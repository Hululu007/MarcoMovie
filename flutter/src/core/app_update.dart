import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'ed25519.dart';

class UpdateCancelled implements Exception {
  const UpdateCancelled();
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
  /// Production Ed25519 public key (hex) for verifying update manifests.
  static const String defaultUpdatePublicKeyHex =
      'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';

  /// Optional testing override for unit tests.
  @visibleForTesting
  static String? debugPublicKeyHexOverride;

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
    final sigB64 = body['signature'] as String? ?? body['sig'] as String?;
    if (sigB64 == null || sigB64.isEmpty) {
      return false;
    }
    final payload = body.containsKey('payload') && body['payload'] is Map
        ? body['payload']
        : (Map<String, dynamic>.from(body)
          ..remove('signature')
          ..remove('sig'));
    final canonical = canonicalizeJson(payload);
    final messageBytes = Uint8List.fromList(utf8.encode(canonical));
    try {
      final sigBytes = base64Decode(sigB64);
      final pubHex =
          publicKeyHex ?? debugPublicKeyHexOverride ?? defaultUpdatePublicKeyHex;
      final pubBytes = Uint8List(pubHex.length ~/ 2);
      for (var i = 0; i < pubBytes.length; i++) {
        pubBytes[i] = int.parse(pubHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return Ed25519.verify(
        publicKey: pubBytes,
        message: messageBytes,
        signature: sigBytes,
      );
    } catch (_) {
      return false;
    }
  }

  final String version;
  final String notes;
  final Uri? windowsUrl;
  final String? checksum;
  final int? size;
  final Uri? iosUrl;
  const AppUpdate(
    this.version,
    this.notes,
    this.windowsUrl,
    this.checksum,
    this.size, [
    this.iosUrl,
  ]);

  // Only use the advertised asset. The download site does not host large IPAs.
  Uri get iosMirrorIpaUrl =>
      iosUrl ?? (throw const FormatException('缺少 iOS 更新包地址'));

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

  static AppUpdate parse(Map<String, dynamic> json,
      {bool github = false, String platform = 'windows'}) {
    if (!github && json['platform'] != null && json['platform'] != platform) {
      throw const FormatException('更新包平台不匹配');
    }
    final raw =
        (github ? json['tag_name'] : json['versionName'])?.toString() ?? '';
    final normalized =
        raw.startsWith('$platform-') ? raw.substring(platform.length + 1) : raw;
    final match = RegExp(r'^[vV]?(\d+\.\d+\.\d+)(?:-preview)?$')
        .firstMatch(normalized.trim());
    if (match == null) throw const FormatException('更新版本信息无效');
    final version = match.group(1)!;
    Map? asset;
    if (github) {
      final assets = json['assets'];
      if (assets is List) {
        for (final item in assets.whereType<Map>()) {
          if (platform == 'windows' &&
              item['name'] == 'MarcoMovie-$version-windows-setup.exe') {
            asset = item;
          } else if (platform == 'ios' &&
              (item['name'] == 'MarcoMovie-$version-ios-unsigned.ipa' ||
                  item['name'] ==
                      'MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa')) {
            asset ??= item;
          }
        }
      }
    } else if (platform == 'windows' && json['windows'] is Map) {
      asset = json['windows'] as Map;
    } else if (platform == 'ios') {
      if (json['package'] is Map) {
        asset = json['package'] as Map;
      } else if (json['packages'] is Map) {
        final pkgs = json['packages'] as Map;
        final cand = pkgs['MarcoMovie-$version-ios-unsigned.ipa'] ??
            pkgs['MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa'];
        if (cand is Map) asset = cand;
      } else if (json['ios'] is Map) {
        asset = json['ios'] as Map;
      }
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
    final verifiedWin = platform == 'windows' &&
        uri != null &&
        uri.path.endsWith('/MarcoMovie-$version-windows-setup.exe') &&
        validDigest;
    final verifiedIos = platform == 'ios' &&
        uri != null &&
        (uri.path.endsWith('/MarcoMovie-$version-ios-unsigned.ipa') ||
            uri.path.endsWith(
              '/MarcoMovie-$version-ios-iphone-ipad-unsigned.ipa',
            )) &&
        validDigest;
    final verified = verifiedWin || verifiedIos;
    return AppUpdate(
      version,
      (json[github ? 'body' : 'notes'] ?? '').toString(),
      verifiedWin ? uri : null,
      verified ? digest.toLowerCase() : null,
      verified ? size : null,
      verifiedIos ? uri : null,
    );
  }

  static String get currentPlatform => Platform.isWindows
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
        'android' => 'mobile.apk',
        _ => throw const FormatException('不支持的更新平台'),
      };

  static AppUpdate _githubRelease(dynamic body, String platform) {
    final candidates = <AppUpdate>[];
    for (final item in (body is List ? body : [body]).whereType<Map>()) {
      if (item['draft'] == true || item['prerelease'] == true) continue;
      try {
        final release = parse(Map<String, dynamic>.from(item),
            github: true, platform: platform);
        final name = 'MarcoMovie-${release.version}-${_suffix(platform)}';
        final altIosName =
            'MarcoMovie-${release.version}-ios-iphone-ipad-unsigned.ipa';
        final assets = item['assets'];
        if (assets is! List ||
            !assets.whereType<Map>().any(
                  (asset) =>
                      (asset['name'] == name ||
                          (platform == 'ios' && asset['name'] == altIosName)) &&
                      trustedAsset(asset['browser_download_url']) != null,
                )) {
          continue;
        }
        if (platform == 'windows' && release.windowsUrl == null ||
            platform == 'ios' && release.iosUrl == null) {
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
    Duration endpointTimeout = const Duration(seconds: 8),
    UpdateCancellation? cancellation,
    void Function(String)? onStage,
  }) async {
    platform ??= currentPlatform;
    _suffix(platform);
    final transport = client ?? http.Client();
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
            return _githubRelease(body, platform);
          }
          if (body is! Map<String, dynamic> || body['prerelease'] == true) {
            continue;
          }
          if (!verifyManifestSignature(body)) {
            throw const FormatException(
                '更新清单数字签名无效或缺失 (Ed25519 signature missing or invalid)');
          }
          final release = parse(body, platform: platform);
          if (platform == 'windows' && release.windowsUrl == null ||
              platform == 'ios' && release.iosUrl == null) {
            continue;
          }
          return release;
        } on UpdateCancelled {
          rethrow;
        } on FormatException {
          rethrow;
        } catch (_) {/* Try the second release endpoint. */} finally {
          stop();
        }
      }
      throw const HttpException('暂时无法检查更新，请稍后重试');
    } finally {
      if (client == null) transport.close();
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
    final expectedFileName = 'MarcoMovie-$version-ios-unsigned.ipa';
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
                RegExp(r'^MarcoMovie-.*-ios-.*unsigned\.ipa$').hasMatch(name)) {
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

  Future<void> verifyFile(File file) async {
    if ((windowsUrl == null && iosUrl == null) ||
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
