// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ed25519.dart';

/// Parsed, cryptographically verified claims of a unified cross-platform
/// offline Ed25519 AI Lab unlock passcode (`MMAILAB1.<payload_b64url>.<sig_b64url>`).
@immutable
class AiLabPasscodePayload {
  final int version;
  final String tag;
  final int issuedAtEpochSec;
  final int expiresAtEpochSec;
  final String platform;
  final bool shared;
  final bool experimentalOAuth;
  final int minVersionCode;
  final String nonce;

  const AiLabPasscodePayload({
    required this.version,
    this.tag = '',
    this.issuedAtEpochSec = 0,
    this.expiresAtEpochSec = 0,
    this.platform = 'all',
    this.shared = false,
    this.experimentalOAuth = false,
    this.minVersionCode = 0,
    this.nonce = '',
  });

  /// Alias for display compatibility.
  String get id => tag;

  bool get hasExpiry => expiresAtEpochSec > 0;

  bool get isPermanent => !hasExpiry;

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

  bool requiresNewerVersion(int currentVersionCode) {
    if (minVersionCode <= 0 || currentVersionCode <= 0) return false;
    return currentVersionCode < minVersionCode;
  }

  /// Normalizes platform names and aliases across Windows / iOS / Android / macOS.
  static String normalizePlatformName(String raw) {
    final p = raw.trim().toLowerCase();
    return switch (p) {
      'android-mobile' || 'mobile' => 'android',
      'win' || 'pc' => 'windows',
      'iphone' || 'ipad' => 'ios',
      'mac' || 'osx' => 'macos',
      '*' => 'all',
      _ => p,
    };
  }

  /// Alias for compatibility.
  static String normalizePlatformToken(String raw) => normalizePlatformName(raw);

