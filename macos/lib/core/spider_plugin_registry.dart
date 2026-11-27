import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'models.dart';

/// Execution kind for a user-installed hot-pluggable cross-platform spider
/// adapter rule (`marco-adapter-pack-v1`).
enum SpiderAdapterKind {
  js,
  drpy,
  python,
  t4;

  static SpiderAdapterKind? tryParse(String raw) => switch (raw.trim().toLowerCase()) {
    'js' || 'javascript' || 'catvod' => SpiderAdapterKind.js,
    'drpy' || 'drpy2' => SpiderAdapterKind.drpy,
    'py' || 'python' => SpiderAdapterKind.python,
    't4' || 'http_t4' || 'http' => SpiderAdapterKind.t4,
    _ => null,
  };

  String get displayName => switch (this) {
    SpiderAdapterKind.js => 'JS 脚本',
    SpiderAdapterKind.drpy => 'DRPY2 规则',
    SpiderAdapterKind.python => 'Python 蜘蛛',
    SpiderAdapterKind.t4 => 'T4 接口',
  };
}

/// Resolution tier used for a TVBox / CatVod spider site under Marco Movie's
/// strict **Local-First** priority order:
/// 1. [nativeLocal] — built-in cross-platform Dart/JS/DRPY/Python/T4 adapter.
/// 2. [adapterPack] — user-installed pure-script adapter pack running locally.
/// 3. [gateway] — optional user-owned BYO Spider Gateway (LAN Android / self-hosted Docker).
/// 4. [unsupported] — requires Android native `.so` with no adapter or gateway configured.
enum SpiderResolutionMode {
  nativeLocal,
  adapterPack,
  gateway,
  unsupported,
}

/// One mapping rule inside a [SpiderAdapterPack] that maps one or more
/// `csp_*` API identifiers (or site name patterns) to a cross-platform script
/// or T4 endpoint.
class SpiderAdapterRule {
  final String id;
  final List<String> matchApis;
  final String matchNamePattern;
  final SpiderAdapterKind kind;
  final String scriptUrl;
  final String inlineScript;
  final String? extOverride;
  final Map<String, String> headers;
  final String sha256;
  final String description;

  const SpiderAdapterRule({
    required this.id,
    required this.matchApis,
    this.matchNamePattern = '',
    required this.kind,
    this.scriptUrl = '',
    this.inlineScript = '',
    this.extOverride,
    this.headers = const {},
    this.sha256 = '',
    this.description = '',
  });

  bool get hasTarget =>
      scriptUrl.trim().isNotEmpty || inlineScript.trim().isNotEmpty;

