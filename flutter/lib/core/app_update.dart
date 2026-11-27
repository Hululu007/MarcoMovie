import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'ed25519.dart';
import 'macos_window_bounds.dart';
import 'ohos_runtime.dart';

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// Relationship between a remote release version and the locally running version.
enum UpdateVersionRelation {
  remoteNewer,
  sameVersion,
  remoteOlder,
}

/// How the currently running Windows binary was distributed.
enum WindowsDistributionKind {
  installer,
  portable,
}

/// One verified downloadable package advertised by a release manifest.
class UpdateAsset {
  final String fileName;
  final Uri url;
  final String checksum;
  final int size;

  const UpdateAsset({
    required this.fileName,
    required this.url,
    required this.checksum,
    required this.size,
  });
}

/// Resolved runtime installation info for the currently executing Windows app.
class WindowsInstallInfo {
  final WindowsDistributionKind distribution;
  final String executablePath;
  final String installDirectory;
  final bool matchedRegisteredInstall;
  final bool hasLocalUninstaller;

  const WindowsInstallInfo({
    required this.distribution,
    required this.executablePath,
    required this.installDirectory,
    this.matchedRegisteredInstall = false,
    this.hasLocalUninstaller = false,
  });

  bool get isPortable => distribution == WindowsDistributionKind.portable;
  bool get isInstaller => distribution == WindowsDistributionKind.installer;
}

/// Determines whether the currently running Windows EXE belongs to an Inno Setup
/// installation or a portable ZIP extraction based strictly on the running EXE
/// path (so having both editions installed on the same PC never confuses them).
class WindowsInstallDetector {
  static const String innoAppIdUninstallKey =
      '{8E9A5D2B-4F31-4C19-9A62-7B8D1E3F4A50}_is1';