  /// Returns `true` when this passcode permits [targetPlatform].
  bool matchesPlatform(String targetPlatform) {
    final rawPlat = platform.trim().toLowerCase();
    if (rawPlat.isEmpty || rawPlat == 'all' || rawPlat == '*') {
      return true;
    }
    final normalizedTarget = normalizePlatformName(targetPlatform);
    if (normalizedTarget.isEmpty ||
        normalizedTarget == 'all' ||
        normalizedTarget == '*') {
      return true;
    }
    final parts = rawPlat
        .split(RegExp(r'[,;/\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return true;
    }
    for (final part in parts) {
      if (part == 'all' || part == '*') return true;
      if (normalizePlatformName(part) == normalizedTarget) {
        return true;
      }
    }
    return false;
  }

  /// Human-readable Chinese label for the passcode's platform scope.
  String get platformScopeLabelZh => formatPlatformScopeZh(platform);

  static String formatPlatformScopeZh(String platformSpec) {
    final p = platformSpec.trim().toLowerCase();
    if (p.isEmpty || p == 'all' || p == '*') return '三端通用';
    var hasAnd = false;
    var hasIos = false;
    var hasWin = false;
    final extras = <String>[];
    for (final part in p.split(RegExp(r'[,;/\s]+'))) {
      final tok = normalizePlatformName(part);
      if (tok.isEmpty) continue;
      if (tok == 'all') return '三端通用';
      if (tok == 'android') {
        hasAnd = true;
      } else if (tok == 'ios') {
        hasIos = true;
      } else if (tok == 'windows') {
        hasWin = true;
      } else if (!extras.contains(tok)) {
        extras.add(tok);
      }
    }
    if (hasAnd && hasIos && hasWin && extras.isEmpty) return '三端通用';
    final names = <String>[
      if (hasAnd) '安卓',
      if (hasIos) 'iOS',
      if (hasWin) 'Windows',
      ...extras,
    ];
    if (names.isEmpty) return '三端通用';
    return '仅限 ${names.join('/')}';
  }

  String get channelTypeLabelZh => shared ? '频道通用' : '专属内测';

  String get expiryDateUtcString {
    if (!hasExpiry) return '永久有效';
    final dt = expiresAtUtc!;
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String get expiryLabelZh =>
      !hasExpiry ? '永久有效' : '有效至 $expiryDateUtcString';

  String get summaryBadgeZh {
    final labelTag = tag.trim().isEmpty ? '内测口令' : tag.trim();
    final oauthPart = experimentalOAuth ? ' · 含实验性 OAuth' : '';
    return '$labelTag · $platformScopeLabelZh · $channelTypeLabelZh$oauthPart · $expiryLabelZh';
  }
}

enum AiLabPasscodeStatus {
  valid,
  empty,
  malformed,
  invalidSignature,
  unsupportedVersion,
  wrongPlatform,
  versionTooOld,
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
/// Unified cross-platform format (`Windows` / `iOS` / `Android Mobile`):
/// `MMAILAB1.<payload_b64url_nopad>.<sig_b64url_nopad>`
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

  /// Optional test-only public key hex override for ephemeral Ed25519 signers.
  static String? debugPublicKeyHexOverride;

  static String effectivePublicKeyHex([String? overrideHex]) =>
      (overrideHex ?? debugPublicKeyHexOverride ?? defaultPublicKeyHex).trim();

  /// Auto-detects the current host platform identifier (`windows` / `ios` /
  /// `macos` / `android` / `linux` / `web`) across all Flutter editions.
  static String detectCurrentPlatform() {
    if (kIsWeb) return 'web';
    final override = debugDefaultTargetPlatformOverride;
    if (override != null) {
      return override.name.toLowerCase();
    }
    if (Platform.isWindows) return 'windows';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  static String resolveRuntimeTargetPlatform() => detectCurrentPlatform();

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
    var s = raw.trim();
    while (s.endsWith('=')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty || (s.length % 4) == 1) return null;
    if (!RegExp(r'^[A-Za-z0-9\-_]+$').hasMatch(s)) return null;
    try {
      final normalized = base64Url.normalize(s);
      return Uint8List.fromList(base64Url.decode(normalized));
    } catch (_) {
      return null;
    }
  }

  static bool _parseBoolFlag(Object? raw, {bool fallback = false}) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final lower = raw.trim().toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
    return fallback;
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
    String? targetPlatform,
    int? currentVersionCode,
    DateTime? now,
  }) {
    final cleaned = extractToken(rawPasscode);
    if (cleaned.isEmpty) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.empty,
        messageZh: '请输入 AI 观影实验室解锁口令',
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
    if (payloadBytes == null ||
        payloadBytes.isEmpty ||
        sigBytes == null ||
        sigBytes.length != 64) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.malformed,
        messageZh: '口令编码损坏，请确认完整复制了整段口令',
      );
    }

    final domainBytes = utf8.encode(signingDomainPrefix);
    final messageBytes = Uint8List(domainBytes.length + payloadBytes.length)
      ..setRange(0, domainBytes.length, domainBytes)
      ..setRange(
        domainBytes.length,
        domainBytes.length + payloadBytes.length,
        payloadBytes,
      );

    final sigOk = Ed25519.verify(
      publicKey: pubBytes,
      message: messageBytes,
      signature: sigBytes,
    );
    if (!sigOk) {
      return const AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.invalidSignature,
        messageZh: '口令 Ed25519 离线签名校验失败，请确认来源为官方渠道',
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
      return AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.unsupportedVersion,
        messageZh: '不支持的口令版本（v$version），请前往官网更新应用',
      );
    }

    final tag = (decoded['tag'] ?? decoded['id'] ?? '').toString().trim();
    final iat = (decoded['iat'] as num?)?.toInt() ?? 0;
    final exp = (decoded['exp'] as num?)?.toInt() ?? 0;
    final platformRaw = (decoded['plat'] ?? 'all').toString().trim();
    final shared = _parseBoolFlag(decoded['shared']);
    final expOAuth = _parseBoolFlag(decoded['exp_oauth']);
    final minVc = (decoded['min_vc'] as num?)?.toInt() ?? 0;
    final nonce = (decoded['n'] ?? '').toString().trim();

    final payload = AiLabPasscodePayload(
      version: version,
      tag: tag,
      issuedAtEpochSec: iat < 0 ? 0 : iat,
      expiresAtEpochSec: exp < 0 ? 0 : exp,
      platform: platformRaw.isEmpty ? 'all' : platformRaw,
      shared: shared,
      experimentalOAuth: expOAuth,
      minVersionCode: minVc < 0 ? 0 : minVc,
      nonce: nonce,
    );

    final effectivePlatform = (targetPlatform ?? '').trim().isNotEmpty
        ? targetPlatform!.trim()
        : detectCurrentPlatform();
    if (!payload.matchesPlatform(effectivePlatform)) {
      return AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.wrongPlatform,
        payload: payload,
        messageZh:
            '该内测口令适用范围为「${payload.platformScopeLabelZh}」，不适用于当前设备平台（$effectivePlatform）',
      );
    }

    if (payload.minVersionCode > 0 &&
        currentVersionCode != null &&
        currentVersionCode > 0 &&
        currentVersionCode < payload.minVersionCode) {
      return AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.versionTooOld,
        payload: payload,
        messageZh:
            '该口令要求更高版本客户端（最低构建号 ${payload.minVersionCode}），请先更新应用',
      );
    }

    final currentTime = now ?? DateTime.now();
    if (payload.isExpiredAt(currentTime)) {
      return AiLabPasscodeVerifyResult(
        status: AiLabPasscodeStatus.expired,
        payload: payload,
        messageZh: '该内测口令已过期，请前往官方交流频道【Marco交流区】获取新口令',
      );
    }

    final canonical = '$tokenPrefix.$payloadB64.$sigB64';
    return AiLabPasscodeVerifyResult(
      status: AiLabPasscodeStatus.valid,
      payload: payload,
      canonicalToken: canonical,
      messageZh: tag.isNotEmpty
          ? 'Ed25519 离线验签通过 · 已开启 AI 观影实验室（$tag）'
          : 'Ed25519 离线验签通过 · 已开启 AI 观影实验室',
    );
  }
}

