// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ed25519.dart';

/// Parsed, cryptographically verified claims of an offline Ed25519 AI Lab
/// unlock passcode (`MMAILAB1.<payload_b64url>.<sig_b64url>`).
@immutable
class AiLabPasscodePayload {
  final int version;
  final String tag;
  final int issuedAtEpochSec;
  final int expiresAtEpochSec;
  final String platform;

  const AiLabPasscodePayload({
    required this.version,
    this.tag = '',
    this.issuedAtEpochSec = 0,
    this.expiresAtEpochSec = 0,
    this.platform = 'all',
  });

  /// Alias for display compatibility.
  String get id => tag;

  bool get hasExpiry => expiresAtEpochSec > 0;

  DateTime? get expiresAtUtc => hasExpiry
      ? DateTime.fromMillisecondsSinceEpoch(
          expiresAtEpochSec * 1000,
          isUtc: true,
        )
      : null;

  bool isExpiredAt(DateTime now) {
    if (!hasExpiry) return false;
    final nowSec = now.toUtc().millisecondsSinceEpoch ~/ 1000;
    return nowSec > expiresAtEpochSec;
  }

  bool matchesPlatform(String targetPlatform) {
    final p = platform.trim().toLowerCase();
    if (p.isEmpty || p == 'all') return true;
    return p == targetPlatform.trim().toLowerCase();
  }
}

enum AiLabPasscodeStatus {
  valid,
  empty,
  malformed,
  invalidSignature,
  unsupportedVersion,
  wrongPlatform,
  expired,
  missingPublicKey,
}

@immutable
class AiLabPasscodeVerifyResult {
  final AiLabPasscodeStatus status;
  final AiLabPasscodePayload? payload;
  final String canonicalToken;
  final String messageZh;

  const AiLabPasscodeVerifyResult({
    required this.status,
    required this.messageZh,
    this.payload,
    this.canonicalToken = '',
  });

  bool get isValid => status == AiLabPasscodeStatus.valid && payload != null;
}

/// Pure offline RFC 8032 Ed25519 verifier for Marco Movie AI Lab passcodes.
///
/// Unified cross-platform format (`scripts/sign_manifest.py issue-ai-lab-token`):
/// `MMAILAB1.<payload_b64url>.<sig_b64url>`
///
/// The Ed25519 signature covers:
/// `utf8("marco-ai-lab-v1:") + decoded_payload_bytes`
abstract final class AiLabPasscodeVerifier {
  static const String tokenPrefix = 'MMAILAB1';
  static const String signingDomainPrefix = 'marco-ai-lab-v1:';

  /// Embedded Marco Movie AI Lab Ed25519 public key (32 bytes / 64 hex chars).
  /// Public keys can ONLY verify offline signatures and cannot forge passcodes.
  /// May be overridden at compile time via `--dart-define=MARCO_AI_LAB_PUBKEY=...`.
  static const String _builtInPublicKeyHex =
      '1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929';

  static const String defaultPublicKeyHex = String.fromEnvironment(
    'MARCO_AI_LAB_PUBKEY',
    defaultValue: _builtInPublicKeyHex,
  );

  static final RegExp _tokenExtractRe = RegExp(
    r'MMAILAB1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)',
  );

  @visibleForTesting
  static String? debugPublicKeyHexOverride;

  static String effectivePublicKeyHex([String? overrideHex]) =>
      (overrideHex ?? debugPublicKeyHexOverride ?? defaultPublicKeyHex).trim();

  static Uint8List? _decodeHex32(String hex) {
    final cleaned = hex.trim();
    if (cleaned.length != 64) return null;
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final byte = int.tryParse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }

