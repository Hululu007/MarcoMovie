import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class Smb2Exception implements Exception {
  final int status;
  final String message;

  const Smb2Exception(this.message, {this.status = 0});

  @override
  String toString() => message;
}

class Smb2Entry {
  final String name;
  final String relativePath;
  final bool isDir;
  final int size;

  const Smb2Entry({
    required this.name,
    required this.relativePath,
    required this.isDir,
    required this.size,
  });
}

class Smb2FileHandle {
  final Uint8List fileId;
  final int size;

  const Smb2FileHandle({required this.fileId, required this.size});
}

/// Pure-Dart SMB2/SMB2.1 client over TCP (default port 445) with NTLMv2 and
/// Guest/Anonymous authentication, real directory enumeration, and random-access
/// byte-range file reads — enabling pure SMB browsing and playback on iOS
/// without requiring a WebDAV companion service.
class Smb2Client {
  Smb2Client._(this._socket, this._reader);

  final Socket _socket;
  final _SocketFrameReader _reader;
  int _messageId = 0;
  int _sessionId = 0;
  int _treeId = 0;
  int _maxReadSize = 65536;
  bool _closed = false;

  static const int _cmdNegotiate = 0x0000;
  static const int _cmdSessionSetup = 0x0001;
  static const int _cmdTreeConnect = 0x0003;
  static const int _cmdCreate = 0x0005;
  static const int _cmdClose = 0x0006;
  static const int _cmdRead = 0x0008;
  static const int _cmdQueryDirectory = 0x000E;

  static const int _statusSuccess = 0x00000000;
  static const int _statusMoreProcessing = 0xC0000016;
  static const int _statusNoMoreFiles = 0x80000006;
  static const int _statusEndOfFile = 0xC0000011;
  static const int _statusAccessDenied = 0xC0000022;
  static const int _statusLogonFailure = 0xC000006D;
  static const int _statusBadNetworkName = 0xC00000CC;
  static const int _statusObjectNameNotFound = 0xC0000034;