/// Device-local store that persists ONLY the signed Ed25519 passcode token
/// string (never a plaintext boolean flag) and cryptographically re-verifies
/// signature, target platform, and expiration on every load and status read.
class AiLabPasscodeStore extends ChangeNotifier {
  static const String prefsPasscodeKey = 'windows_ai_lab_unlock_passcode_v1';
  static const String altPrefsPasscodeKey = 'marco_ai_lab_unlock_passcode_v1';

  static final AiLabPasscodeStore instance = AiLabPasscodeStore();

  DateTime Function() _clock;
  String? _publicKeyHexOverride;
  String? _targetPlatformOverride;
  int? _currentVersionCode;

  bool _loaded = false;
  Future<void>? _loadFuture;
  String _storedToken = '';

  String _sigVerifiedToken = '';
  String _sigVerifiedPubKeyHex = '';
  AiLabPasscodePayload? _sigVerifiedPayload;

  AiLabPasscodeStore({
    DateTime Function()? clock,
    String? publicKeyHexOverride,
    String? targetPlatform,
    int? currentVersionCode,
  })  : _clock = clock ?? DateTime.now,
        _publicKeyHexOverride = publicKeyHexOverride,
        _targetPlatformOverride = targetPlatform,
        _currentVersionCode = currentVersionCode;

  bool get isLoaded => _loaded;

  String get effectiveTargetPlatform =>
      (_targetPlatformOverride != null &&
              _targetPlatformOverride!.trim().isNotEmpty)
          ? _targetPlatformOverride!.trim().toLowerCase()
          : AiLabPasscodeVerifier.detectCurrentPlatform();

  AiLabPasscodePayload? _evaluateVerifiedPayloadAt(DateTime now) {
    final raw = _storedToken.trim();
    if (raw.isEmpty) return null;
    final pubHex = AiLabPasscodeVerifier.effectivePublicKeyHex(
      _publicKeyHexOverride,
    );
    AiLabPasscodePayload? payload;
    if (_sigVerifiedToken == raw &&
        _sigVerifiedPubKeyHex == pubHex &&
        _sigVerifiedPayload != null) {
      payload = _sigVerifiedPayload;
    } else {
      final res = AiLabPasscodeVerifier.verify(
        raw,
        publicKeyHex: _publicKeyHexOverride,
        targetPlatform: effectiveTargetPlatform,
        currentVersionCode: _currentVersionCode,
        now: now,
      );
      if (!res.isValid) return null;
      _sigVerifiedToken = res.canonicalToken;
      _sigVerifiedPubKeyHex = pubHex;
      _sigVerifiedPayload = res.payload;
      payload = res.payload;
    }
    if (payload == null) return null;
    if (!payload.matchesPlatform(effectiveTargetPlatform)) return null;
    if (payload.minVersionCode > 0 &&
        _currentVersionCode != null &&
        _currentVersionCode! > 0 &&
        _currentVersionCode! < payload.minVersionCode) {
      return null;
    }
    if (payload.isExpiredAt(now)) return null;
    return payload;
  }

  bool isUnlockedAt(DateTime now) => _evaluateVerifiedPayloadAt(now) != null;

  bool get isUnlocked => isUnlockedAt(_clock());

  AiLabPasscodePayload? activePayloadAt(DateTime now) =>
      _evaluateVerifiedPayloadAt(now);

  AiLabPasscodePayload? get activePayload => activePayloadAt(_clock());