  static Uint8List? _decodeBase64UrlNoPad(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9\-_]+$').hasMatch(s)) return null;
    try {
      final normalized = base64Url.normalize(s);
      return Uint8List.fromList(base64Url.decode(normalized));
    } catch (_) {
      return null;
    }
  }

  /// Extracts a `MMAILAB1.<payload>.<sig>` token even when copied inside
  /// surrounding prose or wrapped across chat line breaks.
  static String extractToken(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final direct = _tokenExtractRe.firstMatch(trimmed);
    if (direct != null) return direct.group(0)!;
    final collapsed = trimmed.replaceAll(RegExp(r'\s+'), '');
    final afterCollapse = _tokenExtractRe.firstMatch(collapsed);
    if (afterCollapse != null) return afterCollapse.group(0)!;
    return collapsed;
  }

  /// Cryptographically verifies [rawPasscode] completely offline against the
  /// embedded Ed25519 public key (or [publicKeyHex] override).
  static AiLabPasscodeVerifyResult verify(
    String rawPasscode, {
    String? publicKeyHex,
    String targetPlatform = 'windows',
    DateTime? now,
  }) {
    final cleaned = extractToken(rawPasscode);
    if (cleaned.isEmpty) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.empty,
        messageZh: '请输入 AI 实验室解锁口令',
      );
    }

    final pubBytes = _decodeHex32(effectivePublicKeyHex(publicKeyHex));
    if (pubBytes == null) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.missingPublicKey,
        messageZh: '当前构建未配置有效的 Ed25519 验签公钥',
      );
    }

    final match = _tokenExtractRe.firstMatch(cleaned);
    if (match == null || match.group(0) != cleaned) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.malformed,
        messageZh: '口令格式无效，应为 $tokenPrefix.<载荷>.<签名>',
      );
    }

    final payloadB64 = match.group(1)!;
    final sigB64 = match.group(2)!;
    final payloadBytes = _decodeBase64UrlNoPad(payloadB64);
    final sigBytes = _decodeBase64UrlNoPad(sigB64);
    if (payloadBytes == null || sigBytes == null || sigBytes.length != 64) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.malformed,
        messageZh: '口令编码损坏，请确认完整复制了整段口令',
      );
    }

    final domainBytes = utf8.encode(signingDomainPrefix);
    final messageBytes = Uint8List(domainBytes.length + payloadBytes.length)
      ..setRange(0, domainBytes.length, domainBytes)
      ..setRange(domainBytes.length, domainBytes.length + payloadBytes.length,
          payloadBytes);

    final sigOk = Ed25519.verify(
      publicKey: pubBytes,
      message: messageBytes,
      signature: sigBytes,
    );
    if (!sigOk) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.invalidSignature,
        messageZh: '口令 Ed25519 离线签名校验失败，请核对口令是否完整有效',
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(payloadBytes));
    } catch (_) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.malformed,
        messageZh: '口令载荷无法解析',
      );
    }
    if (decoded is! Map) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.malformed,
        messageZh: '口令载荷结构无效',
      );
    }

    final version = (decoded['v'] as num?)?.toInt() ?? 0;
    if (version != 1) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.unsupportedVersion,
        messageZh: '该口令版本不受当前客户端支持',
      );
    }

    final tag = (decoded['tag'] ?? decoded['id'] ?? '').toString().trim();
    final iat = (decoded['iat'] as num?)?.toInt() ?? 0;
    final exp = (decoded['exp'] as num?)?.toInt() ?? 0;
    final platform = (decoded['plat'] ?? 'all').toString().trim();

    final payload = AiLabPasscodePayload(
      version: version,
      tag: tag,
      issuedAtEpochSec: iat < 0 ? 0 : iat,
      expiresAtEpochSec: exp < 0 ? 0 : exp,
      platform: platform.isEmpty ? 'all' : platform,
    );

    if (!payload.matchesPlatform(targetPlatform)) {
      return AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.wrongPlatform,
        payload: payload,
        messageZh: '该口令仅适用于 ${payload.platform} 平台，无法在当前端解锁',
      );
    }

    final currentTime = now ?? DateTime.now();
    if (payload.isExpiredAt(currentTime)) {
      return AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.expired,
        payload: payload,
        messageZh: '该 AI 实验室口令已过期，请获取新口令',
      );
    }

    final canonical = '$tokenPrefix.$payloadB64.$sigB64';
    return AiLabPasscodeVerifyResult(
      status: AiLabPasscodeStatus.valid,
      payload: payload,
      canonicalToken: canonical,
      messageZh: tag.isNotEmpty
          ? 'Ed25519 离线验签通过 · 已解锁 AI 实验室（$tag）'
          : 'Ed25519 离线验签通过 · 已解锁 AI 实验室',
    );
  }
}