  static Future<Smb2Client> connect({
    required String host,
    int port = 445,
    required String share,
    String username = '',
    String password = '',
    String domain = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final cleanHost = host.trim();
    final cleanShare = share
        .trim()
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/+'), '')
        .replaceFirst(RegExp(r'/+$'), '');
    if (cleanHost.isEmpty) {
      throw const Smb2Exception('请输入有效的 SMB 服务器地址');
    }
    if (cleanShare.isEmpty) {
      throw const Smb2Exception('请填写 SMB 共享目录名称（例如 Movies）');
    }

    late final Socket socket;
    try {
      socket = await Socket.connect(cleanHost, port, timeout: timeout);
    } catch (e) {
      throw Smb2Exception('无法连接 SMB 服务器 $cleanHost:$port（$e）');
    }
    final client = Smb2Client._(socket, _SocketFrameReader(socket));
    try {
      await client._negotiate(timeout: timeout);
      await client._authenticate(
        username: username.trim(),
        password: password,
        domain: domain.trim(),
        timeout: timeout,
      );
      await client._treeConnect(
        host: cleanHost,
        share: cleanShare,
        timeout: timeout,
      );
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _reader.close();
    try {
      await _socket.close();
    } catch (_) {
      _socket.destroy();
    }
  }

  Future<List<Smb2Entry>> listDirectory(
    String relativePath, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final normalized = _normalizeSmbPath(relativePath);
    final handle = await _create(
      normalized,
      isDirectory: true,
      timeout: timeout,
    );
    try {
      final results = <Smb2Entry>[];
      var restart = true;
      while (true) {
        final reqBody = ByteData(32);
        reqBody.setUint16(0, 33, Endian.little); // StructureSize
        reqBody.setUint8(2, 0x03); // FileBothDirectoryInformation
        reqBody.setUint8(3, restart ? 0x01 : 0x00); // SMB2_RESTART_SCANS
        reqBody.setUint32(4, 0, Endian.little); // FileIndex
        final body = Uint8List(32 + 2); // + "*" UTF-16LE
        body.setRange(0, 32, reqBody.buffer.asUint8List());
        body.setRange(8, 24, handle.fileId);
        final bd = ByteData.sublistView(body);
        bd.setUint16(24, 64 + 32, Endian.little); // FileNameOffset
        bd.setUint16(26, 2, Endian.little); // FileNameLength ("*" = 2 bytes)
        bd.setUint32(28, 65536, Endian.little); // OutputBufferLength
        body[32] = 0x2A; // '*'
        body[33] = 0x00;

        final resp = await _exchange(
          _cmdQueryDirectory,
          body,
          timeout: timeout,
        );
        restart = false;
        if (resp.status == _statusNoMoreFiles) break;
        if (resp.status != _statusSuccess) {
          throw Smb2Exception(
            _describeStatus(resp.status, fallback: '读取 SMB 目录失败'),
            status: resp.status,
          );
        }
        if (resp.payload.length < 8) break;
        final rbd = ByteData.sublistView(resp.payload);
        final outOff = rbd.getUint16(2, Endian.little);
        final outLen = rbd.getUint32(4, Endian.little);
        final start = outOff - 64;
        if (start < 0 || outLen == 0 || start + outLen > resp.payload.length) {
          break;
        }
        final buf = Uint8List.sublistView(resp.payload, start, start + outLen);
        var pos = 0;
        while (pos + 94 <= buf.length) {
          final ebd = ByteData.sublistView(buf, pos);
          final nextOff = ebd.getUint32(0, Endian.little);
          final endOfFile = ebd.getInt64(40, Endian.little);
          final attrs = ebd.getUint32(56, Endian.little);
          final nameLen = ebd.getUint32(60, Endian.little);
          final nameStart = pos + 94;
          if (nameLen > 0 && nameStart + nameLen <= buf.length) {
            final name = _decodeUtf16Le(
              Uint8List.sublistView(buf, nameStart, nameStart + nameLen),
            );
            if (name != '.' && name != '..' && name.isNotEmpty) {
              final isDir = (attrs & 0x00000010) != 0;
              final childPath = normalized.isEmpty ? name : '$normalized\\$name';
              results.add(
                Smb2Entry(
                  name: name,
                  relativePath: childPath.replaceAll('\\', '/'),
                  isDir: isDir,
                  size: endOfFile < 0 ? 0 : endOfFile,
                ),
              );
            }
          }
          if (nextOff == 0) break;
          pos += nextOff;
        }
      }
      results.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return results;
    } finally {
      await _closeHandle(handle.fileId, timeout: timeout);
    }
  }

  Future<Smb2FileHandle> openFile(
    String relativePath, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    return _create(
      _normalizeSmbPath(relativePath),
      isDirectory: false,
      timeout: timeout,
    );
  }

  Future<Uint8List> readFileChunk(
    Smb2FileHandle handle,
    int offset,
    int length, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final safeLen = min(length, min(_maxReadSize, 65536));
    if (safeLen <= 0) return Uint8List(0);
    final body = Uint8List(49);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 49, Endian.little); // StructureSize
    bd.setUint8(2, 0); // Padding
    bd.setUint8(3, 0); // Flags
    bd.setUint32(4, safeLen, Endian.little); // Length
    bd.setUint64(8, offset, Endian.little); // Offset
    body.setRange(16, 32, handle.fileId);
    bd.setUint32(32, 0, Endian.little); // MinimumCount
    bd.setUint32(36, 0, Endian.little); // Channel
    bd.setUint32(40, 0, Endian.little); // RemainingBytes
    bd.setUint16(44, 0, Endian.little); // ReadChannelInfoOffset
    bd.setUint16(46, 0, Endian.little); // ReadChannelInfoLength
    body[48] = 0;

    final resp = await _exchange(_cmdRead, body, timeout: timeout);
    if (resp.status == _statusEndOfFile) return Uint8List(0);
    if (resp.status != _statusSuccess) {
      throw Smb2Exception(
        _describeStatus(resp.status, fallback: '读取 SMB 文件内容失败'),
        status: resp.status,
      );
    }
    if (resp.payload.length < 16) return Uint8List(0);
    final rbd = ByteData.sublistView(resp.payload);
    final dataOff = rbd.getUint8(2);
    final dataLen = rbd.getUint32(4, Endian.little);
    final start = dataOff - 64;
    if (start < 0 || dataLen == 0 || start + dataLen > resp.payload.length) {
      return Uint8List(0);
    }
    return Uint8List.fromList(
      Uint8List.sublistView(resp.payload, start, start + dataLen),
    );
  }

  Future<void> closeFile(
    Smb2FileHandle handle, {
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _closeHandle(handle.fileId, timeout: timeout);

  // ── SMB2 Wire Operations ──────────────────────────────────────────────────

  Future<void> _negotiate({required Duration timeout}) async {
    const dialects = <int>[0x0202, 0x0210];
    final body = Uint8List(36 + dialects.length * 2);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 36, Endian.little); // StructureSize
    bd.setUint16(2, dialects.length, Endian.little); // DialectCount
    bd.setUint16(4, 1, Endian.little); // SecurityMode: signing enabled
    bd.setUint16(6, 0, Endian.little); // Reserved
    bd.setUint32(8, 0, Endian.little); // Capabilities
    final rng = Random.secure();
    for (var i = 0; i < 16; i++) {
      body[12 + i] = rng.nextInt(256);
    }
    for (var i = 0; i < dialects.length; i++) {
      bd.setUint16(36 + i * 2, dialects[i], Endian.little);
    }
    final resp = await _exchange(_cmdNegotiate, body, timeout: timeout);
    if (resp.status != _statusSuccess) {
      throw Smb2Exception(
        _describeStatus(resp.status, fallback: 'SMB2 协议协商失败'),
        status: resp.status,
      );
    }
    if (resp.payload.length >= 36) {
      final rbd = ByteData.sublistView(resp.payload);
      final serverMaxRead = rbd.getUint32(32, Endian.little);
      if (serverMaxRead >= 4096) {
        _maxReadSize = min(serverMaxRead, 256 * 1024);
      }
    }
  }

  Future<void> _authenticate({
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) async {
    final type1 = _buildNtlmType1();
    final resp1 = await _sendSessionSetup(type1, timeout: timeout);
    if (resp1.status == _statusSuccess) {
      _sessionId = resp1.sessionId;
      return;
    }
    if (resp1.status != _statusMoreProcessing) {
      throw Smb2Exception(
        _describeStatus(resp1.status, fallback: 'SMB 会话认证初始化失败'),
        status: resp1.status,
      );
    }
    _sessionId = resp1.sessionId;
    final challengeBytes = _extractSecurityBuffer(resp1.payload);
    final parsed = _parseNtlmType2(challengeBytes);
    final type3 = _buildNtlmType3(
      username: username,
      password: password,
      domain: domain,
      serverChallenge: parsed.serverChallenge,
      targetInfo: parsed.targetInfo,
    );
    final resp2 = await _sendSessionSetup(type3, timeout: timeout);
    if (resp2.status != _statusSuccess) {
      throw Smb2Exception(
        _describeStatus(resp2.status, fallback: 'SMB 认证失败，请检查账号或密码'),
        status: resp2.status,
      );
    }
    _sessionId = resp2.sessionId;
  }

  Future<_Smb2Response> _sendSessionSetup(
    Uint8List secBuf, {
    required Duration timeout,
  }) async {
    final body = Uint8List(24 + secBuf.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 25, Endian.little); // StructureSize
    bd.setUint8(2, 0); // Flags
    bd.setUint8(3, 1); // SecurityMode: signing enabled
    bd.setUint32(4, 0, Endian.little); // Capabilities
    bd.setUint32(8, 0, Endian.little); // Channel
    bd.setUint16(12, 64 + 24, Endian.little); // SecurityBufferOffset
    bd.setUint16(14, secBuf.length, Endian.little); // SecurityBufferLength
    bd.setUint64(16, 0, Endian.little); // PreviousSessionId
    body.setRange(24, 24 + secBuf.length, secBuf);
    return _exchange(_cmdSessionSetup, body, timeout: timeout);
  }

  Future<void> _treeConnect({
    required String host,
    required String share,
    required Duration timeout,
  }) async {
    final unc = _encodeUtf16Le('\\\\$host\\$share');
    final body = Uint8List(8 + unc.length);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 9, Endian.little); // StructureSize
    bd.setUint16(2, 0, Endian.little); // Flags
    bd.setUint16(4, 64 + 8, Endian.little); // PathOffset
    bd.setUint16(6, unc.length, Endian.little); // PathLength
    body.setRange(8, 8 + unc.length, unc);
    final resp = await _exchange(_cmdTreeConnect, body, timeout: timeout);
    if (resp.status != _statusSuccess) {
      throw Smb2Exception(
        _describeStatus(resp.status, fallback: '连接 SMB 共享目录「$share」失败'),
        status: resp.status,
      );
    }
    _treeId = resp.treeId;
  }

  Future<Smb2FileHandle> _create(
    String smbPath, {
    required bool isDirectory,
    required Duration timeout,
  }) async {
    final nameBytes = _encodeUtf16Le(smbPath);
    final bodyLen = 56 + max<int>(1, nameBytes.length);
    final body = Uint8List(bodyLen);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 57, Endian.little); // StructureSize
    bd.setUint8(2, 0); // SecurityFlags
    bd.setUint8(3, 0); // RequestedOplockLevel = NONE
    bd.setUint32(4, 2, Endian.little); // ImpersonationLevel = Impersonation
    bd.setUint64(8, 0, Endian.little); // SmbCreateFlags
    bd.setUint64(16, 0, Endian.little); // Reserved
    // DesiredAccess: FILE_READ_DATA|FILE_READ_ATTRIBUTES|SYNCHRONIZE
    bd.setUint32(24, isDirectory ? 0x00100081 : 0x00120089, Endian.little);
    bd.setUint32(28, isDirectory ? 0x00000010 : 0x00000080, Endian.little);
    bd.setUint32(32, 0x00000007, Endian.little); // ShareAccess: R/W/D
    bd.setUint32(36, 1, Endian.little); // CreateDisposition: FILE_OPEN
    // CreateOptions: FILE_DIRECTORY_FILE vs FILE_NON_DIRECTORY_FILE
    bd.setUint32(40, isDirectory ? 0x00000001 : 0x00000040, Endian.little);
    bd.setUint16(44, 64 + 56, Endian.little); // NameOffset
    bd.setUint16(46, nameBytes.length, Endian.little); // NameLength
    bd.setUint32(48, 0, Endian.little); // CreateContextsOffset
    bd.setUint32(52, 0, Endian.little); // CreateContextsLength
    if (nameBytes.isNotEmpty) {
      body.setRange(56, 56 + nameBytes.length, nameBytes);
    }

    final resp = await _exchange(_cmdCreate, body, timeout: timeout);
    if (resp.status != _statusSuccess) {
      throw Smb2Exception(
        _describeStatus(
          resp.status,
          fallback: isDirectory ? '无法打开 SMB 目录' : '无法打开 SMB 文件',
        ),
        status: resp.status,
      );
    }
    if (resp.payload.length < 80) {
      throw const Smb2Exception('SMB CREATE 响应格式无效');
    }
    final rbd = ByteData.sublistView(resp.payload);
    final endOfFile = rbd.getInt64(48, Endian.little);
    final fileId = Uint8List.fromList(Uint8List.sublistView(resp.payload, 64, 80));
    return Smb2FileHandle(fileId: fileId, size: endOfFile < 0 ? 0 : endOfFile);
  }

  Future<void> _closeHandle(
    Uint8List fileId, {
    required Duration timeout,
  }) async {
    if (_closed) return;
    final body = Uint8List(24);
    final bd = ByteData.sublistView(body);
    bd.setUint16(0, 24, Endian.little);
    bd.setUint16(2, 0, Endian.little);
    bd.setUint32(4, 0, Endian.little);
    body.setRange(8, 24, fileId);
    try {
      await _exchange(_cmdClose, body, timeout: timeout);
    } catch (_) {}
  }

  Future<_Smb2Response> _exchange(
    int command,
    Uint8List body, {
    required Duration timeout,
  }) async {
    final msgId = _messageId++;
    final packetLen = 64 + body.length;
    final frame = Uint8List(4 + packetLen);
    frame[0] = 0x00;
    frame[1] = (packetLen >> 16) & 0xFF;
    frame[2] = (packetLen >> 8) & 0xFF;
    frame[3] = packetLen & 0xFF;

    frame[4] = 0xFE;
    frame[5] = 0x53; // 'S'
    frame[6] = 0x4D; // 'M'
    frame[7] = 0x42; // 'B'
    final hd = ByteData.sublistView(frame, 4, 68);
    hd.setUint16(4, 64, Endian.little); // StructureSize
    hd.setUint16(6, 1, Endian.little); // CreditCharge
    hd.setUint32(8, 0, Endian.little); // Status
    hd.setUint16(12, command, Endian.little); // Command
    hd.setUint16(14, 64, Endian.little); // CreditRequest
    hd.setUint32(16, 0, Endian.little); // Flags
    hd.setUint32(20, 0, Endian.little); // NextCommand
    hd.setUint64(24, msgId, Endian.little); // MessageId
    hd.setUint32(32, 0, Endian.little); // Reserved
    hd.setUint32(36, _treeId, Endian.little); // TreeId
    hd.setUint64(40, _sessionId, Endian.little); // SessionId
    frame.setRange(68, 68 + body.length, body);

    _socket.add(frame);
    await _socket.flush().timeout(timeout);

    final respBytes = await _reader.readFrame(timeout: timeout);
    if (respBytes.length < 64 ||
        respBytes[0] != 0xFE ||
        respBytes[1] != 0x53 ||
        respBytes[2] != 0x4D ||
        respBytes[3] != 0x42) {
      throw const Smb2Exception('服务器返回的不是有效的 SMB2 协议响应');
    }
    final rhd = ByteData.sublistView(respBytes, 0, 64);
    final status = rhd.getUint32(8, Endian.little);
    final treeId = rhd.getUint32(36, Endian.little);
    final sessionId = rhd.getUint64(40, Endian.little);
    return _Smb2Response(
      status: status,
      treeId: treeId,
      sessionId: sessionId,
      payload: Uint8List.sublistView(respBytes, 64),
    );
  }

  // ── NTLMv2 Helpers (RFC 1320 MD4 + MS-NLMP) ───────────────────────────────

  static Uint8List _buildNtlmType1() {
    final buf = Uint8List(32);
    buf.setRange(0, 8, ascii.encode('NTLMSSP\x00'));
    final bd = ByteData.sublistView(buf);
    bd.setUint32(8, 1, Endian.little); // Type 1 Negotiate
    // UNICODE | REQUEST_TARGET | NTLM | EXTENDED_SESSIONSECURITY | 128 | 56
    bd.setUint32(12, 0x60088215, Endian.little);
    return buf;
  }

  static Uint8List _extractSecurityBuffer(Uint8List payload) {
    if (payload.length < 8) return Uint8List(0);
    final bd = ByteData.sublistView(payload);
    final secOff = bd.getUint16(4, Endian.little);
    final secLen = bd.getUint16(6, Endian.little);
    final start = secOff - 64;
    if (start < 0 || start + secLen > payload.length) return Uint8List(0);
    return Uint8List.sublistView(payload, start, start + secLen);
  }

  static ({Uint8List serverChallenge, Uint8List targetInfo}) _parseNtlmType2(
    Uint8List secBuf,
  ) {
    final sig = ascii.encode('NTLMSSP\x00');
    var idx = -1;
    for (var i = 0; i <= secBuf.length - 32; i++) {
      var match = true;
      for (var j = 0; j < 8; j++) {
        if (secBuf[i + j] != sig[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        idx = i;
        break;
      }
    }
    if (idx < 0 || idx + 32 > secBuf.length) {
      throw const Smb2Exception('SMB 服务器未返回有效的 NTLM 质询包');
    }
    final ntlm = Uint8List.sublistView(secBuf, idx);
    final bd = ByteData.sublistView(ntlm);
    if (bd.getUint32(8, Endian.little) != 2) {
      throw const Smb2Exception('SMB NTLM 质询类型异常');
    }
    final challenge = Uint8List.fromList(Uint8List.sublistView(ntlm, 24, 32));
    Uint8List targetInfo = Uint8List(0);
    if (ntlm.length >= 48) {
      final tiLen = bd.getUint16(40, Endian.little);
      final tiOff = bd.getUint32(44, Endian.little);
      if (tiLen > 0 && tiOff + tiLen <= ntlm.length) {
        targetInfo = Uint8List.fromList(
          Uint8List.sublistView(ntlm, tiOff, tiOff + tiLen),
        );
      }
    }
    return (serverChallenge: challenge, targetInfo: targetInfo);
  }

  static Uint8List _buildNtlmType3({
    required String username,
    required String password,
    required String domain,
    required Uint8List serverChallenge,
    required Uint8List targetInfo,
  }) {
    final domainBytes = _encodeUtf16Le(domain);
    final userBytes = _encodeUtf16Le(username);
    final hostBytes = _encodeUtf16Le('MARCO');

    Uint8List lmResp;
    Uint8List ntResp;
    if (username.isEmpty) {
      lmResp = Uint8List(0);
      ntResp = Uint8List(0);
    } else {
      final ntHash = _md4(_encodeUtf16Le(password));
      final ntlmv2Hash = Hmac(md5, ntHash)
          .convert(_encodeUtf16Le('${username.toUpperCase()}$domain'))
          .bytes;
      final rng = Random.secure();
      final clientChallenge =
          Uint8List.fromList(List.generate(8, (_) => rng.nextInt(256)));
      final unixMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final fileTime = (unixMs + 11644473600000) * 10000;

      final blob = Uint8List(28 + targetInfo.length + 4);
      final bbd = ByteData.sublistView(blob);
      blob[0] = 0x01;
      blob[1] = 0x01;
      bbd.setUint64(8, fileTime, Endian.little);
      blob.setRange(16, 24, clientChallenge);
      if (targetInfo.isNotEmpty) {
        blob.setRange(28, 28 + targetInfo.length, targetInfo);
      }
      final ntInput = Uint8List(8 + blob.length)
        ..setRange(0, 8, serverChallenge)
        ..setRange(8, 8 + blob.length, blob);
      final ntProof = Hmac(md5, ntlmv2Hash).convert(ntInput).bytes;
      ntResp = Uint8List(16 + blob.length)
        ..setRange(0, 16, ntProof)
        ..setRange(16, 16 + blob.length, blob);

      final lmInput = Uint8List(16)
        ..setRange(0, 8, serverChallenge)
        ..setRange(8, 16, clientChallenge);
      final lmProof = Hmac(md5, ntlmv2Hash).convert(lmInput).bytes;
      lmResp = Uint8List(24)
        ..setRange(0, 16, lmProof)
        ..setRange(16, 24, clientChallenge);
    }

    const headerLen = 72;
    var offset = headerLen;
    final domOff = offset;
    offset += domainBytes.length;
    final userOff = offset;
    offset += userBytes.length;
    final hostOff = offset;
    offset += hostBytes.length;
    final lmOff = offset;
    offset += lmResp.length;
    final ntOff = offset;
    offset += ntResp.length;

    final out = Uint8List(offset);
    out.setRange(0, 8, ascii.encode('NTLMSSP\x00'));
    final bd = ByteData.sublistView(out);
    bd.setUint32(8, 3, Endian.little); // Type 3 Authenticate
    _writeSecBuf(bd, 12, lmResp.length, lmOff);
    _writeSecBuf(bd, 20, ntResp.length, ntOff);
    _writeSecBuf(bd, 28, domainBytes.length, domOff);
    _writeSecBuf(bd, 36, userBytes.length, userOff);
    _writeSecBuf(bd, 44, hostBytes.length, hostOff);
    _writeSecBuf(bd, 52, 0, offset); // EncryptedRandomSessionKey
    bd.setUint32(60, 0x60088215, Endian.little);

    out.setRange(domOff, domOff + domainBytes.length, domainBytes);
    out.setRange(userOff, userOff + userBytes.length, userBytes);
    out.setRange(hostOff, hostOff + hostBytes.length, hostBytes);
    out.setRange(lmOff, lmOff + lmResp.length, lmResp);
    out.setRange(ntOff, ntOff + ntResp.length, ntResp);
    return out;
  }

  static void _writeSecBuf(ByteData bd, int pos, int len, int offset) {
    bd.setUint16(pos, len, Endian.little);
    bd.setUint16(pos + 2, len, Endian.little);
    bd.setUint32(pos + 4, offset, Endian.little);
  }

  static Uint8List _md4(Uint8List input) {
    final bitLen = input.length * 8;
    final padLen = ((56 - (input.length + 1) % 64) + 64) % 64;
    final msg = Uint8List(input.length + 1 + padLen + 8)
      ..setRange(0, input.length, input);
    msg[input.length] = 0x80;
    ByteData.sublistView(msg).setUint64(msg.length - 8, bitLen, Endian.little);

    var a = 0x67452301;
    var b = 0xEFCDAB89;
    var c = 0x98BADCFE;
    var d = 0x10325476;

    int rotl(int x, int s) => ((x << s) | ((x & 0xFFFFFFFF) >>> (32 - s))) & 0xFFFFFFFF;
    int f(int x, int y, int z) => ((x & y) | ((~x & 0xFFFFFFFF) & z)) & 0xFFFFFFFF;
    int g(int x, int y, int z) => ((x & y) | (x & z) | (y & z)) & 0xFFFFFFFF;
    int h(int x, int y, int z) => (x ^ y ^ z) & 0xFFFFFFFF;

    final x = Uint32List(16);
    final mbd = ByteData.sublistView(msg);
    for (var i = 0; i < msg.length; i += 64) {
      for (var j = 0; j < 16; j++) {
        x[j] = mbd.getUint32(i + j * 4, Endian.little);
      }
      final aa = a, bb = b, cc = c, dd = d;

      const s1 = [3, 7, 11, 19];
      for (var k = 0; k < 16; k += 4) {
        a = rotl((a + f(b, c, d) + x[k]) & 0xFFFFFFFF, s1[0]);
        d = rotl((d + f(a, b, c) + x[k + 1]) & 0xFFFFFFFF, s1[1]);
        c = rotl((c + f(d, a, b) + x[k + 2]) & 0xFFFFFFFF, s1[2]);
        b = rotl((b + f(c, d, a) + x[k + 3]) & 0xFFFFFFFF, s1[3]);
      }

      const s2 = [3, 5, 9, 13];
      for (var k = 0; k < 4; k++) {
        a = rotl((a + g(b, c, d) + x[k] + 0x5A827999) & 0xFFFFFFFF, s2[0]);
        d = rotl((d + g(a, b, c) + x[k + 4] + 0x5A827999) & 0xFFFFFFFF, s2[1]);
        c = rotl((c + g(d, a, b) + x[k + 8] + 0x5A827999) & 0xFFFFFFFF, s2[2]);
        b = rotl((b + g(c, d, a) + x[k + 12] + 0x5A827999) & 0xFFFFFFFF, s2[3]);
      }

      const idx3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
      const s3 = [3, 9, 11, 15];
      for (var k = 0; k < 16; k += 4) {
        a = rotl((a + h(b, c, d) + x[idx3[k]] + 0x6ED9EBA1) & 0xFFFFFFFF, s3[0]);
        d = rotl((d + h(a, b, c) + x[idx3[k + 1]] + 0x6ED9EBA1) & 0xFFFFFFFF, s3[1]);
        c = rotl((c + h(d, a, b) + x[idx3[k + 2]] + 0x6ED9EBA1) & 0xFFFFFFFF, s3[2]);
        b = rotl((b + h(c, d, a) + x[idx3[k + 3]] + 0x6ED9EBA1) & 0xFFFFFFFF, s3[3]);
      }

      a = (a + aa) & 0xFFFFFFFF;
      b = (b + bb) & 0xFFFFFFFF;
      c = (c + cc) & 0xFFFFFFFF;
      d = (d + dd) & 0xFFFFFFFF;
    }

    final out = Uint8List(16);
    final obd = ByteData.sublistView(out);
    obd.setUint32(0, a, Endian.little);
    obd.setUint32(4, b, Endian.little);
    obd.setUint32(8, c, Endian.little);
    obd.setUint32(12, d, Endian.little);
    return out;
  }

  static Uint8List _encodeUtf16Le(String value) {
    final units = value.codeUnits;
    final out = Uint8List(units.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < units.length; i++) {
      bd.setUint16(i * 2, units[i], Endian.little);
    }
    return out;
  }

  static String _decodeUtf16Le(Uint8List bytes) {
    final count = bytes.length ~/ 2;
    final bd = ByteData.sublistView(bytes);
    final units = List<int>.generate(
      count,
      (i) => bd.getUint16(i * 2, Endian.little),
    );
    return String.fromCharCodes(units);
  }

  static String _normalizeSmbPath(String raw) {
    final cleaned = raw
        .trim()
        .replaceAll('/', '\\')
        .replaceFirst(RegExp(r'^\\+'), '')
        .replaceFirst(RegExp(r'\\+$'), '');
    return cleaned;
  }

  static String _describeStatus(int status, {required String fallback}) {
    return switch (status) {
      _statusLogonFailure => 'SMB 认证失败，请检查用户名或密码',
      _statusAccessDenied => 'SMB 无权访问该共享或目录',
      _statusBadNetworkName => '找不到指定的 SMB 共享名称',
      _statusObjectNameNotFound => 'SMB 文件或目录不存在',
      _ => '$fallback（NTSTATUS 0x${status.toRadixString(16).toUpperCase().padLeft(8, '0')}）',
    };
  }
}

class _Smb2Response {
  final int status;
  final int treeId;
  final int sessionId;
  final Uint8List payload;

  const _Smb2Response({
    required this.status,
    required this.treeId,
    required this.sessionId,
    required this.payload,
  });
}

class _SocketFrameReader {
  _SocketFrameReader(Socket socket) {
    _sub = socket.listen(
      (chunk) {
        _buffer.add(chunk);
        _tryFulfill();
      },
      onError: (Object e, StackTrace st) {
        _eof = true;
        _error = e;
        _failWaiter(e);
      },
      onDone: () {
        _eof = true;
        _failWaiter(const Smb2Exception('SMB 服务器关闭了连接'));
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Completer<Uint8List>? _waiter;
  int _needed = 0;
  bool _eof = false;
  Object? _error;

  Future<void> close() async {
    await _sub.cancel();
    _failWaiter(const Smb2Exception('SMB 连接已关闭'));
  }

  Future<Uint8List> readFrame({required Duration timeout}) async {
    final hdr = await _readExact(4, timeout: timeout);
    final length = (hdr[1] << 16) | (hdr[2] << 8) | hdr[3];
    if (length <= 0 || length > 16 * 1024 * 1024) {
      throw const Smb2Exception('SMB 响应帧长度异常');
    }
    return _readExact(length, timeout: timeout);
  }

  Future<Uint8List> _readExact(int n, {required Duration timeout}) {
    if (_buffer.length >= n) {
      return Future.value(_take(n));
    }
    if (_eof) {
      return Future.error(_error ?? const Smb2Exception('SMB 连接已断开'));
    }
    final completer = Completer<Uint8List>();
    _waiter = completer;
    _needed = n;
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiter, completer)) {
          _waiter = null;
          _needed = 0;
        }
        throw const Smb2Exception('SMB 读取响应超时');
      },
    );
  }

  Uint8List _take(int n) {
    final all = _buffer.takeBytes();
    final head = Uint8List.fromList(Uint8List.sublistView(all, 0, n));
    if (all.length > n) {
      _buffer.add(Uint8List.sublistView(all, n));
    }
    return head;
  }

  void _tryFulfill() {
    final waiter = _waiter;
    if (waiter == null || waiter.isCompleted) return;
    if (_buffer.length >= _needed) {
      final n = _needed;
      _waiter = null;
      _needed = 0;
      waiter.complete(_take(n));
    }
  }

  void _failWaiter(Object err) {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      _needed = 0;
      waiter.completeError(err);
    }
  }
}

/// Loopback HTTP Range (`206 Partial Content`) proxy that streams a single SMB2
/// file so iOS AVPlayer and MPV can seek and play pure SMB shares seamlessly.
class SmbMediaStreamProxy {
  SmbMediaStreamProxy._({
    required HttpServer server,
    required String token,
    required String fileName,
    required this.host,
    required this.port,
    required this.share,
    required this.username,
    required this.password,
    required this.relativePath,
    required this.fileSize,
  })  : _server = server,
        _token = token,
        _fileName = fileName {
    _server.listen(_handleRequest);
    _idleTimer = Timer(const Duration(hours: 6), () {
      unawaited(close());
    });
  }