  static String normalizeWindowsDir(String raw) {
    var s = raw.trim();
    while (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      s = s.substring(1, s.length - 1).trim();
    }
    s = s.replaceAll('/', r'\');
    while (s.length > 3 && s.endsWith(r'\')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.length == 2 && s[1] == ':') {
      s = '$s\\';
    }
    return s.toLowerCase();
  }

  static bool _containsCaseInsensitiveAsciiOrUtf16Le(
    Uint8List bytes,
    String asciiLowerNeedle,
  ) {
    final needle = asciiLowerNeedle.codeUnits;
    if (needle.isEmpty || bytes.length < needle.length) return false;
    int toLowerAscii(int b) => (b >= 65 && b <= 90) ? (b + 32) : b;

    final asciiLimit = bytes.length - needle.length;
    for (var i = 0; i <= asciiLimit; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (toLowerAscii(bytes[i + j]) != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }

    final utf16Len = needle.length * 2;
    if (bytes.length < utf16Len) return false;
    final utf16Limit = bytes.length - utf16Len;
    for (var i = 0; i <= utf16Limit; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (toLowerAscii(bytes[i + j * 2]) != needle[j] ||
            bytes[i + j * 2 + 1] != 0) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  static bool _isMarcoMovieUninstallLog(File datFile) {
    try {
      final stat = datFile.statSync();
      if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) return false;
      final bytes = datFile.readAsBytesSync();
      const markers = <String>[
        '{8e9a5d2b-4f31-4c19-9a62-7b8d1e3f4a50}',
        'marco_movie.exe',
        'marco movie',
      ];
      for (final marker in markers) {
        if (_containsCaseInsensitiveAsciiOrUtf16Le(bytes, marker)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  static bool hasInnoUninstallerInDirectory(String directoryPath) {
    if (directoryPath.trim().isEmpty) return false;
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return false;
    try {
      final filesByLowerName = <String, File>{};
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          final seg = entity.path
              .split(RegExp(r'[\\/]'))
              .where((s) => s.isNotEmpty)
              .lastOrNull;
          if (seg != null) filesByLowerName[seg.toLowerCase()] = entity;
        }
      }
      final uninsExeRe = RegExp(r'^unins(\d{3})\.exe$');
      for (final name in filesByLowerName.keys) {
        final m = uninsExeRe.firstMatch(name);
        if (m == null) continue;
        final datFile = filesByLowerName['unins${m.group(1)}.dat'];
        if (datFile != null && _isMarcoMovieUninstallLog(datFile)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  static Future<List<String>> queryRegisteredInstallLocations() async {
    if (kIsWeb || !Platform.isWindows) return const [];
    final paths = <String>[];
    const regKeys = <String>[
      'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$innoAppIdUninstallKey',
      'HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$innoAppIdUninstallKey',
      'HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$innoAppIdUninstallKey',
    ];
    for (final key in regKeys) {
      for (final valueName in const ['InstallLocation', 'Inno Setup: App Path']) {
        try {
          final result = await Process.run(
            'reg.exe',
            ['query', key, '/v', valueName],
          ).timeout(const Duration(seconds: 2));
          if (result.exitCode != 0) continue;
          final stdoutText = result.stdout?.toString() ?? '';
          for (final line in stdoutText.split(RegExp(r'\r?\n'))) {
            final match = RegExp(
              r'^\s*' + RegExp.escape(valueName) + r'\s+REG_\w+\s+(.+?)\s*$',
              caseSensitive: false,
            ).firstMatch(line);
            if (match != null) {
              final val = match.group(1)!.trim();
              if (val.isNotEmpty) paths.add(val);
            }
          }
        } catch (_) {}
      }
    }
    return paths;
  }

  static Future<WindowsInstallInfo> detect({
    String? executablePath,
    List<String>? registeredInstallLocations,
    bool? hasLocalUninstallerOverride,
  }) async {
    final exe = (executablePath ?? Platform.resolvedExecutable).trim();
    final runningDir = File(exe).parent.path;
    final normRunningDir = normalizeWindowsDir(runningDir);
    final registered =
        registeredInstallLocations ?? await queryRegisteredInstallLocations();
    final matchedReg = registered.any(
      (loc) =>
          loc.trim().isNotEmpty && normalizeWindowsDir(loc) == normRunningDir,
    );
    final hasLocalUnins =
        hasLocalUninstallerOverride ?? hasInnoUninstallerInDirectory(runningDir);
    final kind = (matchedReg || hasLocalUnins)
        ? WindowsDistributionKind.installer
        : WindowsDistributionKind.portable;
    return WindowsInstallInfo(
      distribution: kind,
      executablePath: exe,
      installDirectory: runningDir,
      matchedRegisteredInstall: matchedReg,
      hasLocalUninstaller: hasLocalUnins,
    );
  }
}

/// Cancellation also releases the underlying HTTP request, not just its UI.
class UpdateCancellation {
  final _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!isCancelled) _done.complete();
  }

  void check() {
    if (isCancelled) throw const UpdateCancelled();
  }

  Future<T> bind<T>(Future<T> work) => Future.any([
        work,
        whenCancelled.then<T>((_) => throw const UpdateCancelled()),
      ]);
}

class AppUpdate {
  /// 用于校验更新清单的 Ed25519 公钥（64 位十六进制字符串），默认为空（不启用验签）。
  /// 正式启用需要项目所有者离线生成密钥对，私钥不得进入仓库。
  static const String defaultUpdatePublicKeyHex = '';

  /// Optional testing override for unit tests.
  @visibleForTesting
  static String? debugPublicKeyHexOverride;

  /// Optional testing override for the running iOS major version (e.g. `14` vs
  /// `15`/`26`) so unit tests can exercise iOS 14 / 15+ package routing on any
  /// host OS.
  @visibleForTesting
  static int? debugIosMajorVersionOverride;

  /// Optional testing HTTP client override used when UI flows call `AppUpdate.check()`.
  @visibleForTesting
  static http.Client? debugHttpClientOverride;

  /// Parses the major iOS version number from [osVersion] (for example
  /// `"Version 14.8.1 (Build 18H107)"` -> `14`). Returns `null` if unknown.
  static int? parseIosMajorVersion(String osVersion) {
    final trimmed = osVersion.trim();
    if (trimmed.isEmpty) return null;
    final match = RegExp(
          r'(?:Version|iOS|iPadOS)\s+(\d+)(?:\.\d+)*',
          caseSensitive: false,
        ).firstMatch(trimmed) ??
        RegExp(r'^(\d+)(?:\.\d+)+').firstMatch(trimmed);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// True when the current device runs iOS < 15.0 (i.e. iOS 14.x) and must
  /// pull the dedicated `MarcoMovie-<v>-ios14-unsigned.ipa` compatibility
  /// package instead of the iOS 15.0+ Liquid Glass main IPA.
  static bool get prefersIos14CompatPackage {
    final override = debugIosMajorVersionOverride;
    if (override != null) return override < 15;
    if (!Platform.isIOS) return false;
    final major = parseIosMajorVersion(Platform.operatingSystemVersion);
    return major != null && major < 15;
  }

  static Set<String> _iosAssetNames(String version, {required bool ios14}) =>
      ios14
          ? <String>{'MarcoMovie-$version-ios14-unsigned.ipa'}
          : <String>{
              'MarcoMovie-$version-ios-unsigned.ipa',
              'MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa',
            };
  static String _effectivePublicKeyHex([String? publicKeyHex]) =>
      (publicKeyHex ?? debugPublicKeyHexOverride ?? defaultUpdatePublicKeyHex)
          .trim();

  static bool _hasSignatureField(Map<String, dynamic> body) =>
      (body['signature'] ?? body['sig']) != null;

  /// Extracts only the signed portion of [body].
  /// When `payload` is present, only `payload` is returned and any unsigned
  /// outer fields (outside `payload`, `signature`, `sig`) cause rejection.
  static Map<String, dynamic>? extractSignedPayload(Map<String, dynamic> body) {
    if (body.containsKey('payload')) {
      final rawPayload = body['payload'];
      if (rawPayload is! Map) return null;
      for (final key in body.keys) {
        if (key != 'payload' && key != 'signature' && key != 'sig') {
          return null;
        }
      }
      return Map<String, dynamic>.from(rawPayload);
    }
    return Map<String, dynamic>.from(body)
      ..remove('signature')
      ..remove('sig');
  }

  static String canonicalizeJson(dynamic obj) {
    if (obj is Map) {
      final sortedKeys = obj.keys.map((k) => k.toString()).toList()..sort();
      final parts = <String>[];
      for (final k in sortedKeys) {
        parts.add('${jsonEncode(k)}:${canonicalizeJson(obj[k])}');
      }
      return '{${parts.join(',')}}';
    } else if (obj is List) {
      return '[${obj.map(canonicalizeJson).join(',')}]';
    } else if (obj is String) {
      return jsonEncode(obj);
    } else if (obj is bool) {
      return obj ? 'true' : 'false';
    } else if (obj == null) {
      return 'null';
    } else if (obj is num) {
      return obj.toString();
    }
    return jsonEncode(obj);
  }

  static bool verifyManifestSignature(
    Map<String, dynamic> body, {
    String? publicKeyHex,
  }) {
    final pubHex = _effectivePublicKeyHex(publicKeyHex);
    if (pubHex.isEmpty || pubHex.length != 64) {
      return false;
    }
    final rawSig = body['signature'] ?? body['sig'];
    if (rawSig is! String || rawSig.trim().isEmpty) {
      return false;
    }
    final payload = extractSignedPayload(body);
    if (payload == null) {
      return false;
    }
    final canonical = canonicalizeJson(payload);
    final messageBytes = Uint8List.fromList(utf8.encode(canonical));
    try {
      final sigBytes = base64Decode(rawSig);
      final pubBytes = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        pubBytes[i] = int.parse(pubHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return Ed25519.verify(
        publicKey: pubBytes,
        message: messageBytes,
        signature: sigBytes,
      );
    } on FormatException catch (e) {
      debugPrint('AppUpdate: 签名或公钥格式无效: $e');
      return false;
    }
  }

  static const String harmonyosUnsignedInstallGuide =
      '鸿蒙发布包为未签名通用 HAP（支持 arm64-v8a 手机 / 平板 / 2in1 / 智慧屏）。'
      '下载后请先核对 SHA-256 摘要，使用 DevEco Studio 自动签名或 hap-sign-tool 签名，'
      '再通过 hdc install 覆盖安装（使用相同签名覆盖升级将保留本机订阅、收藏、观看进度与安全凭据）。';

  static int compareVersions(String a, String b) {
    List<int> parseParts(String raw) {
      final clean = raw.trim().replaceFirst(RegExp(r'^[vV]'), '').split('-').first;
      return clean
          .split(RegExp(r'[^0-9]+'))
          .where((s) => s.isNotEmpty)
          .map((p) => int.tryParse(p.trim()) ?? 0)
          .toList(growable: false);
    }

    final pa = parseParts(a);
    final pb = parseParts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var idx = 0; idx < len; idx++) {
      final va = idx < pa.length ? pa[idx] : 0;
      final vb = idx < pb.length ? pb[idx] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  static UpdateVersionRelation compareVersionRelation(
    String remote,
    String installed,
  ) {
    final cmp = compareVersions(remote, installed);
    if (cmp > 0) return UpdateVersionRelation.remoteNewer;
    if (cmp < 0) return UpdateVersionRelation.remoteOlder;
    return UpdateVersionRelation.sameVersion;
  }

  static bool isRemoteVersionNewer(String remote, String installed) =>
      compareVersions(remote, installed) > 0;

  static bool isValidHarmonyosAssetName(String name, String version) =>
      name == 'MarcoMovie-$version-harmonyos-universal.hap' ||
      name == 'MarcoMovie-$version-harmonyos.hap';

  static bool isValidHarmonyosAssetPath(Uri uri, String version) =>
      uri.path.endsWith('/MarcoMovie-$version-harmonyos-universal.hap') ||
      uri.path.endsWith('/MarcoMovie-$version-harmonyos.hap');

  static Uri? trustedReleasePage(dynamic value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }
    if (uri.host == 'github.com' &&
            uri.path.startsWith('/Pilipala9919/MarcoMovie/releases/') ||
        uri.host == 'marcotv.wlj9919.top' && uri.path.startsWith('/movie/')) {
      return uri;
    }
    return null;
  }

  final String version;
  final String notes;
  final Uri? windowsUrl;
  final String? checksum;
  final int? size;
  final Uri? iosUrl;
  final Uri? macosUrl;
  final Uri? harmonyosUrl;
  final Uri? releaseUrl;
  final String? packageFileName;
  final UpdateAsset? windowsSetupAsset;
  final UpdateAsset? windowsPortableAsset;
  const AppUpdate(
    this.version,
    this.notes,
    this.windowsUrl,
    this.checksum,
    this.size, [
    this.iosUrl,
    this.macosUrl,
    this.harmonyosUrl,
    this.releaseUrl,
    this.packageFileName,
    this.windowsSetupAsset,
    this.windowsPortableAsset,
  ]);

  static List<String> macosAssetNames(String version) => <String>[
        'MarcoMovie-$version-macos-desktop.zip',
        'MarcoMovie-$version-macos.zip',
      ];

  static bool _isTrustedMacosAssetPath(String path, String version) =>
      path.endsWith('/MarcoMovie-$version-macos-desktop.zip') ||
      path.endsWith('/MarcoMovie-$version-macos.zip');

  /// Selects the verified Windows package matching [distribution].
  UpdateAsset? windowsAssetFor(WindowsDistributionKind distribution) {
    if (distribution == WindowsDistributionKind.portable) {
      return windowsPortableAsset;
    }
    if (windowsSetupAsset != null) return windowsSetupAsset;
    final url = windowsUrl;
    final sha = checksum;
    final len = size;
    if (url != null && sha != null && len != null && len > 0) {
      final name = url.pathSegments.isNotEmpty
          ? url.pathSegments.last
          : 'MarcoMovie-$version-windows-setup.exe';
      return UpdateAsset(
        fileName: name,
        url: url,
        checksum: sha,
        size: len,
      );
    }
    return null;
  }

  static bool isValidWindowsSetupAssetName(String name, String version) =>
      name == 'MarcoMovie-$version-windows-x64-setup.exe' ||
      name == 'MarcoMovie-$version-windows-setup.exe';

  static bool isValidWindowsPortableAssetName(String name, String version) =>
      name == 'MarcoMovie-$version-windows-x64-portable.zip' ||
      name == 'MarcoMovie-$version-windows-x64.zip';

  static UpdateAsset? _parseVerifiedAsset(
    Map? data, {
    required bool github,
    required List<String> allowedFileNames,
  }) {
    if (data == null) return null;
    final digest = (github ? data['digest'] : data['sha256'])
        ?.toString()
        .replaceFirst('sha256:', '')
        .trim();
    final rawSize = data['size'];
    final sizeVal = rawSize is int ? rawSize : null;
    final uri =
        trustedAsset(github ? data['browser_download_url'] : data['url']);
    if (uri == null ||
        digest == null ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) ||
        sizeVal == null ||
        sizeVal <= 0) {
      return null;
    }
    for (final fileName in allowedFileNames) {
      if (uri.path.endsWith('/$fileName')) {
        return UpdateAsset(
          fileName: fileName,
          url: uri,
          checksum: digest.toLowerCase(),
          size: sizeVal,
        );
      }
    }
    return null;
  }

  Uri? downloadUrlForPlatform([String? platform]) {
    final target = platform ?? currentPlatform;
    return switch (target) {
      'windows' => windowsUrl,
      'ios' => iosUrl,
      'macos' => macosUrl,
      'harmonyos' => harmonyosUrl,
      _ => null,
    };
  }

  // Only use the advertised asset. The download site does not host large IPAs.
  Uri get iosMirrorIpaUrl =>
      iosUrl ?? (throw const FormatException('缺少 iOS 更新包地址'));

  bool get isIos14Compat =>
      iosUrl != null && iosUrl!.path.endsWith('-ios14-unsigned.ipa');

  Uri get trollStoreInstallUrl {
    final target = iosUrl;
    if (target == null || checksum == null || size == null) {
      throw const FormatException('缺少可信的 iOS 更新信息');
    }
    return Uri.parse(
      'apple-magnifier://install?url=${Uri.encodeComponent(target.toString())}',
    );
  }

  /// Pass a file produced by downloadIos, so TrollStore reads the already
  /// verified IPA rather than starting a second internet download.
  static Uri trollStoreFileUrl(File verifiedFile) => Uri(
      scheme: 'apple-magnifier',
      host: 'install',
      queryParameters: {'url': verifiedFile.absolute.uri.toString()});

  static Uri? trustedAsset(dynamic value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 443)) {
      return null;
    }
    if (uri.host == 'github.com' &&
            uri.path
                .startsWith('/Pilipala9919/MarcoMovie/releases/download/') ||
        uri.host == 'marcotv.wlj9919.top' && uri.path.startsWith('/movie/')) {
      return uri;
    }
    return null;
  }

  static AppUpdate parse(
    Map<String, dynamic> json, {
    bool github = false,
    String platform = 'windows',
    bool? preferIos14,
  }) {
    if (!github) {
      final declaredPlatform = json['platform']?.toString().trim();
      if (platform == 'harmonyos' && declaredPlatform != 'harmonyos') {
        throw const FormatException('更新包平台不匹配');
      }
      if (declaredPlatform != null &&
          declaredPlatform.isNotEmpty &&
          declaredPlatform != platform) {
        throw const FormatException('更新包平台不匹配');
      }
    }
    final raw =
        (github ? json['tag_name'] : json['versionName'])?.toString() ?? '';
    if (github && platform == 'harmonyos' && !raw.startsWith('harmonyos-')) {
      throw const FormatException('非鸿蒙正式发布标签');
    }
    final normalized =
        raw.startsWith('$platform-') ? raw.substring(platform.length + 1) : raw;
    final match = RegExp(r'^[vV]?(\d+\.\d+\.\d+)(?:-preview)?$')
        .firstMatch(normalized.trim());
    if (match == null) throw const FormatException('更新版本信息无效');
    final version = match.group(1)!;
    final useIos14 =
        platform == 'ios' && (preferIos14 ?? prefersIos14CompatPackage);
    final iosNames = _iosAssetNames(version, ios14: useIos14);
    final winSetupNames = <String>[
      'MarcoMovie-$version-windows-x64-setup.exe',
      'MarcoMovie-$version-windows-setup.exe',
    ];
    final winPortableNames = <String>[
      'MarcoMovie-$version-windows-x64-portable.zip',
      'MarcoMovie-$version-windows-x64.zip',
    ];
    UpdateAsset? winSetup;
    UpdateAsset? winPortable;
    Map? asset;
    String? matchedFileName;
    if (github) {
      final assets = json['assets'];
      if (assets is List) {
        final byName = <String, Map>{};
        for (final item in assets.whereType<Map>()) {
          final itemName = (item['name'] ?? '').toString().trim();
          if (itemName.isNotEmpty) byName[itemName] = item;
          if (platform == 'ios' && iosNames.contains(itemName)) {
            asset ??= item;
            matchedFileName ??= itemName;
          } else if (platform == 'harmonyos' &&
              isValidHarmonyosAssetName(itemName, version)) {
            if (asset == null ||
                itemName == 'MarcoMovie-$version-harmonyos-universal.hap') {
              asset = item;
              matchedFileName = itemName;
            }
          } else if (platform == 'macos') {
            if (itemName == 'MarcoMovie-$version-macos-desktop.zip') {
              asset = item;
              matchedFileName = itemName;
            } else if (itemName == 'MarcoMovie-$version-macos.zip') {
              asset ??= item;
              matchedFileName ??= itemName;
            }
          }
        }
        if (platform == 'windows') {
          for (final name in winSetupNames) {
            winSetup ??= _parseVerifiedAsset(
              byName[name],
              github: true,
              allowedFileNames: winSetupNames,
            );
          }
          for (final name in winPortableNames) {
            winPortable ??= _parseVerifiedAsset(
              byName[name],
              github: true,
              allowedFileNames: winPortableNames,
            );
          }
        }
      }
    } else if (platform == 'windows') {
      final pkgs = json['packages'] is Map ? json['packages'] as Map : null;
      if (pkgs != null) {
        for (final name in winSetupNames) {
          final cand = pkgs[name];
          if (cand is Map) {
            winSetup ??= _parseVerifiedAsset(
              cand,
              github: false,
              allowedFileNames: winSetupNames,
            );
          }
        }
        for (final name in winPortableNames) {
          final cand = pkgs[name];
          if (cand is Map) {
            winPortable ??= _parseVerifiedAsset(
              cand,
              github: false,
              allowedFileNames: winPortableNames,
            );
          }
        }
      }
      if (winSetup == null && json['windows'] is Map) {
        winSetup = _parseVerifiedAsset(
          json['windows'] as Map,
          github: false,
          allowedFileNames: winSetupNames,
        );
      }
      if (winPortable == null) {
        final rawPortable = json['windowsPortable'] ?? json['portable'];
        if (rawPortable is Map) {
          winPortable = _parseVerifiedAsset(
            rawPortable,
            github: false,
            allowedFileNames: winPortableNames,
          );
        }
      }
    } else if (platform == 'ios') {
      if (useIos14) {
        final ios14Name = 'MarcoMovie-$version-ios14-unsigned.ipa';
        if (json['packages'] is Map) {
          final pkgs = json['packages'] as Map;
          final cand = pkgs[ios14Name];
          if (cand is Map) asset = cand;
        }
        if (asset == null && json['ios14'] is Map) {
          asset = json['ios14'] as Map;
        }
        if (asset == null && json['package'] is Map) {
          final pkg = json['package'] as Map;
          final pkgUrl = pkg['url']?.toString() ?? '';
          if (pkgUrl.endsWith('/$ios14Name')) {
            asset = pkg;
          }
        }
      } else {
        if (json['package'] is Map) {
          final pkg = json['package'] as Map;
          final pkgUrl = pkg['url']?.toString() ?? '';
          if (!pkgUrl.endsWith('-ios14-unsigned.ipa')) {
            asset = pkg;
          }
        }
        if (asset == null && json['packages'] is Map) {
          final pkgs = json['packages'] as Map;
          final cand = pkgs['MarcoMovie-$version-ios-unsigned.ipa'] ??
              pkgs['MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa'];
          if (cand is Map) asset = cand;
        }
        if (asset == null && json['ios'] is Map) {
          asset = json['ios'] as Map;
        }
      }
    } else if (platform == 'harmonyos') {
      if (json['packages'] is Map) {
        final pkgs = json['packages'] as Map;
        for (final candidateName in [
          'MarcoMovie-$version-harmonyos-universal.hap',
          'MarcoMovie-$version-harmonyos-arm64.hap',
          'MarcoMovie-$version-harmonyos.hap',
        ]) {
          final cand = pkgs[candidateName];
          if (cand is Map) {
            asset = cand;
            matchedFileName = candidateName;
            break;
          }
        }
        if (asset == null) {
          for (final entry in pkgs.entries) {
            final keyName = entry.key.toString().trim();
            if (isValidHarmonyosAssetName(keyName, version) &&
                entry.value is Map) {
              asset = entry.value as Map;
              matchedFileName = keyName;
              break;
            }
          }
        }
      } else if (json['package'] is Map) {
        asset = json['package'] as Map;
      } else if (json['harmonyos'] is Map) {
        asset = json['harmonyos'] as Map;
      }
    } else if (platform == 'macos') {
      if (json['packages'] is Map) {
        final pkgs = json['packages'] as Map;
        for (final candidateName in macosAssetNames(version)) {
          final cand = pkgs[candidateName];
          if (cand is Map) {
            asset = cand;
            matchedFileName = candidateName;
            break;
          }
        }
      }
      if (asset == null && json['package'] is Map) {
        asset = json['package'] as Map;
      }
      if (asset == null && json['macos'] is Map) {
        asset = json['macos'] as Map;
      }
    } else if (platform == 'harmonyos') {
      if (json['packages'] is Map) {
        final pkgs = json['packages'] as Map;
        final cand = pkgs['MarcoMovie-$version-harmonyos-universal.hap'] ??
            pkgs['MarcoMovie-$version-harmonyos.hap'];
        if (cand is Map) asset = cand;
      } else if (json['package'] is Map) {
        asset = json['package'] as Map;
      } else if (json['harmonyos'] is Map) {
        asset = json['harmonyos'] as Map;
      }
    }
    final releasePage = trustedReleasePage(
      github ? json['html_url'] : (json['release_url'] ?? json['releaseUrl']),
    );
    if (platform == 'windows') {
      final primary = winSetup ?? winPortable;
      return AppUpdate(
        version,
        (json[github ? 'body' : 'notes'] ?? '').toString(),
        winSetup?.url,
        winSetup?.checksum,
        winSetup?.size,
        null,
        null,
        null,
        releasePage,
        primary?.fileName,
        winSetup,
        winPortable,
      );
    }
    final data = asset ?? const <String, dynamic>{};
    final digest = (github ? data['digest'] : data['sha256'])
        ?.toString()
        .replaceFirst('sha256:', '');
    final size = data['size'];
    final uri =
        trustedAsset(github ? data['browser_download_url'] : data['url']);
    final validDigest = digest != null &&
        RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) &&
        size is int &&
        size > 0;
    final verifiedIos = platform == 'ios' &&
        uri != null &&
        iosNames.any((name) => uri.path.endsWith('/$name')) &&
        validDigest;
    final verifiedMacos = platform == 'macos' &&
        uri != null &&
        _isTrustedMacosAssetPath(uri.path, version) &&
        validDigest;
    final verifiedHarmonyos = platform == 'harmonyos' &&
        uri != null &&
        isValidHarmonyosAssetPath(uri, version) &&
        validDigest;
    final verified = verifiedIos || verifiedMacos || verifiedHarmonyos;
    final resolvedFileName = matchedFileName ??
        (uri != null && uri.pathSegments.isNotEmpty
            ? uri.pathSegments.last
            : null);
    return AppUpdate(
      version,
      (json[github ? 'body' : 'notes'] ?? '').toString(),
      null,
      verified ? digest.toLowerCase() : null,
      verified ? size : null,
      verifiedIos ? uri : null,
      verifiedMacos ? uri : null,
      verifiedHarmonyos ? uri : null,
      releasePage,
      verified ? resolvedFileName : null,
    );
  }

  static String get currentPlatform => OhosRuntime.isOhos
      ? 'harmonyos'
      : Platform.isWindows
          ? 'windows'
          : Platform.isIOS
              ? 'ios'
              : Platform.isMacOS
                  ? 'macos'
                  : 'android';

  static String _suffix(String platform) => switch (platform) {
        'windows' => 'windows-setup.exe',
        'ios' => 'ios-unsigned.ipa',
        'macos' => 'macos.zip',
        'harmonyos' => 'harmonyos-universal.hap',
        'android' => 'mobile.apk',
        _ => throw const FormatException('不支持的更新平台'),
      };

  static AppUpdate _githubRelease(
    dynamic body,
    String platform, {
    bool? preferIos14,
  }) {
    final useIos14 =
        platform == 'ios' && (preferIos14 ?? prefersIos14CompatPackage);
    final candidates = <AppUpdate>[];
    for (final item in (body is List ? body : [body]).whereType<Map>()) {
      if (item['draft'] == true || item['prerelease'] == true) continue;
      final tagName = (item['tag_name'] ?? '').toString().trim();
      if (platform == 'harmonyos' && !tagName.startsWith('harmonyos-')) {
        continue;
      }
      try {
        final release = parse(
          Map<String, dynamic>.from(item),
          github: true,
          platform: platform,
          preferIos14: useIos14,
        );
        final expectedNames = platform == 'ios'
            ? _iosAssetNames(release.version, ios14: useIos14)
            : <String>{'MarcoMovie-${release.version}-${_suffix(platform)}'};
        final altMacosName = 'MarcoMovie-${release.version}-macos-desktop.zip';
        final assets = item['assets'];
        if (assets is! List ||
            !assets.whereType<Map>().any(
                  (asset) {
                    final assetName = (asset['name'] ?? '').toString().trim();
                    final matchesName = expectedNames.contains(assetName) ||
                        (platform == 'windows' &&
                            (isValidWindowsSetupAssetName(
                                  assetName,
                                  release.version,
                                ) ||
                                isValidWindowsPortableAssetName(
                                  assetName,
                                  release.version,
                                ))) ||
                        (platform == 'macos' && assetName == altMacosName) ||
                        (platform == 'harmonyos' &&
                            isValidHarmonyosAssetName(
                              assetName,
                              release.version,
                            ));
                    return matchesName &&
                        trustedAsset(asset['browser_download_url']) != null;
                  },
                )) {
          continue;
        }
        if (platform == 'windows' &&
                release.windowsSetupAsset == null &&
                release.windowsPortableAsset == null &&
                release.windowsUrl == null ||
            platform == 'ios' && release.iosUrl == null ||
            platform == 'macos' && release.macosUrl == null ||
            platform == 'harmonyos' && release.harmonyosUrl == null) {
          continue;
        }
        candidates.add(release);
      } on FormatException {
        /* Another platform's release or malformed entry. */
      }
    }
    if (candidates.isEmpty) throw const FormatException('没有当前平台的正式更新');
    candidates.sort((a, b) {
      final av = a.version.split('.').map(int.parse).toList();
      final bv = b.version.split('.').map(int.parse).toList();
      for (var i = 0; i < av.length; i++) {
        if (av[i] != bv[i]) return bv[i].compareTo(av[i]);
      }
      return 0;
    });
    return candidates.first;
  }

  static Future<AppUpdate> check({
    http.Client? client,
    String? platform,
    bool? preferIos14,
    Duration endpointTimeout = const Duration(seconds: 8),
    UpdateCancellation? cancellation,
    void Function(String)? onStage,
  }) async {
    platform ??= currentPlatform;
    _suffix(platform);
    final useIos14 =
        platform == 'ios' && (preferIos14 ?? prefersIos14CompatPackage);
    final effectiveClient = client ?? debugHttpClientOverride;
    final transport = effectiveClient ?? http.Client();
    try {
      for (final url in [
        'https://marcotv.wlj9919.top/movie/updates/$platform.json',
        'https://api.github.com/repos/Pilipala9919/MarcoMovie/releases?per_page=100',
      ]) {
        final abort = Completer<void>();
        void stop() {
          if (!abort.isCompleted) abort.complete();
        }

        cancellation?.whenCancelled.then((_) => stop());
        try {
          cancellation?.check();
          onStage?.call(url.contains('api.github.com')
              ? '正在连接 GitHub 备用更新源…'
              : '正在连接镜像更新源…');
          final request = http.AbortableRequest('GET', Uri.parse(url),
              abortTrigger: abort.future)
            ..headers.addAll({
              'User-Agent': 'MarcoMovie-Updater',
              'Cache-Control': 'no-cache'
            });
          Future<dynamic> read() async {
            final response = await transport.send(request);
            if (response.statusCode != 200) {
              throw HttpException('HTTP ${response.statusCode}');
            }
            final bytes = <int>[];
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > 4 * 1024 * 1024) {
                throw const FormatException('更新信息过大');
              }
              bytes.addAll(chunk);
            }
            return jsonDecode(utf8.decode(bytes));
          }

          final work = read().timeout(endpointTimeout);
          final body = await (cancellation?.bind(work) ?? work);
          if (url.contains('api.github.com')) {
            return _githubRelease(body, platform, preferIos14: useIos14);
          }
          if (body is! Map<String, dynamic>) {
            continue;
          }
          final pubKeyHex = _effectivePublicKeyHex();
          final Map<String, dynamic> manifest;
          if (!_hasSignatureField(body)) {
            debugPrint('AppUpdate: 更新清单缺少 signature 字段，按旧逻辑继续 ($url)');
            manifest = body;
          } else if (pubKeyHex.isEmpty) {
            debugPrint('AppUpdate: 更新公钥常量为空，跳过签名校验 ($url)');
            final extracted = extractSignedPayload(body);
            if (extracted == null) {
              debugPrint('AppUpdate: 更新清单 payload 结构无效，跳过当前来源 ($url)');
              continue;
            }
            manifest = extracted;
          } else {
            if (!verifyManifestSignature(body, publicKeyHex: pubKeyHex)) {
              debugPrint('AppUpdate: 更新清单签名校验失败，跳过当前来源 ($url)');
              continue;
            }
            final signedPayload = extractSignedPayload(body);
            if (signedPayload == null) {
              debugPrint('AppUpdate: 更新清单签名载荷无效，跳过当前来源 ($url)');
              continue;
            }
            manifest = signedPayload;
          }
          if (manifest['prerelease'] == true) {
            continue;
          }
          final release = parse(
            manifest,
            platform: platform,
            preferIos14: useIos14,
          );
          if (platform == 'windows' &&
                  release.windowsSetupAsset == null &&
                  release.windowsPortableAsset == null &&
                  release.windowsUrl == null ||
              platform == 'ios' && release.iosUrl == null ||
              platform == 'macos' && release.macosUrl == null ||
              platform == 'harmonyos' && release.harmonyosUrl == null) {
            continue;
          }
          return release;
        } on UpdateCancelled {
          rethrow;
        } catch (e) {
          debugPrint('AppUpdate: 更新源检查失败，继续尝试下一来源 ($url): $e');
        } finally {
          stop();
        }
      }
      throw const HttpException('暂时无法检查更新，请稍后重试');
    } finally {
      if (effectiveClient == null) transport.close();
    }
  }

  /// Downloads the published iOS asset to an isolated partial file. Only a
  /// complete, hash-verified package is exposed to Files / signing tools.
  Future<File> downloadIos({
    required Directory directory,
    required UpdateCancellation cancellation,
    http.Client? client,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration stallTimeout = const Duration(seconds: 30),
    Duration totalTimeout = const Duration(minutes: 8),
    void Function(int received, int total)? onProgress,
  }) async {
    final target = iosUrl;
    if (target == null ||
        trustedAsset(target.toString()) == null ||
        size == null ||
        checksum == null) {
      throw const FormatException('缺少可信的 iOS 更新信息');
    }
    final expectedFileName = isIos14Compat
        ? 'MarcoMovie-$version-ios14-unsigned.ipa'
        : 'MarcoMovie-$version-ios-unsigned.ipa';
    final installedFile =
        File('${directory.path}${Platform.pathSeparator}$expectedFileName');
    cancellation.check();
    if (await installedFile.exists()) {
      try {
        await verifyFile(installedFile);
        cancellation.check();
        return installedFile;
      } on FormatException {
        await installedFile.delete();
      }
    }
    final transport = client ?? http.Client();
    final abort = Completer<void>();
    final deadline = Timer(totalTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    cancellation.whenCancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    Directory? staging;
    IOSink? sink;
    try {
      cancellation.check();
      await directory.create(recursive: true);
      staging = await directory.createTemp('.marco-update-');
      final partial = File('${staging.path}/package.part');
      final request =
          http.AbortableRequest('GET', target, abortTrigger: abort.future);
      final response = await cancellation
          .bind(transport.send(request).timeout(connectionTimeout));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (response.contentLength != null && response.contentLength != size) {
        throw const FormatException('更新包大小与发布清单不一致');
      }
      var received = 0;
      sink = partial.openWrite();
      // Both a stalled stream and a stream trickling forever have a deadline.
      Future<void> receive() async {
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          cancellation.check();
          if (abort.isCompleted) throw TimeoutException('更新包下载超时');
          received += chunk.length;
          if (received > size!) throw const FormatException('更新包超过发布大小');
          sink!.add(chunk);
          onProgress?.call(received, size!);
        }
      }

      await cancellation.bind(Future.any([
        receive(),
        abort.future.then<void>((_) => throw TimeoutException('更新包下载超时')),
      ]));
      await sink.flush();
      await sink.close();
      sink = null;
      cancellation.check();
      await verifyFile(partial);
      cancellation.check();
      final savedFile = await partial.rename(installedFile.path);
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File && entity.uri != savedFile.uri) {
            final name = entity.uri.pathSegments.isEmpty
                ? ''
                : entity.uri.pathSegments.last;
            if (name != expectedFileName &&
                RegExp(r'^MarcoMovie-.*-ios(?:14)?-.*unsigned\.ipa$')
                    .hasMatch(name)) {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
      return savedFile;
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
      if (client == null) transport.close();
      await sink?.close();
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  /// Downloads the published macOS ZIP asset to an isolated staging file.
  /// Only a complete, size- and SHA-256-verified archive is exposed to Finder.
  Future<File> downloadMacos({
    required Directory directory,
    required UpdateCancellation cancellation,
    http.Client? client,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration stallTimeout = const Duration(seconds: 30),
    Duration totalTimeout = const Duration(minutes: 10),
    void Function(int received, int total)? onProgress,
  }) async {
    final target = macosUrl;
    if (target == null ||
        trustedAsset(target.toString()) == null ||
        !_isTrustedMacosAssetPath(target.path, version) ||
        size == null ||
        checksum == null) {
      throw const FormatException('缺少可信的 macOS 更新信息');
    }
    final rawName =
        target.pathSegments.isNotEmpty ? target.pathSegments.last : '';
    final expectedFileName =
        RegExp(r'^MarcoMovie-\d+\.\d+\.\d+-macos(?:-desktop)?\.zip$')
                .hasMatch(rawName)
            ? rawName
            : 'MarcoMovie-$version-macos-desktop.zip';
    final installedFile =
        File('${directory.path}${Platform.pathSeparator}$expectedFileName');
    cancellation.check();
    if (await installedFile.exists()) {
      try {
        await verifyFile(installedFile);
        cancellation.check();
        return installedFile;
      } on FormatException {
        // Never delete a pre-existing local file with different content;
        // download and verify in an isolated temporary directory first, then
        // pick a non-colliding filename if the namesake still exists.
      }
    }
    final transport = client ?? http.Client();
    final abort = Completer<void>();
    final deadline = Timer(totalTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    cancellation.whenCancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    Directory? staging;
    IOSink? sink;
    File? publishTemp;
    try {
      cancellation.check();
      staging = await Directory.systemTemp.createTemp('marco-macos-update-');
      final partial =
          File('${staging.path}${Platform.pathSeparator}package.part');
      final request =
          http.AbortableRequest('GET', target, abortTrigger: abort.future);
      final response = await cancellation
          .bind(transport.send(request).timeout(connectionTimeout));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (response.contentLength != null && response.contentLength != size) {
        throw const FormatException('更新包大小与发布清单不一致');
      }
      var received = 0;
      sink = partial.openWrite();
      Future<void> receive() async {
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          cancellation.check();
          if (abort.isCompleted) throw TimeoutException('更新包下载超时');
          received += chunk.length;
          if (received > size!) throw const FormatException('更新包超过发布大小');
          sink!.add(chunk);
          onProgress?.call(received, size!);
        }
      }

      await cancellation.bind(Future.any([
        receive(),
        abort.future.then<void>((_) => throw TimeoutException('更新包下载超时')),
      ]));
      await sink.flush();
      await sink.close();
      sink = null;
      cancellation.check();
      await verifyFile(partial);
      cancellation.check();

      await directory.create(recursive: true);
      final destination = await _resolveUniqueMacosDestination(
        directory,
        expectedFileName,
      );
      if (await destination.exists()) {
        // Exact SHA-256 verified file already present at canonical path.
        return destination;
      }
      publishTemp = File(
        '${directory.path}${Platform.pathSeparator}'
        '.$expectedFileName.tmp.${DateTime.now().microsecondsSinceEpoch}',
      );
      await partial.copy(publishTemp.path);
      await verifyFile(publishTemp);
      cancellation.check();
      final finalDestination = await _resolveUniqueMacosDestination(
        directory,
        expectedFileName,
      );
      if (await finalDestination.exists()) {
        return finalDestination;
      }
      final published = await publishTemp.rename(finalDestination.path);
      publishTemp = null;
      return published;
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
      if (client == null) transport.close();
      await sink?.close();
      if (publishTemp != null && await publishTemp.exists()) {
        try {
          await publishTemp.delete();
        } catch (_) {}
      }
      if (staging != null && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Downloads the published Windows package matching [distribution]
  /// (setup installer `.exe` or portable `.zip`) into an isolated staging
  /// directory. Only a complete, SHA-256 verified file is exposed under its
  /// published versioned filename.
  Future<File> downloadWindows({
    required WindowsDistributionKind distribution,
    required Directory directory,
    required UpdateCancellation cancellation,
    http.Client? client,
    bool cleanupOldPackages = true,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration stallTimeout = const Duration(seconds: 30),
    Duration totalTimeout = const Duration(minutes: 10),
    void Function(int received, int total)? onProgress,
  }) async {
    final asset = windowsAssetFor(distribution);
    if (asset == null || trustedAsset(asset.url.toString()) == null) {
      throw FormatException(
        distribution == WindowsDistributionKind.portable
            ? '缺少可信的 Windows 便携版更新包信息'
            : '缺少可信的 Windows 安装版更新包信息',
      );
    }
    final targetFile =
        File('${directory.path}${Platform.pathSeparator}${asset.fileName}');
    cancellation.check();
    if (await targetFile.exists()) {
      try {
        await verifyAssetFile(targetFile, asset);
        cancellation.check();
        onProgress?.call(asset.size, asset.size);
        return targetFile;
      } on FormatException {
        try {
          await targetFile.delete();
        } catch (_) {}
      }
    }
    final effectiveClient = client ?? debugHttpClientOverride;
    final transport = effectiveClient ?? http.Client();
    final abort = Completer<void>();
    final deadline = Timer(totalTimeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    cancellation.whenCancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    Directory? staging;
    IOSink? sink;
    try {
      cancellation.check();
      await directory.create(recursive: true);
      staging = await directory.createTemp('.marco-win-update-');
      final partial =
          File('${staging.path}${Platform.pathSeparator}package.part');
      final request =
          http.AbortableRequest('GET', asset.url, abortTrigger: abort.future);
      final response = await cancellation
          .bind(transport.send(request).timeout(connectionTimeout));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (response.contentLength != null &&
          response.contentLength != asset.size) {
        throw const FormatException('更新包大小与发布清单不一致');
      }
      var received = 0;
      sink = partial.openWrite();
      Future<void> receive() async {
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          cancellation.check();
          if (abort.isCompleted) throw TimeoutException('更新包下载超时');
          received += chunk.length;
          if (received > asset.size) {
            throw const FormatException('更新包超过发布大小');
          }
          sink!.add(chunk);
          onProgress?.call(received, asset.size);
        }
      }

      await cancellation.bind(Future.any([
        receive(),
        abort.future.then<void>((_) => throw TimeoutException('更新包下载超时')),
      ]));
      await sink.flush();
      await sink.close();
      sink = null;
      cancellation.check();
      await verifyAssetFile(partial, asset);
      cancellation.check();
      if (await targetFile.exists()) {
        try {
          await targetFile.delete();
        } catch (_) {}
      }
      final savedFile = await partial.rename(targetFile.path);
      if (cleanupOldPackages) {
        try {
          await for (final entity in directory.list(followLinks: false)) {
            if (entity is File && entity.uri != savedFile.uri) {
              final name = entity.uri.pathSegments.isEmpty
                  ? ''
                  : entity.uri.pathSegments.last;
              if (name != asset.fileName &&
                  RegExp(
                    r'^MarcoMovie-.*-windows-(?:x64-)?(?:setup\.exe|portable\.zip|x64\.zip)$',
                  ).hasMatch(name)) {
                try {
                  await entity.delete();
                } catch (_) {}
              }
            }
          }
        } catch (_) {}
      }
      return savedFile;
    } finally {
      deadline.cancel();
      if (!abort.isCompleted) abort.complete();
      if (effectiveClient == null) transport.close();
      await sink?.close();
      if (staging != null && await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<File> _resolveUniqueMacosDestination(
    Directory directory,
    String expectedFileName,
  ) async {
    final primary =
        File('${directory.path}${Platform.pathSeparator}$expectedFileName');
    if (!await primary.exists()) return primary;
    try {
      await verifyFile(primary);
      return primary;
    } on FormatException {
      // Preserve pre-existing different file; pick a fresh non-colliding name.
    }
    final dot = expectedFileName.lastIndexOf('.');
    final stem = dot > 0 ? expectedFileName.substring(0, dot) : expectedFileName;
    final ext = dot > 0 ? expectedFileName.substring(dot) : '';
    for (var i = 1; i <= 99; i++) {
      final candidate = File(
        '${directory.path}${Platform.pathSeparator}$stem ($i)$ext',
      );
      if (!await candidate.exists()) return candidate;
      try {
        await verifyFile(candidate);
        return candidate;
      } on FormatException {
        // Occupied by another file; keep trying.
      }
    }
    return File(
      '${directory.path}${Platform.pathSeparator}'
      '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
    );
  }

  static Future<bool> revealMacosPackageInFinder(File file) =>
      const DefaultMacosWindowPlatformAdapter().revealInFinder(file.path);

  static Future<void> verifyAssetFile(File file, UpdateAsset asset) async {
    if (asset.size <= 0 ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(asset.checksum) ||
        await file.length() != asset.size) {
      throw const FormatException('更新包大小不符或缺少校验信息');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString().toLowerCase() != asset.checksum.toLowerCase()) {
      throw const FormatException('更新包校验失败，请重新下载');
    }
  }

  Future<void> verifyFile(File file) async {
    if ((windowsUrl == null &&
            iosUrl == null &&
            macosUrl == null &&
            harmonyosUrl == null) ||
        size == null ||
        checksum == null ||
        await file.length() != size) {
      throw const FormatException('更新包大小不符或缺少校验信息');
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != checksum) {
      throw const FormatException('更新包校验失败，请重新下载');
    }
  }

  ReleaseNotesSummary get notesSummary => ReleaseNotesSummary.parse(notes);
}

class ReleaseNotesSection {
  final String title;
  final List<String> items;
  const ReleaseNotesSection(this.title, this.items);
}

/// Automatically condenses, deduplicates, and categorizes verbose Markdown
/// release notes into concise user-facing sections across desktop and iOS.
class ReleaseNotesSummary {
  final String overview;
  final List<ReleaseNotesSection> sections;
  final int totalItems;

  const ReleaseNotesSummary({
    required this.overview,
    required this.sections,
    required this.totalItems,
  });

  bool get isEmpty => overview.isEmpty && sections.isEmpty;

  static const _catPlayback = '片源与播放';
  static const _catUi = '界面与交互';
  static const _catFeature = '功能与同步';
  static const _catFix = '问题修复与优化';
  static const _catNote = '注意事项';

  static final _headingRe = RegExp(r'^#{1,6}\s+(.+)$');
  static final _numberedBoldRe = RegExp(r'^\d+[.)、]\s*\*\*(.+?)\*\*\s*$');
  static final _bulletRe = RegExp(r'^(?:[-*•]|\d+[.)、])\s+(.+)$');
  static final _mdLinkRe = RegExp(r'\[([^\]\n]+)\]\(([^)\s]+)\)');
  static final _techParenRe = RegExp(
    r'[（(][^）)]*(?:`[^`]+`|[A-Za-z_][A-Za-z0-9_./:-]{3,}|SHA-256|MKCOL)[^）)]*[）)]',
  );
  static final _metaSentenceRe = RegExp(
    r'^(?:发布日期|应用版本|版本代码|构建号|最低系统要求)[：:][^。\n]*[。.]?\s*',
  );

  static ReleaseNotesSummary parse(String rawNotes) {
    final trimmedAll = rawNotes.trim();
    if (trimmedAll.isEmpty) {
      return const ReleaseNotesSummary(
        overview: '',
        sections: [],
        totalItems: 0,
      );
    }
    final lines = rawNotes.split(RegExp(r'\r?\n'));
    var overview = '';
    var skipSection = false;
    var inVerificationSection = false;
    var pendingTopic = '';

    final buckets = <String, List<String>>{
      _catPlayback: <String>[],
      _catUi: <String>[],
      _catFeature: <String>[],
      _catFix: <String>[],
      _catNote: <String>[],
    };
    final seen = <String>{};

    int currentCount() =>
        buckets.values.fold<int>(0, (acc, list) => acc + list.length);

    void addUnique(String category, String item) {
      final norm = item
          .toLowerCase()
          .replaceAll(
            RegExp(r'[\s·•:：,，.。!！?？;；()（）\[\]【】「」]'),
            '',
          );
      if (norm.isEmpty || !seen.add(norm)) return;
      buckets[category]!.add(item);
    }

    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;

      final hm = _headingRe.firstMatch(trimmed);
      if (hm != null) {
        final h = _cleanInline(hm.group(1)!);
        pendingTopic = '';
        if (_isTopVersionHeading(h)) {
          skipSection = false;
          inVerificationSection = false;
          continue;
        }
        if (_isBuildArtifactHeading(h)) {
          skipSection = true;
          inVerificationSection = false;
          continue;
        }
        if (_isVerificationHeading(h)) {
          skipSection = true;
          inVerificationSection = true;
          continue;
        }
        skipSection = false;
        inVerificationSection = false;
        continue;
      }

      final nbm = _numberedBoldRe.firstMatch(trimmed);
      if (nbm != null) {
        if (!skipSection) {
          pendingTopic = _cleanInline(nbm.group(1)!);
        }
        continue;
      }

      final bm = _bulletRe.firstMatch(trimmed);
      final content = bm != null ? bm.group(1)!.trim() : trimmed;

      if (_isKnownLimitationLine(content)) {
        addUnique(_catNote, _condenseItem(_cleanInline(content), 88));
        continue;
      }

      if (skipSection) {
        if (inVerificationSection && content.contains('已知限制')) {
          addUnique(_catNote, _condenseItem(_cleanInline(content), 88));
        }
        continue;
      }

      if (_isNoiseMetadataLine(content)) {
        final extracted = _extractOverviewFromMetaLine(content);
        if (extracted.isNotEmpty && overview.isEmpty) {
          overview = extracted;
        }
        continue;
      }

      if (bm == null &&
          overview.isEmpty &&
          currentCount() == 0 &&
          content.startsWith('本次更新')) {
        overview = _condenseItem(_cleanInline(content), 86);
        continue;
      }

      var cleaned = _cleanInline(content);
      if (cleaned.isEmpty || _isNoiseMetadataLine(cleaned)) continue;

      if (pendingTopic.isNotEmpty && !cleaned.startsWith(pendingTopic)) {
        if (!cleaned.contains('：') && !cleaned.contains(':')) {
          cleaned = '$pendingTopic：$cleaned';
        }
        pendingTopic = '';
      }

      final condensed = _condenseItem(cleaned, 84);
      if (condensed.isEmpty) continue;
      addUnique(_classify(condensed), condensed);
    }

    final sections = <ReleaseNotesSection>[];
    var total = 0;
    for (final entry in buckets.entries) {
      if (entry.value.isNotEmpty) {
        sections.add(
          ReleaseNotesSection(entry.key, List.unmodifiable(entry.value)),
        );
        total += entry.value.length;
      }
    }
    return ReleaseNotesSummary(
      overview: overview,
      sections: List.unmodifiable(sections),
      totalItems: total,
    );
  }

  String toPlainText() {
    if (sections.isEmpty) return overview;
    if (totalItems == 1 && overview.isEmpty) {
      return '• ${sections.first.items.first}';
    }
    final buf = StringBuffer();
    if (overview.isNotEmpty) {
      buf.writeln(overview);
      buf.writeln();
    } else if (totalItems >= 2) {
      buf.writeln('共整理 $totalItems 项重点升级改进：');
      buf.writeln();
    }
    final showHeaders = sections.length > 1 || totalItems >= 3;
    for (var i = 0; i < sections.length; i++) {
      final sec = sections[i];
      if (showHeaders) {
        buf.writeln('【${sec.title}】');
      }
      for (final item in sec.items) {
        buf.writeln('• $item');
      }
      if (i + 1 < sections.length) buf.writeln();
    }
    return buf.toString().trimRight();
  }

  static String formatPlainText(String rawNotes) {
    final parsed = parse(rawNotes);
    if (parsed.isEmpty) return rawNotes.trim();
    return parsed.toPlainText();
  }

  static bool _isTopVersionHeading(String h) {
    final lower = h.toLowerCase();
    return lower.startsWith('marco movie') ||
        RegExp(r'^v?\d+\.\d+\.\d+').hasMatch(lower) ||
        h == '更新内容' ||
        h == '核心修复与优化' ||
        lower == 'changes';
  }

  static bool _isBuildArtifactHeading(String h) {
    final lower = h.toLowerCase();
    return h.contains('包信息') ||
        h.contains('构建记录') ||
        h.contains('文件校验') ||
        h.contains('安装包校验') ||
        lower.contains('checksum') ||
        lower.contains('artifact');
  }

  static bool _isVerificationHeading(String h) =>
      h.contains('验证范围') || h.contains('测试记录') || h.contains('自动化验证');

  static bool _isKnownLimitationLine(String line) =>
      line.startsWith('已知限制：') ||
      line.startsWith('已知限制:') ||
      line.startsWith('注意事项：');

  static bool _isNoiseMetadataLine(String line) {
    final lower = line.toLowerCase();
    if (line.startsWith('发布日期：') || line.startsWith('发布日期:')) return true;
    if (lower.startsWith('platform:') || lower.startsWith('- platform:')) {
      return true;
    }
    if (lower.startsWith('commit:') || lower.startsWith('- commit:')) {
      return true;
    }
    if (lower.contains('sha-256') || lower.contains('sha256:')) return true;
    if (line.contains('构建提交') || line.contains('对应源码包')) return true;
    if (line.startsWith('通过公共内容守卫检查')) return true;
    if (line.startsWith('自动化与') && line.contains('实机验收')) return true;
    if (line.startsWith('未签名 IPA 支持巨魔') && line.contains('长期可用性承诺')) {
      return true;
    }
    return false;
  }

  static String _extractOverviewFromMetaLine(String line) {
    var rest = line;
    while (true) {
      final m = _metaSentenceRe.firstMatch(rest);
      if (m != null) {
        rest = rest.substring(m.end).trim();
      } else {
        break;
      }
    }
    if (rest.isEmpty) return '';
    return _condenseItem(_cleanInline(rest), 86);
  }

  static String _cleanInline(String raw) {
    var s = raw.replaceAll(_techParenRe, '');
    s = s.replaceAllMapped(_mdLinkRe, (m) => m.group(1) ?? '');
    s = s.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static String _condenseItem(String cleaned, int maxLen) {
    var s = cleaned.trim();
    if (s.isEmpty) return '';
    if (s.length <= maxLen) return _stripTrailingPunct(s);
    final semi = s.indexOf('；');
    if (semi >= 14 && semi <= maxLen + 8) {
      s = s.substring(0, semi);
    }
    final period = s.indexOf('。');
    if (period >= 14 && period <= maxLen + 8) {
      s = s.substring(0, period);
    }
    if (s.length > maxLen) {
      final comma = s.lastIndexOf('，', maxLen);
      if (comma >= maxLen ~/ 2) {
        s = s.substring(0, comma);
      } else {
        s = '${s.substring(0, maxLen - 1)}…';
      }
    }
    return _stripTrailingPunct(s);
  }

  static String _stripTrailingPunct(String s) {
    var end = s.length;
    while (end > 0) {
      final ch = s[end - 1];
      if (ch == '。' || ch == '；' || ch == ';' || ch == '，' || ch == ',') {
        end--;
      } else {
        break;
      }
    }
    return s.substring(0, end).trim();
  }

  static String _classify(String item) {
    if (_isKnownLimitationLine(item)) return _catNote;
    if (item.startsWith('修复') ||
        _containsAny(item, const [
          '报错',
          '异常',
          '崩溃',
          '闪退',
          '观看历史',
          '观影记录',
          '桌面快捷方式',
          '桌面图标',
        ])) {
      return _catFix;
    }
    if (_containsAny(item, const [
      '片源',
      '线路',
      '网盘',
      '玩偶',
      '夸克',
      '百度',
      '阿里',
      'UC',
      '播放',
      '片头',
      '片尾',
      '常显时间',
      '解码',
      '直播',
      '弹幕',
      '字幕',
      '插件',
      '嗅探',
    ])) {
      return _catPlayback;
    }
    if (_containsAny(item, const [
      '界面',
      '海报',
      '首页',
      '筛选',
      '分类',
      '窗口',
      '标题栏',
      '沉浸式',
      '中文',
      '安装程序',
      '安装向导',
      '闪烁',
      '加载更多',
      '导航',
      '遥控',
      '设置页',
    ])) {
      return _catUi;
    }
    if (_containsAny(item, const [
      '同步',
      'WebDAV',
      '局域网',
      '收藏',
      '新增',
      '支持',
      '引入',
      '升级',
    ])) {
      return _catFeature;
    }
    return _catFix;
  }

  static bool _containsAny(String text, List<String> keywords) {
    for (final kw in keywords) {
      if (text.contains(kw)) return true;
    }
    return false;
  }
}