/// Device-local store that persists the signed Ed25519 passcode token and
/// cryptographically re-verifies it on every load so tampering with a boolean
/// preference cannot bypass the gate.
class AiLabPasscodeStore extends ChangeNotifier {
  static const String prefsPasscodeKey = 'windows_ai_lab_unlock_passcode_v1';

  static final AiLabPasscodeStore instance = AiLabPasscodeStore();

  DateTime Function() _clock;
  String? _publicKeyHexOverride;
  String _targetPlatform;

  bool _loaded = false;
  Future<void>? _loadFuture;
  String _storedToken = '';
  AiLabPasscodePayload? _activePayload;

  AiLabPasscodeStore({
    DateTime Function()? clock,
    String? publicKeyHexOverride,
    String targetPlatform = 'windows',
  })  : _clock = clock ?? DateTime.now,
        _publicKeyHexOverride = publicKeyHexOverride,
        _targetPlatform = targetPlatform;

  bool get isLoaded => _loaded;

  /// True ONLY when a cryptographically verified, non-expired Ed25519 passcode
  /// is currently active.
  bool get isUnlocked {
    final payload = _activePayload;
    if (payload == null) return false;
    return !payload.isExpiredAt(_clock());
  }

  AiLabPasscodePayload? get activePayload => isUnlocked ? _activePayload : null;
  String get storedToken => isUnlocked ? _storedToken : '';

  @visibleForTesting
  void configureForTest({
    DateTime Function()? clock,
    String? publicKeyHexOverride,
    String? targetPlatform,
    bool resetState = false,
  }) {
    if (clock != null) _clock = clock;
    if (publicKeyHexOverride != null) {
      _publicKeyHexOverride = publicKeyHexOverride;
    }
    if (targetPlatform != null) _targetPlatform = targetPlatform;
    if (resetState) {
      _loaded = false;
      _loadFuture = null;
      _storedToken = '';
      _activePayload = null;
      notifyListeners();
    }
  }

  @visibleForTesting
  void resetForTest() {
    _clock = DateTime.now;
    _publicKeyHexOverride = null;
    _targetPlatform = 'windows';
    _loaded = false;
    _loadFuture = null;
    _storedToken = '';
    _activePayload = null;
    notifyListeners();
  }

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _doLoad();
  }

  Future<void> reload() {
    _loaded = false;
    _loadFuture = null;
    return ensureLoaded();
  }

  Future<void> _doLoad() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = (prefs.getString(prefsPasscodeKey) ?? '').trim();
      if (saved.isNotEmpty) {
        final verified = AiLabPasscodeVerifier.verify(
          saved,
          publicKeyHex: _publicKeyHexOverride,
          targetPlatform: _targetPlatform,
          now: _clock(),
        );
        if (verified.isValid) {
          _storedToken = verified.canonicalToken;
          _activePayload = verified.payload;
        } else {
          _storedToken = '';
          _activePayload = null;
        }
      } else {
        _storedToken = '';
        _activePayload = null;
      }
    } catch (_) {
      _storedToken = '';
      _activePayload = null;
    } finally {
      _loaded = true;
      _loadFuture = null;
      notifyListeners();
    }
  }

  /// Verifies [rawPasscode] offline with Ed25519 and persists the signed token
  /// locally when valid.
  Future<AiLabPasscodeVerifyResult> unlockWithPasscode(String rawPasscode) async {
    await ensureLoaded();
    final result = AiLabPasscodeVerifier.verify(
      rawPasscode,
      publicKeyHex: _publicKeyHexOverride,
      targetPlatform: _targetPlatform,
      now: _clock(),
    );
    if (!result.isValid) {
      return result;
    }
    _storedToken = result.canonicalToken;
    _activePayload = result.payload;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsPasscodeKey, result.canonicalToken);
    } catch (_) {}
    notifyListeners();
    return result;
  }

  /// Re-locks AI Lab and removes the locally persisted passcode token.
  Future<void> lock() async {
    await ensureLoaded();
    _storedToken = '';
    _activePayload = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsPasscodeKey);
    } catch (_) {}
    notifyListeners();
  }
}