  final HttpServer _server;
  final String _token;
  final String _fileName;
  final String host;
  final int port;
  final String share;
  final String username;
  final String password;
  final String relativePath;
  final int fileSize;
  Timer? _idleTimer;
  bool _closed = false;

  Uri get url => Uri.parse(
        'http://127.0.0.1:${_server.port}/$_token/${Uri.encodeComponent(_fileName)}',
      );

  static Future<SmbMediaStreamProxy> open({
    required String host,
    required int port,
    required String share,
    required String username,
    required String password,
    required String relativePath,
  }) async {
    final probe = await Smb2Client.connect(
      host: host,
      port: port,
      share: share,
      username: username,
      password: password,
    );
    late final int size;
    try {
      final fh = await probe.openFile(relativePath);
      size = fh.size;
      await probe.closeFile(fh);
    } finally {
      await probe.close();
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..autoCompress = false;
    final token = base64Url
        .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
    final fileName = relativePath.split('/').last.isEmpty
        ? 'video.mp4'
        : relativePath.split('/').last;
    return SmbMediaStreamProxy._(
      server: server,
      token: token,
      fileName: fileName,
      host: host,
      port: port,
      share: share,
      username: username,
      password: password,
      relativePath: relativePath,
      fileSize: size,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_closed || !request.uri.path.startsWith('/$_token/')) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    var start = 0;
    var end = fileSize > 0 ? fileSize - 1 : 0;
    var partial = false;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6).split(',').first.trim();
      final parts = spec.split('-');
      if (parts.length == 2) {
        final s = int.tryParse(parts[0].trim());
        final e = int.tryParse(parts[1].trim());
        if (s != null) {
          start = s;
          end = e != null ? min(e, fileSize - 1) : (fileSize - 1);
          partial = true;
        } else if (e != null && e > 0) {
          start = max(0, fileSize - e);
          end = fileSize - 1;
          partial = true;
        }
      }
    }

