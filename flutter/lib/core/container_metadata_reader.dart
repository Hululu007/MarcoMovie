// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Lightweight pure-Dart container metadata reader for Matroska (`.mkv`/`.webm`)
/// and ISO-BMFF (`.mp4`/`.m4v`/`.mov`) files, plus libmpv runtime `metadata`
/// JSON parsing and an in-memory cache shared across DetailScreen, PlayerScreen,
/// episode pickers, line switching, and danmu matching.
class ContainerMetadataReader {
  ContainerMetadataReader._();

  static const int _maxTagSectionBytes = 512 * 1024;
  static const int _maxHeaderScanBytes = 256 * 1024;
  static const int _maxMp4MoovBytes = 4 * 1024 * 1024;

  // Matroska / EBML element IDs
  static const int _idEbml = 0x1A45DFA3;
  static const int _idSegment = 0x18538067;
  static const int _idSeekHead = 0x114D9B74;
  static const int _idSeek = 0x4DBB;
  static const int _idSeekId = 0x53AB;
  static const int _idSeekPosition = 0x53AC;
  static const int _idInfo = 0x1549A966;
  static const int _idInfoTitle = 0x7BA9;
  static const int _idTags = 0x1254C367;
  static const int _idTag = 0x7373;
  static const int _idTargets = 0x63C0;
  static const int _idTargetTypeValue = 0x68CA;
  static const int _idTagTrackUid = 0x63C5;
  static const int _idTagEditionUid = 0x63C9;
  static const int _idTagChapterUid = 0x63C4;
  static const int _idTagAttachmentUid = 0x63C6;
  static const int _idSimpleTag = 0x67C8;
  static const int _idTagName = 0x45A3;
  static const int _idTagString = 0x4487;
  static const int _idCluster = 0x1F43B675;

