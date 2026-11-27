import 'dart:convert';

import 'catpaw_host.dart';
import 'csp_bridge.dart';
import 'models.dart';
import 'netdisk_session.dart';
import 'quark_account.dart';
import 'storage_service.dart';

enum ConfigCenterKind {
  wexOk,
  ftyMyDrive,
  catPaw,
  panConfig,
  generic,
}

extension ConfigCenterKindLabel on ConfigCenterKind {
  String get labelZh => switch (this) {
        ConfigCenterKind.wexOk => 'WEX / OK 配置中心',
        ConfigCenterKind.ftyMyDrive => 'FTY / 云盘配置中心',
        ConfigCenterKind.catPaw => 'CatPaw 本地配置中心',
        ConfigCenterKind.panConfig => '网盘线路配置中心',
        ConfigCenterKind.generic => '多源通用配置中心',
      };
}

class DetectedConfigCenter {
  final CmsSite site;
  final ConfigCenterKind kind;
  final String displayName;
  final String group;

  const DetectedConfigCenter({
    required this.site,
    required this.kind,
    required this.displayName,
    required this.group,
  });

  bool get isCatPawBaseset =>
      site.isCatPaw && Uri.tryParse(site.api)?.path == '/api/baseset';
}

class ExtractedConfigCenterData {
  final Map<String, String> credentials;
  final List<String>? driveOrder;

  const ExtractedConfigCenterData({
    this.credentials = const <String, String>{},
    this.driveOrder,
  });

  bool get isEmpty => credentials.isEmpty && (driveOrder == null || driveOrder!.isEmpty);
}

class ConfigCenterSyncReport {
  final List<DetectedConfigCenter> detectedCenters;
  final List<String> importedDrives;
  final List<String> exportedDrives;
  final int syncedTargetCount;
  final bool updatedDriveOrder;

  const ConfigCenterSyncReport({
    this.detectedCenters = const <DetectedConfigCenter>[],
    this.importedDrives = const <String>[],
    this.exportedDrives = const <String>[],
    this.syncedTargetCount = 0,
    this.updatedDriveOrder = false,
  });

  String get summaryZh {
    final parts = <String>[];
    if (importedDrives.isNotEmpty) {
      parts.add('已自动读取 ${importedDrives.length} 个网盘凭据');
    }
    if (updatedDriveOrder) {
      parts.add('已同步盘序');
    }
    if (exportedDrives.isNotEmpty) {
      final centerHint = detectedCenters.isNotEmpty
          ? '${detectedCenters.length} 个配置中心'
          : '全源共享存储';
      parts.add('${exportedDrives.length} 个已登录网盘已互通至$centerHint');
    }
    if (parts.isEmpty) {
      return detectedCenters.isNotEmpty
          ? '已兼容识别 ${detectedCenters.length} 个源配置中心，一次扫码全源通用'
          : '统一配置中心已就绪，扫码一次即可在所有兼容片源中通用';
    }
    return parts.join(' · ');
  }
}

/// Unified multi-source Config Center compatibility bridge.
///
/// Discovers WEX / OK / FTY / MyDrive / CatPaw / PanConfig centers across all
/// loaded subscriptions, directly reads compatible credentials & drive order
/// from subscription `ext` blocks and local runtime stores, and broadcasts a
/// single QR / Token login back out so one scan works across every source.
class ConfigCenterBridge {
  static const List<String> supportedDriveKeys = <String>[
    'quark',
    'uc',
    'baidu',
    'ali',
  ];

  static bool isConfigCenterSite(CmsSite site) {
    if (CspBridge.isMyDriveSite(site)) return true;
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final lowerName = site.name.toLowerCase();
    if (site.isCatPaw && Uri.tryParse(site.api)?.path == '/api/baseset') {
      return true;
    }
    return lowerApi.contains('configcenter') ||
        lowerApi.contains('localconfig') ||
        lowerApi.contains('wexconfig') ||
        lowerApi.contains('wexokconfig') ||
        lowerApi.contains('panconfig') ||
        lowerApi.contains('mydrive') ||
        lowerApi.contains('csp_config') ||
        lowerKey.contains('configcenter') ||
        lowerKey.contains('wexconfig') ||
        lowerKey.contains('panconfig') ||
        lowerKey.contains('mydrive') ||
        lowerName.contains('配置中心') ||
        lowerName.contains('我的云盘') ||
        lowerName.contains('我的网盘') ||
        lowerName.contains('网盘配置') ||
        lowerName.contains('云盘配置') ||
        lowerName.contains('配置┃中心') ||
        lowerName.contains('网盘┃配置');
  }