  static String? validateHttpUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.toString();
  }

  /// Whether this rule matches [site] by `api` / `sourceApi` (exact or
  /// trailing-wildcard prefix like `csp_manjuai*`) or optional name pattern.
  bool matchesSite(CmsSite site) {
    if (!hasTarget) return false;
    final candidates = <String>{
      site.api.trim().toLowerCase(),
      site.sourceApi.trim().toLowerCase(),
    }..removeWhere((s) => s.isEmpty);

    if (matchApis.isNotEmpty) {
      for (final rawPattern in matchApis) {
        final pat = rawPattern.trim().toLowerCase();
        if (pat.isEmpty) continue;
        if (pat == '*') return true;
        if (pat.endsWith('*')) {
          final prefix = pat.substring(0, pat.length - 1);
          if (prefix.isNotEmpty &&
              candidates.any((c) => c.startsWith(prefix))) {
            return true;
          }
        } else if (candidates.contains(pat)) {
          return true;
        }
      }
    }

    final namePat = matchNamePattern.trim();
    if (namePat.isNotEmpty) {
      try {
        if (RegExp(namePat, caseSensitive: false).hasMatch(site.name)) {
          return true;
        }
      } catch (_) {
        if (site.name.toLowerCase().contains(namePat.toLowerCase())) {
          return true;
        }
      }
    }
    return false;
  }

  /// Converts an unadapted [original] `csp_*` site into an executable
  /// cross-platform [CmsSite] targeting Marco Movie's existing local QuickJS,
  /// DRPY2, Python, or HTTP T4 runtimes.
  CmsSite materializeSite(CmsSite original) {
    final effectiveExt = (extOverride != null && extOverride!.trim().isNotEmpty)
        ? extOverride!.trim()
        : original.ext;
    final mergedHeaders = <String, String>{
      ...original.headers,
      ...headers,
    };
    final safeId = id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

    switch (kind) {
      case SpiderAdapterKind.t4:
        return original.copyWith(
          type: 4,
          api: scriptUrl.trim(),
          ext: effectiveExt,
          headers: mergedHeaders,
        );
      case SpiderAdapterKind.js:
        if (inlineScript.trim().isNotEmpty) {
          return original.copyWith(
            type: 3,
            api: 'csp_LocalScript.js',
            ext: jsonEncode(<String, dynamic>{
              'script': inlineScript,
              'origin': 'pkg://adapter/$safeId/index.js',
              'ext': effectiveExt,
            }),
            headers: mergedHeaders,
          );
        }
        return original.copyWith(
          type: 3,
          api: scriptUrl.trim(),
          ext: effectiveExt,
          headers: mergedHeaders,
        );
      case SpiderAdapterKind.drpy:
        if (inlineScript.trim().isNotEmpty) {
          return original.copyWith(
            type: 3,
            api: 'csp_LocalRule.js',
            ext: jsonEncode(<String, dynamic>{
              'script': inlineScript,
              'origin': 'pkg://adapter/$safeId/rule.js',
              'ext': effectiveExt,
            }),
            headers: mergedHeaders,
          );
        }
        return original.copyWith(
          type: 3,
          api: 'csp_drpy',
          ext: scriptUrl.trim(),
          headers: mergedHeaders,
        );
      case SpiderAdapterKind.python:
        if (inlineScript.trim().isNotEmpty) {
          return original.copyWith(
            type: 3,
            api: 'csp_LocalScript.py',
            ext: jsonEncode(<String, dynamic>{
              'script': inlineScript,
              'origin': 'pkg://adapter/$safeId/spider.py',
              'ext': effectiveExt,
            }),
            headers: mergedHeaders,
          );
        }
        return original.copyWith(
          type: 3,
          api: scriptUrl.trim(),
          ext: effectiveExt,
          headers: mergedHeaders,
        );
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'matchApis': matchApis,
    if (matchNamePattern.isNotEmpty) 'matchNamePattern': matchNamePattern,
    'kind': kind.name,
    if (scriptUrl.isNotEmpty) 'scriptUrl': scriptUrl,
    if (inlineScript.isNotEmpty) 'inlineScript': inlineScript,
    if (extOverride != null && extOverride!.isNotEmpty)
      'extOverride': extOverride,
    if (headers.isNotEmpty) 'headers': headers,
    if (sha256.isNotEmpty) 'sha256': sha256,
    if (description.isNotEmpty) 'description': description,
  };

  factory SpiderAdapterRule.fromJson(Map<String, dynamic> json, {int index = 0}) {
    final kindRaw = (json['kind'] ?? json['engine'] ?? 'js').toString();
    final kind = SpiderAdapterKind.tryParse(kindRaw);
    if (kind == null) {
      throw FormatException('插件规则 #${index + 1} 使用了不支持的引擎类型：$kindRaw');
    }
    final apis = <String>[];
    final rawApis = json['matchApis'] ?? json['apis'] ?? json['matchApi'];
    if (rawApis is String && rawApis.trim().isNotEmpty) {
      apis.add(rawApis.trim());
    } else if (rawApis is List) {
      for (final item in rawApis) {
        final s = item.toString().trim();
        if (s.isNotEmpty) apis.add(s);
      }
    }
    final namePattern =
        (json['matchNamePattern'] ?? json['namePattern'] ?? '').toString().trim();
    if (apis.isEmpty && namePattern.isEmpty) {
      throw FormatException('插件规则 #${index + 1} 缺少 matchApis 或 matchNamePattern');
    }
    final rawUrl = (json['scriptUrl'] ?? json['url'] ?? json['t4Url'] ?? '')
        .toString()
        .trim();
    final validatedUrl = validateHttpUrl(rawUrl);
    if (validatedUrl == null) {
      throw FormatException('插件规则 #${index + 1} 的脚本地址无效（仅允许 HTTP/HTTPS）');
    }
    final inline = (json['inlineScript'] ?? json['script'] ?? '').toString();
    if (validatedUrl.isEmpty && inline.trim().isEmpty) {
      throw FormatException('插件规则 #${index + 1} 缺少 scriptUrl 或 inlineScript');
    }
    if (kind == SpiderAdapterKind.t4 && validatedUrl.isEmpty) {
      throw FormatException('T4 规则 #${index + 1} 必须提供有效的 HTTP(S) scriptUrl');
    }
    final headersMap = <String, String>{};
    if (json['headers'] is Map) {
      for (final e in (json['headers'] as Map).entries) {
        final k = e.key.toString().trim();
        if (k.isNotEmpty) headersMap[k] = e.value.toString();
      }
    }
    final rawId = (json['id'] ?? '').toString().trim();
    return SpiderAdapterRule(
      id: rawId.isNotEmpty ? rawId : 'rule_${index + 1}',
      matchApis: List<String>.unmodifiable(apis),
      matchNamePattern: namePattern,
      kind: kind,
      scriptUrl: validatedUrl,
      inlineScript: inline,
      extOverride: json['extOverride']?.toString(),
      headers: Map<String, String>.unmodifiable(headersMap),
      sha256: (json['sha256'] ?? '').toString().trim().toLowerCase(),
      description: (json['description'] ?? '').toString().trim(),
    );
  }
}