  /// Normalizes a local filesystem path or `file://` URI into an OS file path.
  static String? resolveLocalFilePath(String rawPathOrUri) {
    final trimmed = rawPathOrUri.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.toLowerCase().startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath();
      } catch (_) {
        return null;
      }
    }
    if (trimmed.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed)) {
      return trimmed;
    }
    return null;
  }

  /// Synchronously reads container tags from a local MKV/WebM or MP4/M4V file
  /// using bounded random-access seeks. Returns an empty map on non-local or
  /// unreadable files without ever throwing.
  static Map<String, String> readLocalFileTagsSync(String rawPathOrUri) {
    final path = resolveLocalFilePath(rawPathOrUri);
    if (path == null) return const <String, String>{};
    final file = File(path);
    RandomAccessFile? raf;
    try {
      if (!file.existsSync()) return const <String, String>{};
      final length = file.lengthSync();
      if (length < 16) return const <String, String>{};
      raf = file.openSync(mode: FileMode.read);
      final head = _readBytesAt(raf, 0, math.min(16, length));
      if (head.length < 12) return const <String, String>{};
      if (head[0] == 0x1A &&
          head[1] == 0x45 &&
          head[2] == 0xDF &&
          head[3] == 0xA3) {
        return _readMatroskaTags(raf, length);
      }
      if (head[4] == 0x66 &&
          head[5] == 0x74 &&
          head[6] == 0x79 &&
          head[7] == 0x70) {
        return _readMp4Tags(raf, length);
      }
      return const <String, String>{};
    } catch (_) {
      return const <String, String>{};
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// Parses libmpv's `metadata` property JSON string (plus optional
  /// `media-title`) into normalized lowercase tag key-value pairs.
  ///
  /// Ignores `media-title` when it merely echoes the raw filename (mpv's
  /// fallback when a container has no internal title tag).
  static Map<String, String> parseMpvMetadataJson(
    String? rawMetadataJson, {
    String? mediaTitle,
    String? fallbackFileName,
  }) {
    final out = <String, String>{};
    final raw = (rawMetadataJson ?? '').trim();
    if (raw.isNotEmpty && raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final k = entry.key.toString().trim().toLowerCase();
            final v = (entry.value ?? '').toString().trim();
            if (k.isNotEmpty && v.isNotEmpty) {
              out[k] = v;
            }
          }
        }
      } catch (_) {}
    }
    final mt = (mediaTitle ?? '').trim();
    if (mt.isNotEmpty && !out.containsKey('title')) {
      final fb = (fallbackFileName ?? '').trim();
      final fbBase = _basename(fb).toLowerCase();
      final fbStem = _stripExt(fbBase);
      final mtLower = mt.toLowerCase();
      final mtStem = _stripExt(mtLower);
      final echoesFileName = fbBase.isNotEmpty &&
          (mtLower == fbBase ||
              mtLower == fb.toLowerCase() ||
              (fbStem.isNotEmpty && mtStem == fbStem));
      if (!echoesFileName) {
        out['title'] = mt;
      }
    }
    return Map<String, String>.unmodifiable(out);
  }

  static String _basename(String path) {
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  static String _stripExt(String name) {
    return name.replaceAll(
      RegExp(r'\.(?:mkv|mp4|m4v|mov|webm|ts|m2ts|avi|flv|wmv)$',
          caseSensitive: false),
      '',
    );
  }

  static Uint8List _readBytesAt(RandomAccessFile raf, int offset, int count) {
    if (offset < 0 || count <= 0) return Uint8List(0);
    raf.setPositionSync(offset);
    return raf.readSync(count);
  }

  // ---------------------------------------------------------------------------
  // Matroska / EBML Parser
  // ---------------------------------------------------------------------------

  static ({int id, int size, int headerLen, bool unknownSize})? _readEbmlHeader(
    Uint8List buf,
    int pos,
  ) {
    if (pos >= buf.length) return null;
    final firstId = buf[pos];
    if (firstId == 0) return null;
    int idLen = 1;
    int mask = 0x80;
    while (idLen <= 4 && (firstId & mask) == 0) {
      mask >>= 1;
      idLen++;
    }
    if (idLen > 4 || pos + idLen >= buf.length) return null;
    int id = 0;
    for (int i = 0; i < idLen; i++) {
      id = (id << 8) | buf[pos + i];
    }

    final sizePos = pos + idLen;
    final firstSize = buf[sizePos];
    if (firstSize == 0) return null;
    int sizeLen = 1;
    int sMask = 0x80;
    while (sizeLen <= 8 && (firstSize & sMask) == 0) {
      sMask >>= 1;
      sizeLen++;
    }
    if (sizeLen > 8 || sizePos + sizeLen > buf.length) return null;
    int size = firstSize & (sMask - 1);
    bool allOnes = size == (sMask - 1);
    for (int i = 1; i < sizeLen; i++) {
      final b = buf[sizePos + i];
      size = (size << 8) | b;
      if (b != 0xFF) allOnes = false;
    }
    return (
      id: id,
      size: size,
      headerLen: idLen + sizeLen,
      unknownSize: allOnes,
    );
  }

  static int _readUnsignedInt(Uint8List buf, int offset, int len) {
    int val = 0;
    for (int i = 0; i < len && offset + i < buf.length; i++) {
      val = (val << 8) | buf[offset + i];
    }
    return val;
  }

  static Map<String, String> _readMatroskaTags(
    RandomAccessFile raf,
    int fileLength,
  ) {
    final headBuf =
        _readBytesAt(raf, 0, math.min(_maxHeaderScanBytes, fileLength));
    int pos = 0;
    final ebml = _readEbmlHeader(headBuf, pos);
    if (ebml == null || ebml.id != _idEbml) return const <String, String>{};
    pos += ebml.headerLen + ebml.size;
    if (pos >= headBuf.length) return const <String, String>{};

    final seg = _readEbmlHeader(headBuf, pos);
    if (seg == null || seg.id != _idSegment) return const <String, String>{};
    final segmentDataStart = pos + seg.headerLen;
    pos = segmentDataStart;

    final tags = <String, String>{};
    final seekTargets = <int, List<int>>{};
    final visitedOffsets = <int>{};

    // Walk top-level children in the initial header window until Cluster or end.
    while (pos < headBuf.length) {
      final hdr = _readEbmlHeader(headBuf, pos);
      if (hdr == null) break;
      final dataStart = pos + hdr.headerLen;
      if (hdr.id == _idCluster) break;
      if (hdr.unknownSize || hdr.size < 0) break;
      final dataEnd = dataStart + hdr.size;
      if (dataEnd > headBuf.length) {
        // Large element extending past header buffer: still try reading if Info/Tags.
        if ((hdr.id == _idInfo || hdr.id == _idTags) &&
            hdr.size <= _maxTagSectionBytes &&
            dataEnd <= fileLength) {
          visitedOffsets.add(pos);
          final section = _readBytesAt(raf, dataStart, hdr.size);
          if (hdr.id == _idInfo) {
            _parseInfoPayload(section, tags);
          } else {
            _parseTagsPayload(section, tags);
          }
        }
        break;
      }
      if (hdr.id == _idSeekHead) {
        _parseSeekHeadPayload(
          headBuf.sublist(dataStart, dataEnd),
          seekTargets,
        );
      } else if (hdr.id == _idInfo) {
        visitedOffsets.add(pos);
        _parseInfoPayload(headBuf.sublist(dataStart, dataEnd), tags);
      } else if (hdr.id == _idTags) {
        visitedOffsets.add(pos);
        _parseTagsPayload(headBuf.sublist(dataStart, dataEnd), tags);
      }
      pos = dataEnd;
    }

    // Follow SeekHead pointers (essential when FFmpeg writes Tags at the tail).
    for (final targetId in const <int>[_idInfo, _idTags]) {
      final relOffsets = seekTargets[targetId];
      if (relOffsets == null) continue;
      for (final rel in relOffsets) {
        final abs = segmentDataStart + rel;
        if (abs < segmentDataStart ||
            abs >= fileLength ||
            visitedOffsets.contains(abs)) {
          continue;
        }
        visitedOffsets.add(abs);
        final probe = _readBytesAt(raf, abs, math.min(16, fileLength - abs));
        final hdr = _readEbmlHeader(probe, 0);
        if (hdr == null ||
            hdr.id != targetId ||
            hdr.unknownSize ||
            hdr.size <= 0 ||
            hdr.size > _maxTagSectionBytes ||
            abs + hdr.headerLen + hdr.size > fileLength) {
          continue;
        }
        final section = _readBytesAt(raf, abs + hdr.headerLen, hdr.size);
        if (targetId == _idInfo) {
          _parseInfoPayload(section, tags);
        } else {
          _parseTagsPayload(section, tags);
        }
      }
    }

    return Map<String, String>.unmodifiable(tags);
  }

  static void _parseSeekHeadPayload(
    Uint8List buf,
    Map<int, List<int>> out,
  ) {
    int pos = 0;
    while (pos < buf.length) {
      final hdr = _readEbmlHeader(buf, pos);
      if (hdr == null || hdr.unknownSize) break;
      final dataStart = pos + hdr.headerLen;
      final dataEnd = dataStart + hdr.size;
      if (dataEnd > buf.length) break;
      if (hdr.id == _idSeek) {
        int? seekId;
        int? seekPos;
        int sPos = dataStart;
        while (sPos < dataEnd) {
          final sh = _readEbmlHeader(buf, sPos);
          if (sh == null || sh.unknownSize) break;
          final sData = sPos + sh.headerLen;
          final sEnd = sData + sh.size;
          if (sEnd > dataEnd) break;
          if (sh.id == _idSeekId && sh.size >= 1 && sh.size <= 4) {
            seekId = _readUnsignedInt(buf, sData, sh.size);
          } else if (sh.id == _idSeekPosition && sh.size >= 1 && sh.size <= 8) {
            seekPos = _readUnsignedInt(buf, sData, sh.size);
          }
          sPos = sEnd;
        }
        if (seekId != null && seekPos != null) {
          out.putIfAbsent(seekId, () => <int>[]).add(seekPos);
        }
      }
      pos = dataEnd;
    }
  }

  static void _parseInfoPayload(Uint8List buf, Map<String, String> tags) {
    int pos = 0;
    while (pos < buf.length) {
      final hdr = _readEbmlHeader(buf, pos);
      if (hdr == null || hdr.unknownSize) break;
      final dataStart = pos + hdr.headerLen;
      final dataEnd = dataStart + hdr.size;
      if (dataEnd > buf.length) break;
      if (hdr.id == _idInfoTitle && hdr.size > 0 && hdr.size <= 4096) {
        final title =
            utf8.decode(buf.sublist(dataStart, dataEnd), allowMalformed: true)
                .replaceAll('\x00', '')
                .trim();
        if (title.isNotEmpty) {
          tags['title'] = title;
        }
      }
      pos = dataEnd;
    }
  }

  static void _parseTagsPayload(Uint8List buf, Map<String, String> tags) {
    int pos = 0;
    while (pos < buf.length) {
      final hdr = _readEbmlHeader(buf, pos);
      if (hdr == null || hdr.unknownSize) break;
      final dataStart = pos + hdr.headerLen;
      final dataEnd = dataStart + hdr.size;
      if (dataEnd > buf.length) break;
      if (hdr.id == _idTag) {
        _parseTagChildren(buf, dataStart, dataEnd, tags);
      }
      pos = dataEnd;
    }
  }

  static bool _isSubFileTagTargets(Uint8List buf, int start, int end) {
    int pos = start;
    while (pos < end) {
      final hdr = _readEbmlHeader(buf, pos);
      if (hdr == null || hdr.unknownSize) break;
      final dataStart = pos + hdr.headerLen;
      final dataEnd = dataStart + hdr.size;
      if (dataEnd > end) break;
      if (hdr.id == _idTagTrackUid ||
          hdr.id == _idTagChapterUid ||
          hdr.id == _idTagEditionUid ||
          hdr.id == _idTagAttachmentUid) {
        // Any explicit non-zero Track/Chapter/Edition/Attachment UID scopes
        // this Matroska Tag to a specific stream or sub-entity (e.g. an audio
        // track), NOT the whole file/episode.
        int uid = 0;
        for (int i = dataStart; i < dataEnd; i++) {
          uid = (uid << 8) | buf[i];
        }
        if (uid != 0) return true;
      } else if (hdr.id == _idTargetTypeValue && hdr.size > 0 && hdr.size <= 8) {
        // Matroska TargetTypeValue: 50=MOVIE/EPISODE, 60=SEASON, 70=COLLECTION;
        // values < 50 (e.g. 30=TRACK/CHAPTER, 20=SUBTRACK, 10=SHOT) are
        // sub-file scopes and must not be promoted to whole-file episode tags.
        int ttv = 0;
        for (int i = dataStart; i < dataEnd; i++) {
          ttv = (ttv << 8) | buf[i];
        }
        if (ttv > 0 && ttv < 50) return true;
      }
      pos = dataEnd;
    }
    return false;
  }

  static void _parseTagChildren(
    Uint8List buf,
    int start,
    int end,
    Map<String, String> tags,
  ) {
    final pendingSimpleTags = <({String name, String val})>[];
    bool isSubFileScoped = false;
    int pos = start;
    while (pos < end) {
      final hdr = _readEbmlHeader(buf, pos);
      if (hdr == null || hdr.unknownSize) break;
      final dataStart = pos + hdr.headerLen;
      final dataEnd = dataStart + hdr.size;
      if (dataEnd > end) break;
      if (hdr.id == _idTargets) {
        if (_isSubFileTagTargets(buf, dataStart, dataEnd)) {
          isSubFileScoped = true;
        }
      } else if (hdr.id == _idSimpleTag) {
        String name = '';
        String val = '';
        int sp = dataStart;
        while (sp < dataEnd) {
          final sh = _readEbmlHeader(buf, sp);
          if (sh == null || sh.unknownSize) break;
          final sData = sp + sh.headerLen;
          final sEnd = sData + sh.size;
          if (sEnd > dataEnd) break;
          if (sh.id == _idTagName && sh.size <= 512) {
            name = utf8
                .decode(buf.sublist(sData, sEnd), allowMalformed: true)
                .replaceAll('\x00', '')
                .trim()
                .toLowerCase();
          } else if (sh.id == _idTagString && sh.size <= 4096) {
            val = utf8
                .decode(buf.sublist(sData, sEnd), allowMalformed: true)
                .replaceAll('\x00', '')
                .trim();
          }
          sp = sEnd;
        }
        if (name.isNotEmpty && val.isNotEmpty) {
          pendingSimpleTags.add((name: name, val: val));
        }
      }
      pos = dataEnd;
    }
    if (isSubFileScoped) {
      // Ignore track/chapter/attachment-scoped tags so audio/subtitle stream
      // metadata never masquerades as whole-file season/episode tags.
      return;
    }
    for (final st in pendingSimpleTags) {
      // Do not overwrite Info.Title unless empty; otherwise keep first tag.
      tags.putIfAbsent(st.name, () => st.val);
    }
  }

  // ---------------------------------------------------------------------------
  // MP4 / M4V ISO-BMFF Parser (moov -> udta -> meta -> ilst)
  // ---------------------------------------------------------------------------

  static Map<String, String> _readMp4Tags(
    RandomAccessFile raf,
    int fileLength,
  ) {
    final tags = <String, String>{};
    int offset = 0;
    int guard = 0;
    while (offset + 8 <= fileLength && guard++ < 64) {
      final hdr = _readBytesAt(raf, offset, 16);
      if (hdr.length < 8) break;
      final bd = ByteData.sublistView(hdr);
      int size = bd.getUint32(0, Endian.big);
      final type = String.fromCharCodes(hdr.sublist(4, 8));
      int headerLen = 8;
      if (size == 1) {
        if (hdr.length < 16) break;
        size = bd.getUint64(8, Endian.big);
        headerLen = 16;
      } else if (size == 0) {
        size = fileLength - offset;
      }
      if (size < headerLen || offset + size > fileLength) break;
      if (type == 'moov' && size <= _maxMp4MoovBytes) {
        final moov = _readBytesAt(raf, offset + headerLen, size - headerLen);
        _scanMp4Container(moov, 0, moov.length, tags, depth: 0);
        break;
      }
      offset += size;
    }
    return Map<String, String>.unmodifiable(tags);
  }

  static void _scanMp4Container(
    Uint8List buf,
    int start,
    int end,
    Map<String, String> tags, {
    required int depth,
  }) {
    if (depth > 6) return;
    int pos = start;
    while (pos + 8 <= end) {
      final bd = ByteData.sublistView(buf, pos, pos + 8);
      int size = bd.getUint32(0, Endian.big);
      final typeBytes = buf.sublist(pos + 4, pos + 8);
      final type = latin1.decode(typeBytes);
      int headerLen = 8;
      if (size == 1 && pos + 16 <= end) {
        size = ByteData.sublistView(buf, pos + 8, pos + 16)
            .getUint64(0, Endian.big);
        headerLen = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < headerLen || pos + size > end) break;
      final payloadStart = pos + headerLen;
      final payloadEnd = pos + size;
      if (type == 'udta') {
        _scanMp4Container(buf, payloadStart, payloadEnd, tags,
            depth: depth + 1);
      } else if (type == 'meta' && payloadEnd - payloadStart > 4) {
        // FullBox: skip 4 bytes of version/flags.
        _scanMp4Container(buf, payloadStart + 4, payloadEnd, tags,
            depth: depth + 1);
      } else if (type == 'ilst') {
        _parseMp4Ilst(buf, payloadStart, payloadEnd, tags);
      }
      pos = payloadEnd;
    }
  }

  static void _parseMp4Ilst(
    Uint8List buf,
    int start,
    int end,
    Map<String, String> tags,
  ) {
    int pos = start;
    while (pos + 8 <= end) {
      final bd = ByteData.sublistView(buf, pos, pos + 8);
      final size = bd.getUint32(0, Endian.big);
      if (size < 8 || pos + size > end) break;
      final type = latin1.decode(buf.sublist(pos + 4, pos + 8));
      final itemEnd = pos + size;
      final mappedKey = switch (type) {
        '\xA9nam' => 'title',
        'tvsh' => 'show',
        'tvsn' => 'season_number',
        'tves' => 'episode_sort',
        'tven' => 'episode_id',
        '\xA9cmt' => 'comment',
        _ => '',
      };
      if (mappedKey.isNotEmpty) {
        final value = _extractMp4DataAtom(buf, pos + 8, itemEnd);
        if (value != null && value.isNotEmpty) {
          tags.putIfAbsent(mappedKey, () => value);
        }
      }
      pos = itemEnd;
    }
  }

  static String? _extractMp4DataAtom(Uint8List buf, int start, int end) {
    int pos = start;
    while (pos + 16 <= end) {
      final bd = ByteData.sublistView(buf, pos, pos + 16);
      final size = bd.getUint32(0, Endian.big);
      final type = latin1.decode(buf.sublist(pos + 4, pos + 8));
      if (size < 16 || pos + size > end) break;
      if (type == 'data') {
        final dataType = bd.getUint32(8, Endian.big);
        final dataStart = pos + 16;
        final dataEnd = pos + size;
        if (dataType == 1) {
          // UTF-8 string
          return utf8
              .decode(buf.sublist(dataStart, dataEnd), allowMalformed: true)
              .replaceAll('\x00', '')
              .trim();
        }
        if ((dataType == 21 || dataType == 0) && dataEnd - dataStart >= 4) {
          final n = ByteData.sublistView(buf, dataStart, dataStart + 4)
              .getInt32(0, Endian.big);
          return '$n';
        }
      }
      pos += size;
    }
    return null;
  }
}