    if (fileSize > 0 && (start < 0 || start >= fileSize || end < start)) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$fileSize');
      await request.response.close();
      return;
    }

    final length = fileSize == 0 ? 0 : (end - start + 1);
    request.response.statusCode =
        partial ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.contentType = _contentTypeFor(_fileName);
    request.response.headers.contentLength = length;
    if (partial && fileSize > 0) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$fileSize',
      );
    }

    if (request.method == 'HEAD' || length == 0) {
      await request.response.close();
      return;
    }

    Smb2Client? smb;
    Smb2FileHandle? fh;
    try {
      smb = await Smb2Client.connect(
        host: host,
        port: port,
        share: share,
        username: username,
        password: password,
      );
      fh = await smb.openFile(relativePath);
      var cursor = start;
      var remaining = length;
      while (remaining > 0 && !_closed) {
        final chunk = await smb.readFileChunk(fh, cursor, min(remaining, 65536));
        if (chunk.isEmpty) break;
        request.response.add(chunk);
        await request.response.flush();
        cursor += chunk.length;
        remaining -= chunk.length;
      }
    } catch (_) {
      // Client may abort mid-stream on seek.
    } finally {
      if (smb != null && fh != null) {
        await smb.closeFile(fh);
      }
      await smb?.close();
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  static ContentType _contentTypeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) {
      return ContentType('video', 'mp4');
    }
    if (lower.endsWith('.mkv')) return ContentType('video', 'x-matroska');
    if (lower.endsWith('.mov')) return ContentType('video', 'quicktime');
    if (lower.endsWith('.webm')) return ContentType('video', 'webm');
    if (lower.endsWith('.ts') || lower.endsWith('.m2ts')) {
      return ContentType('video', 'mp2t');
    }
    return ContentType.binary;
  }
}