/// User-installed hot-pluggable adapter pack (`marco-adapter-pack-v1`) that maps
/// unadapted `csp_*` routes onto local cross-platform JS/DRPY/Python/T4 scripts
/// without requiring an app rebuild or any central server.
class SpiderAdapterPack {
  static const String schemaId = 'marco-adapter-pack-v1';
  static const int maxPackBytes = 2 * 1024 * 1024;
  static const int maxRulesPerPack = 256;

  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String sourceUrl;
  final bool enabled;
  final int updatedAt;
  final List<SpiderAdapterRule> rules;

  const SpiderAdapterPack({
    required this.id,
    required this.name,
    this.version = '1.0.0',
    this.author = '',
    this.description = '',
    this.sourceUrl = '',
    this.enabled = true,
    this.updatedAt = 0,
    required this.rules,
  });

  SpiderAdapterPack copyWith({
    String? id,
    String? name,
    String? version,
    String? author,
    String? description,
    String? sourceUrl,
    bool? enabled,
    int? updatedAt,
    List<SpiderAdapterRule>? rules,
  }) {
    return SpiderAdapterPack(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      author: author ?? this.author,
      description: description ?? this.description,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      enabled: enabled ?? this.enabled,
      updatedAt: updatedAt ?? this.updatedAt,
      rules: rules ?? this.rules,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': schemaId,
    'id': id,
    'name': name,
    'version': version,
    if (author.isNotEmpty) 'author': author,
    if (description.isNotEmpty) 'description': description,
    if (sourceUrl.isNotEmpty) 'sourceUrl': sourceUrl,
    'enabled': enabled,
    'updatedAt': updatedAt,
    'rules': [for (final r in rules) r.toJson()],
  };

  factory SpiderAdapterPack.fromJson(
    Map<String, dynamic> json, {
    String fallbackSourceUrl = '',
  }) {
    final schema = (json['schema'] ?? '').toString().trim();
    if (schema.isNotEmpty && schema != schemaId) {
      throw FormatException('不支持的插件包协议版本：$schema（需要 $schemaId）');
    }
    final rawRules = json['rules'] ?? json['adapters'];
    if (rawRules is! List || rawRules.isEmpty) {
      throw const FormatException('插件包中未包含任何有效的 rules 规则');
    }
    if (rawRules.length > maxRulesPerPack) {
      throw const FormatException('单个插件包规则数不能超过 256 条');
    }
    final parsedRules = <SpiderAdapterRule>[];
    for (var i = 0; i < rawRules.length; i++) {
      final entry = rawRules[i];
      if (entry is! Map) {
        throw FormatException('插件规则 #${i + 1} 格式无效');
      }
      parsedRules.add(
        SpiderAdapterRule.fromJson(
          Map<String, dynamic>.from(entry),
          index: i,
        ),
      );
    }
    final name = (json['name'] ?? '').toString().trim();
    final effectiveName = name.isNotEmpty ? name : '自定义扩展插件包';
    final rawId = (json['id'] ?? '').toString().trim();
    final effectiveId = rawId.isNotEmpty
        ? rawId
        : 'pack_${DateTime.now().millisecondsSinceEpoch}';
    final rawSource =
        (json['sourceUrl'] ?? fallbackSourceUrl).toString().trim();
    final validSource = SpiderAdapterRule.validateHttpUrl(rawSource) ?? '';
    return SpiderAdapterPack(
      id: effectiveId,
      name: effectiveName,
      version: (json['version'] ?? '1.0.0').toString().trim(),
      author: (json['author'] ?? '').toString().trim(),
      description: (json['description'] ?? '').toString().trim(),
      sourceUrl: validSource,
      enabled: json['enabled'] != false,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      rules: List<SpiderAdapterRule>.unmodifiable(parsedRules),
    );
  }

  static SpiderAdapterPack parseJsonString(
    String rawJson, {
    String fallbackSourceUrl = '',
  }) {
    if (utf8.encode(rawJson).length > maxPackBytes) {
      throw const FormatException('插件包体积超过 2 MB 上限');
    }
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('插件包 JSON 根节点必须为对象');
    }
    return SpiderAdapterPack.fromJson(
      Map<String, dynamic>.from(decoded),
      fallbackSourceUrl: fallbackSourceUrl,
    );
  }
}