  static ConfigCenterKind classifySite(CmsSite site) {
    final lowerApi = site.api.toLowerCase();
    final lowerKey = site.key.toLowerCase();
    final lowerName = site.name.toLowerCase();
    if (site.isCatPaw) return ConfigCenterKind.catPaw;
    if (lowerApi.contains('wex') ||
        lowerKey.contains('wex') ||
        lowerApi.contains('okconfig') ||
        lowerName.contains('wex') ||
        lowerName.contains('ok')) {
      return ConfigCenterKind.wexOk;
    }
    if (lowerApi.contains('mydrive') ||
        lowerKey.contains('mydrive') ||
        lowerApi.contains('fty') ||
        lowerName.contains('我的云盘') ||
        lowerName.contains('我的网盘')) {
      return ConfigCenterKind.ftyMyDrive;
    }
    if (lowerApi.contains('panconfig') ||
        lowerApi.contains('panwebshare') ||
        lowerName.contains('网盘配置') ||
        lowerName.contains('云盘配置')) {
      return ConfigCenterKind.panConfig;
    }
    return ConfigCenterKind.generic;
  }

  static List<DetectedConfigCenter> detectConfigCenters(
    List<CmsSite> sites, {
    String activeGroup = '',
  }) {
    if (sites.isEmpty) return const <DetectedConfigCenter>[];
    final seen = <String>{};
    final matched = <DetectedConfigCenter>[];
    for (final site in sites) {
      if (!isConfigCenterSite(site)) continue;
      final dedup = '${site.key}|${site.api}';
      if (!seen.add(dedup)) continue;
      final cleanName = site.name
          .replaceAll(RegExp(r'[\r\n]+'), ' ')
          .trim();
      matched.add(
        DetectedConfigCenter(
          site: site,
          kind: classifySite(site),
          displayName: cleanName.isEmpty ? site.key : cleanName,
          group: site.group,
        ),
      );
    }
    if (activeGroup.trim().isNotEmpty && matched.length > 1) {
      final cleanGroup = activeGroup.trim();
      matched.sort((a, b) {
        final aMatch = a.group == cleanGroup ? 0 : 1;
        final bMatch = b.group == cleanGroup ? 0 : 1;
        return aMatch.compareTo(bMatch);
      });
    }
    return matched;
  }