  bool get isExperimentalOAuthAllowed =>
      activePayload?.experimentalOAuth == true;

  String get storedToken => isUnlocked ? _storedToken : '';

  /// `true` whenever any raw passcode token has been stored (even if it has
  /// since expired), so callers can enforce re-lock on expiry.
  bool get hasStoredToken => _storedToken.trim().isNotEmpty;

  @visibleForTesting
  void configureForTest({
    DateTime Function()? clock,
    String? publicKeyHexOverride,
    String? targetPlatform,
    int? currentVersionCode,
    bool resetState = false,
  }) {
    if (clock != null) _clock = clock;
    if (publicKeyHexOverride != null) {
      _publicKeyHexOverride = publicKeyHexOverride;
    }
    if (targetPlatform != null) {
      _targetPlatformOverride = targetPlatform;
    }
    if (currentVersionCode != null) {
      _currentVersionCode = currentVersionCode;
    }
    if (resetState) {
      _loaded = false;
      _loadFuture = null;
      _storedToken = '';
      _sigVerifiedToken = '';
      _sigVerifiedPubKeyHex = '';
      _sigVerifiedPayload = null;
    }
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _clock = DateTime.now;
    _publicKeyHexOverride = null;
    _targetPlatformOverride = null;
    _currentVersionCode = null;
    _loaded = false;
    _loadFuture = null;
    _storedToken = '';
    _sigVerifiedToken = '';
    _sigVerifiedPubKeyHex = '';
    _sigVerifiedPayload = null;
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
      var saved = (prefs.getString(prefsPasscodeKey) ?? '').trim();
      if (saved.isEmpty) {
        saved = (prefs.getString(altPrefsPasscodeKey) ?? '').trim();
      }
      if (saved.isNotEmpty) {
        final verified = AiLabPasscodeVerifier.verify(
          saved,
          publicKeyHex: _publicKeyHexOverride,
          targetPlatform: effectiveTargetPlatform,
          currentVersionCode: _currentVersionCode,
          now: _clock(),
        );
        if (verified.isValid) {
          _storedToken = verified.canonicalToken;
          _sigVerifiedToken = verified.canonicalToken;
          _sigVerifiedPubKeyHex = AiLabPasscodeVerifier.effectivePublicKeyHex(
            _publicKeyHexOverride,
          );
          _sigVerifiedPayload = verified.payload;
        } else {
          _storedToken = '';
          _sigVerifiedToken = '';
          _sigVerifiedPubKeyHex = '';
          _sigVerifiedPayload = null;
        }
      } else {
        _storedToken = '';
        _sigVerifiedToken = '';
        _sigVerifiedPubKeyHex = '';
        _sigVerifiedPayload = null;
      }
    } catch (_) {
      _storedToken = '';
      _sigVerifiedToken = '';
      _sigVerifiedPubKeyHex = '';
      _sigVerifiedPayload = null;
    } finally {
      _loaded = true;
      _loadFuture = null;
      notifyListeners();
    }
  }

  /// Verifies [rawPasscode] offline with Ed25519 and persists the signed token
  /// locally when valid.
  Future<AiLabPasscodeVerifyResult> unlockWithPasscode(
    String rawPasscode, {
    DateTime? nowOverride,
  }) async {
    await ensureLoaded();
    final evalNow = nowOverride ?? _clock();
    final result = AiLabPasscodeVerifier.verify(
      rawPasscode,
      publicKeyHex: _publicKeyHexOverride,
      targetPlatform: effectiveTargetPlatform,
      currentVersionCode: _currentVersionCode,
      now: evalNow,
    );
    if (!result.isValid) {
      return result;
    }
    _storedToken = result.canonicalToken;
    _sigVerifiedToken = result.canonicalToken;
    _sigVerifiedPubKeyHex = AiLabPasscodeVerifier.effectivePublicKeyHex(
      _publicKeyHexOverride,
    );
    _sigVerifiedPayload = result.payload;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsPasscodeKey, result.canonicalToken);
      await prefs.setString(altPrefsPasscodeKey, result.canonicalToken);
    } catch (_) {}
    notifyListeners();
    return result;
  }

  /// Re-locks AI Lab and removes the locally persisted passcode token.
  Future<void> lock() async {
    await ensureLoaded();
    _storedToken = '';
    _sigVerifiedToken = '';
    _sigVerifiedPubKeyHex = '';
    _sigVerifiedPayload = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsPasscodeKey);
      await prefs.remove(altPrefsPasscodeKey);
    } catch (_) {}
    notifyListeners();
  }
}