/// Optional user-owned BYO Spider Gateway configuration (strictly opt-in,
/// default OFF, zero author-hosted servers). Connects ONLY to a user's own
/// LAN Android device or self-hosted Docker / NAS T4 gateway.
class SpiderGatewayConfig {
  final bool enabled;
  final String baseUrl;
  final String token;
  final String deviceName;

  const SpiderGatewayConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.token = '',
    this.deviceName = '',
  });

  static String normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final candidate = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return '';
    }
    var out = uri.replace(query: null, fragment: null).toString();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  String get normalizedBaseUrl => normalizeBaseUrl(baseUrl);

  bool get isActive => enabled && normalizedBaseUrl.isNotEmpty;

  SpiderGatewayConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? token,
    String? deviceName,
  }) {
    return SpiderGatewayConfig(
      enabled: enabled ?? this.enabled,
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      deviceName: deviceName ?? this.deviceName,
    );
  }
}

/// Global runtime registry for user-installed cross-platform Spider Adapter
/// Packs and optional BYO Spider Gateway fallback, hydrated by `StorageService`.
class SpiderPluginRegistry extends ChangeNotifier {
  SpiderPluginRegistry._();
  static final SpiderPluginRegistry instance = SpiderPluginRegistry._();

  List<SpiderAdapterPack> _packs = const <SpiderAdapterPack>[];
  SpiderGatewayConfig _gatewayConfig = const SpiderGatewayConfig();

  List<SpiderAdapterPack> get packs => _packs;
  SpiderGatewayConfig get gatewayConfig => _gatewayConfig;

  int get enabledPackCount => _packs.where((p) => p.enabled).length;
  int get enabledRuleCount => _packs
      .where((p) => p.enabled)
      .fold<int>(0, (sum, p) => sum + p.rules.length);

  void hydrate({
    required List<SpiderAdapterPack> packs,
    required SpiderGatewayConfig gateway,
  }) {
    _packs = List<SpiderAdapterPack>.unmodifiable(packs);
    _gatewayConfig = gateway;
    notifyListeners();
  }