/// Process-wide bounded cache of container metadata tags keyed by stable
/// episode/file identity so DetailScreen, PlayerScreen, episode pickers, line
/// switching, and Danmu queries always share identical container-tag evidence.
class ContainerMetadataCache {
  ContainerMetadataCache._();

  static const int _maxEntries = 512;
  static final Map<String, Map<String, String>> _byStableKey =
      <String, Map<String, String>>{};
  static final Map<String, ({int length, int mtimeMs, Map<String, String> tags})>
      _byFilePath = <String, ({int length, int mtimeMs, Map<String, String> tags})>{};

  static Map<String, String> getByStableKey(String stableKey) {
    if (stableKey.isEmpty) return const <String, String>{};
    return _byStableKey[stableKey] ?? const <String, String>{};
  }

  static void putByStableKey(String stableKey, Map<String, String> tags) {
    if (stableKey.isEmpty || tags.isEmpty) return;
    if (_byStableKey.length >= _maxEntries && !_byStableKey.containsKey(stableKey)) {
      _byStableKey.remove(_byStableKey.keys.first);
    }
    final existing = _byStableKey[stableKey];
    if (existing == null || existing.isEmpty) {
      _byStableKey[stableKey] = Map<String, String>.unmodifiable(tags);
    } else {
      _byStableKey[stableKey] = Map<String, String>.unmodifiable({
        ...existing,
        ...tags,
      });
    }
  }

  static Map<String, String> probeLocalFileSync(String rawPathOrUri) {
    final path = ContainerMetadataReader.resolveLocalFilePath(rawPathOrUri);
    if (path == null) return const <String, String>{};
    try {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file) {
        return const <String, String>{};
      }
      final mtimeMs = stat.modified.millisecondsSinceEpoch;
      final cached = _byFilePath[path];
      if (cached != null &&
          cached.length == stat.size &&
          cached.mtimeMs == mtimeMs) {
        return cached.tags;
      }
      final parsed = ContainerMetadataReader.readLocalFileTagsSync(path);
      if (_byFilePath.length >= _maxEntries && !_byFilePath.containsKey(path)) {
        _byFilePath.remove(_byFilePath.keys.first);
      }
      _byFilePath[path] = (length: stat.size, mtimeMs: mtimeMs, tags: parsed);
      return parsed;
    } catch (_) {
      return const <String, String>{};
    }
  }

  static void clearForTest() {
    _byStableKey.clear();
    _byFilePath.clear();
  }
}