  /// Extracts cloud drive cookies/tokens & preferred drive order from diverse
  /// Config Center JSON / map / string formats (`wexfnwconfig.json`, OK/WEX
  /// `ext` blocks, FTY/MyDrive configs, CatPaw state files, etc.).
  static ExtractedConfigCenterData extractCredentialsFromPayload(dynamic raw) {
    final creds = <String, String>{};
    List<String>? order;

    Map<dynamic, dynamic>? map;
    if (raw is Map) {
      map = raw;
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return const ExtractedConfigCenterData();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) map = decoded;
        } catch (_) {}
      }
    }

    if (map == null) return const ExtractedConfigCenterData();

    void putDrive(String driveKey, dynamic val) {
      if (creds.containsKey(driveKey) && creds[driveKey]!.isNotEmpty) return;
      String candidate = '';
      if (val is String) {
        candidate = val.trim();
      } else if (val is Map) {
        for (final k in const [
          'cookie',
          'Cookie',
          'token',
          'Token',
          'refresh_token',
          'refreshToken',
          'ck',
          'value',
        ]) {
          final v = val[k];
          if (v is String && v.trim().isNotEmpty) {
            candidate = v.trim();
            break;
          }
        }
      }
      if (candidate.isEmpty) return;
      if (candidate.startsWith('http://') || candidate.startsWith('https://')) {
        return;
      }
      if (isCredentialUsableForDrive(driveKey, candidate)) {
        creds[driveKey] = candidate;
      }
    }

    void scanMap(Map<dynamic, dynamic> obj, {int depth = 0}) {
      if (depth > 4) return;
      for (final entry in obj.entries) {
        final rawKey = entry.key?.toString() ?? '';
        final key = rawKey.trim().toLowerCase();
        final value = entry.value;

        if (key == 'pan' ||
            key == 'pans' ||
            key == 'drives' ||
            key == 'netdisk' ||
            key == 'accounts' ||
            key == 'config') {
          if (value is Map) scanMap(value, depth: depth + 1);
          continue;
        }

        if (key == 'quark' ||
            key == 'quarkcookie' ||
            key == 'quark_cookie' ||
            key == 'quarkck' ||
            key == 'qkcookie' ||
            key == 'kuake') {
          putDrive('quark', value);
        } else if (key == 'uc' ||
            key == 'uccookie' ||
            key == 'uc_cookie' ||
            key == 'ucpancookie' ||
            key == 'ucck') {
          putDrive('uc', value);
        } else if (key == 'baidu' ||
            key == 'baiducookie' ||
            key == 'baidu_cookie' ||
            key == 'baidupan' ||
            key == 'bdcookie') {
          putDrive('baidu', value);
        } else if (key == 'ali' ||
            key == 'alipan' ||
            key == 'aliyun' ||
            key == 'alitoken' ||
            key == 'ali_token' ||
            key == 'aliyuntoken' ||
            key == 'aliyun_token' ||
            key == 'token' ||
            key == 'refresh_token') {
          putDrive('ali', value);
        } else if (key == 'order' ||
            key == 'panorder' ||
            key == 'pan_order' ||
            key == 'driveorder' ||
            key == 'drive_order') {
          order ??= parseDriveOrder(value);
        } else if (value is Map && depth < 3) {
          scanMap(value, depth: depth + 1);
        }
      }
    }

    scanMap(map);
    return ExtractedConfigCenterData(credentials: creds, driveOrder: order);
  }

  static bool isCredentialUsableForDrive(String driveKey, String credential) {
    final trimmed = credential.trim();
    if (trimmed.isEmpty) return false;
    if (driveKey == 'quark') {
      return QuarkAccountSession.tryParseCredential(trimmed) != null ||
          NetdiskSession.isUsable('quark', trimmed);
    }
    return NetdiskSession.isUsable(driveKey, trimmed);
  }

  static List<String>? parseDriveOrder(dynamic raw) {
    final tokens = <String>[];
    if (raw is List) {
      for (final item in raw) {
        tokens.add(item.toString());
      }
    } else if (raw is String && raw.trim().isNotEmpty) {
      tokens.addAll(raw.split(RegExp(r'[,|/>;\s]+')));
    } else {
      return null;
    }
    final normalized = <String>[];
    for (final rawToken in tokens) {
      final t = rawToken.trim().toLowerCase();
      if (t.isEmpty) continue;
      String? key;
      if (t.contains('quark') || t.contains('夸克') || t.contains('夸父')) {
        key = 'quark';
      } else if (t == 'uc' || t.contains('优汐') || t.contains('uc')) {
        key = 'uc';
      } else if (t.contains('baidu') || t.contains('百度') || t.contains('嘟嘟')) {
        key = 'baidu';
      } else if (t.contains('ali') || t.contains('阿里') || t.contains('阿狸')) {
        key = 'ali';
      }
      if (key != null && !normalized.contains(key)) {
        normalized.add(key);
      }
    }
    if (normalized.isEmpty) return null;
    for (final fallback in supportedDriveKeys) {
      if (!normalized.contains(fallback)) {
        normalized.add(fallback);
      }
    }
    return normalized;
  }

  /// Synchronizes credentials bidirectionally between Marco's shared
  /// [StorageService], all detected subscription Config Center sites, and the
  /// local CatPaw / WEX / OK / FTY spider runtime files.
  static Future<ConfigCenterSyncReport> syncAll({
    required StorageService storage,
    List<CmsSite> sites = const <CmsSite>[],
    String activeGroup = '',
    bool pullFromExternal = true,
    bool pushToExternal = true,
    bool overwriteExisting = false,
  }) async {
    final centers = detectConfigCenters(sites, activeGroup: activeGroup);
    final imported = <String>[];
    var updatedOrder = false;

    if (pullFromExternal) {
      final discoveredCreds = <String, String>{};
      List<String>? discoveredOrder;

      // 1. Read local CatPaw / WEX / spider runtime stores first (most recent).
      try {
        final localPayload = await CatPawHost.instance.readExternalPanCredentials();
        if (localPayload.isNotEmpty) {
          final parsed = extractCredentialsFromPayload(localPayload);
          for (final e in parsed.credentials.entries) {
            discoveredCreds.putIfAbsent(e.key, () => e.value);
          }
          discoveredOrder ??= parsed.driveOrder;
        }
      } catch (_) {}

      // 2. Read embedded `ext` payloads from detected Config Center sites.
      for (final center in centers) {
        final parsed = extractCredentialsFromPayload(center.site.ext);
        for (final e in parsed.credentials.entries) {
          discoveredCreds.putIfAbsent(e.key, () => e.value);
        }
        discoveredOrder ??= parsed.driveOrder;
      }

      for (final driveKey in supportedDriveKeys) {
        final incoming = discoveredCreds[driveKey];
        if (incoming == null || incoming.isEmpty) continue;
        final alreadyLogged = storage.isNetdiskLoggedIn(driveKey);
        if (alreadyLogged && !overwriteExisting) continue;
        await storage.setNetdiskCredential(driveKey, incoming);
        imported.add(driveKey);
      }

      if (discoveredOrder != null &&
          discoveredOrder.isNotEmpty &&
          (overwriteExisting || !storage.hasCustomDriveOrder)) {
        if (discoveredOrder.join(',') != storage.driveOrder.join(',')) {
          await storage.setDriveOrder(
            discoveredOrder,
            markCustomized: false,
          );
          updatedOrder = true;
        }
      }
    }

    final exported = <String>[];
    for (final driveKey in supportedDriveKeys) {
      if (storage.isNetdiskLoggedIn(driveKey)) {
        exported.add(driveKey);
      }
    }

    var syncedTargets = 0;
    if (pushToExternal) {
      try {
        syncedTargets = await CatPawHost.instance.syncNetdiskConfigWithStorage(
          storage,
        );
      } catch (_) {}
    }

    return ConfigCenterSyncReport(
      detectedCenters: centers,
      importedDrives: imported,
      exportedDrives: exported,
      syncedTargetCount: syncedTargets,
      updatedDriveOrder: updatedOrder,
    );
  }
}