  void setPacks(List<SpiderAdapterPack> packs) {
    _packs = List<SpiderAdapterPack>.unmodifiable(packs);
    notifyListeners();
  }

  void setGatewayConfig(SpiderGatewayConfig config) {
    _gatewayConfig = config;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTesting() {
    _packs = const <SpiderAdapterPack>[];
    _gatewayConfig = const SpiderGatewayConfig();
    notifyListeners();
  }

  /// Finds the first matching rule across enabled user-installed adapter packs.
  SpiderAdapterRule? matchAdapterRule(CmsSite site) {
    if (_packs.isEmpty) return null;
    for (final pack in _packs) {
      if (!pack.enabled) continue;
      for (final rule in pack.rules) {
        if (rule.matchesSite(site)) {
          return rule;
        }
      }
    }
    return null;
  }

  static bool _isGatewayExcludedApi(String lowerApi) {
    return lowerApi.startsWith('csp_sixv') ||
        lowerApi.startsWith('csp_emby') ||
        lowerApi.startsWith('csp_alist') ||
        lowerApi.startsWith('csp_webdav') ||
        lowerApi.startsWith('csp_diyvod') ||
        lowerApi.startsWith('csp_fakeai115') ||
        lowerApi.startsWith('csp_push') ||
        lowerApi == 'csp_config' ||
        lowerApi == 'csp_configcenter';
  }

  /// Whether the user's optional BYO Spider Gateway can execute [site]
  /// (typically Android `.jar` + `.so` `csp_*` spiders that cannot run natively
  /// on iOS / macOS / Windows / HarmonyOS).
  bool canGatewayHandle(CmsSite site) {
    if (!_gatewayConfig.isActive) return false;
    if (site.key == 'mydrive' || site.isExtTooLarge) return false;
    final lowerApi = site.api.trim().toLowerCase();
    if (!lowerApi.startsWith('csp_')) return false;
    if (lowerApi.startsWith('csp_local')) return false;
    if (_isGatewayExcludedApi(lowerApi)) return false;
    return true;
  }

  /// Whether either an installed script adapter pack OR the user's opt-in BYO
  /// gateway can handle [site].
  bool hasPluginOrGatewaySupport(CmsSite site) {
    if (site.key == 'mydrive' || site.isExtTooLarge) return false;
    return matchAdapterRule(site) != null || canGatewayHandle(site);
  }

  /// Resolves the strict Local-First execution tier for [site].
  SpiderResolutionMode resolveModeFor(
    CmsSite site, {
    required bool hasNativeLocalAdapter,
  }) {
    if (hasNativeLocalAdapter) return SpiderResolutionMode.nativeLocal;
    if (matchAdapterRule(site) != null) return SpiderResolutionMode.adapterPack;
    if (canGatewayHandle(site)) return SpiderResolutionMode.gateway;
    return SpiderResolutionMode.unsupported;
  }

  /// Copyable JSON starter template for community / personal pure-script
  /// adapter packs (`marco-adapter-pack-v1`).
  static String samplePackTemplateJson() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(<String, dynamic>{
      'schema': SpiderAdapterPack.schemaId,
      'id': 'community-sample-pack',
      'name': '跨平台脚本扩展包示例',
      'version': '1.0.0',
      'author': 'YourName',
      'description': '将依赖 Android .so 的 csp_* 线路映射为纯本地 JS / DRPY2 / Python / T4 脚本，全平台通用。',
      'rules': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'example-js-adapter',
          'matchApis': <String>['csp_ExampleSpider', 'csp_ExampleSpiderGuard'],
          'kind': 'js',
          'scriptUrl': 'https://plugins.example/adapters/example_spider.js',
          'description': '使用纯 JavaScript 替代原 Android .so 蜘蛛',
        },
        <String, dynamic>{
          'id': 'example-t4-adapter',
          'matchApis': <String>['csp_ExampleT4*'],
          'kind': 't4',
          'scriptUrl': 'https://plugins.example/t4/example',
          'description': '映射为标准 HTTP T4 元数据接口',
        },
      ],
    });
  }
}
