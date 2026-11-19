import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';
import '../core/cms_client.dart';
import '../core/csp_bridge.dart';
import '../core/models.dart';
import '../core/spider_gateway.dart';
import '../core/spider_plugin_registry.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'ios_settings.dart';

/// iOS 26 / cross-platform Settings panel for:
/// 1. Hot-pluggable Script Adapter Packs (`marco-adapter-pack-v1`, local JS/DRPY/Python/T4)
/// 2. Optional user-owned BYO Spider Gateway (`marco-spider-gateway-v1`, LAN Android / Docker)
class SpiderExtensionsPanel extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;
  final List<CmsSite> sites;
  final VoidCallback onChanged;
  final void Function(String title, String message)? onNotice;

  const SpiderExtensionsPanel({
    super.key,
    required this.storage,
    required this.client,
    required this.sites,
    required this.onChanged,
    this.onNotice,
  });

  @override
  State<SpiderExtensionsPanel> createState() => _SpiderExtensionsPanelState();
}

class _SpiderExtensionsPanelState extends State<SpiderExtensionsPanel> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;
  bool _gatewayEnabled = false;
  bool _tokenObscured = true;
  bool _testingGateway = false;
  bool _discoveringLan = false;
  bool _importingPack = false;
  String? _gatewayStatusText;
  bool? _gatewayStatusOk;

  @override
  void initState() {
    super.initState();
    final cfg = widget.storage.spiderGatewayConfig;
    _gatewayEnabled = cfg.enabled;
    _urlCtrl = TextEditingController(text: cfg.baseUrl);
    _tokenCtrl = TextEditingController(text: cfg.token);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  void _notify(String title, String message) {
    final cb = widget.onNotice;
    if (cb != null) {
      cb(title, message);
      return;
    }
    if (!mounted) return;
    unawaited(
      showAppleNativeAlert(
        context,
        title: title,
        message: message,
        actions: const [
          AppleNativeAlertAction(id: 'ok', title: '好的', isDefault: true),
        ],
      ),
    );
  }

  Future<void> _saveGateway({bool? enabledOverride, String? deviceName}) async {
    final nextEnabled = enabledOverride ?? _gatewayEnabled;
    final rawUrl = _urlCtrl.text.trim();
    if (nextEnabled && SpiderGatewayConfig.normalizeBaseUrl(rawUrl).isEmpty) {
      setState(() {
        _gatewayEnabled = false;
        _gatewayStatusOk = false;
        _gatewayStatusText = '请先填写有效的网关地址后再开启（例如局域网 Android 端或自建 Docker 地址）';
      });
      return;
    }
    try {
      await widget.storage.saveSpiderGatewayConfig(
        SpiderGatewayConfig(
          enabled: nextEnabled,
          baseUrl: rawUrl,
          token: _tokenCtrl.text.trim(),
          deviceName: deviceName ?? widget.storage.spiderGatewayConfig.deviceName,
        ),
      );
      if (!mounted) return;
      final saved = widget.storage.spiderGatewayConfig;
      setState(() {
        _gatewayEnabled = saved.enabled;
        _urlCtrl.text = saved.baseUrl;
        _gatewayStatusOk = true;
        _gatewayStatusText = saved.isActive
            ? '已保存并启用自建网关兜底，仅代理未适配 .so 线路元数据'
            : '已保存配置（当前未启用网关）';
      });
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _gatewayStatusOk = false;
        _gatewayStatusText = CmsClient.cleanErrorMessage(e);
      });
    }
  }

  Future<void> _testGatewayConnection() async {
    final normalized = SpiderGatewayConfig.normalizeBaseUrl(_urlCtrl.text);
    if (normalized.isEmpty) {
      setState(() {
        _gatewayStatusOk = false;
        _gatewayStatusText = '请先填写有效的 HTTP(S) 网关地址';
      });
      return;
    }
    setState(() {
      _testingGateway = true;
      _gatewayStatusText = '正在探测网关健康状态…';
      _gatewayStatusOk = null;
    });
    final res = await SpiderGatewayClient.checkHealth(
      SpiderGatewayConfig(
        enabled: true,
        baseUrl: normalized,
        token: _tokenCtrl.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _testingGateway = false;
      _gatewayStatusOk = res.ok;
      _gatewayStatusText = res.message;
    });
    if (res.ok && res.deviceName.isNotEmpty) {
      await _saveGateway(
        enabledOverride: _gatewayEnabled,
        deviceName: res.deviceName,
      );
    }
  }

  Future<void> _discoverLanAndroidGateways() async {
    setState(() {
      _discoveringLan = true;
      _gatewayStatusOk = null;
      _gatewayStatusText = '正在搜索同一局域网内开启网关的 Android 设备…';
    });
    final found = await SpiderGatewayClient.discoverLanGateways();
    if (!mounted) return;
    setState(() => _discoveringLan = false);
    if (found.isEmpty) {
      setState(() {
        _gatewayStatusOk = false;
        _gatewayStatusText =
            '未发现局域网网关。请在 Android 端「设置 → 订阅与账号 → 局域网蜘蛛网关」开启服务，或手动填写地址。';
      });
      return;
    }
    final picked = await showAppleNativeActionSheet<DiscoveredSpiderGateway>(
      context,
      title: '发现 ${found.length} 台局域网蜘蛛网关',
      message: '选择后将自动填入地址；出于安全考虑，仍需输入该设备上显示的访问令牌（Token）。',
      options: [
        for (final g in found)
          AppleNativeSheetOption<DiscoveredSpiderGateway>(
            value: g,
            title: '${g.deviceName} · ${g.baseUrl}',
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _urlCtrl.text = picked.baseUrl;
      _gatewayStatusOk = true;
      _gatewayStatusText = '已填入「${picked.deviceName}」，请输入设备令牌后保存或测试连接';
    });
  }

  Future<void> _openImportPackDialog() async {
    final inputCtrl = TextEditingController();
    String? errorMsg;
    var busy = false;
    final imported = await showAppleModalSheet<SpiderAdapterPack>(
      context: context,
      title: '导入脚本扩展包',
      maxWidth: 560,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> submit() async {
            final raw = inputCtrl.text.trim();
            if (raw.isEmpty) {
              setSheetState(() => errorMsg = '请粘贴插件包 JSON 内容或 HTTP(S) 链接');
              return;
            }
            setSheetState(() {
              busy = true;
              errorMsg = null;
            });
            try {
              SpiderAdapterPack pack;
              if (raw.startsWith('{')) {
                pack = await widget.storage.importSpiderAdapterPackJson(raw);
              } else {
                final remote = await widget.client.fetchSpiderAdapterPack(raw);
                final current = List<SpiderAdapterPack>.of(
                  widget.storage.spiderAdapterPacks,
                );
                final idx = current.indexWhere((p) => p.id == remote.id);
                if (idx >= 0) {
                  current[idx] = remote;
                } else {
                  current.insert(0, remote);
                }
                await widget.storage.saveSpiderAdapterPacks(current);
                pack = remote;
              }
              if (ctx.mounted) Navigator.of(ctx).pop(pack);
            } catch (e) {
              if (ctx.mounted) {
                setSheetState(() {
                  busy = false;
                  errorMsg = CmsClient.cleanErrorMessage(e);
                });
              }
            }
          }

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              18,
              14,
              18,
              20 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '支持输入社区 / 自建的 marco-adapter-pack-v1 扩展包链接（https://plugins.example/pack.json）或直接粘贴 JSON，所有脚本均在本机运行，无需任何官方服务器。',
                  style: TextStyle(
                    color: AppleColors.labelSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 12),
                CupertinoTextField(
                  key: const ValueKey('spider-pack-import-input'),
                  controller: inputCtrl,
                  maxLines: 6,
                  minLines: 3,
                  autocorrect: false,
                  placeholder: '粘贴插件包 JSON 或 https://plugins.example/pack.json',
                  placeholderStyle: const TextStyle(
                    color: Color(0x70EBEBF5),
                    fontSize: 13.5,
                  ),
                  style: const TextStyle(
                    color: AppleColors.labelPrimary,
                    fontSize: 13.5,
                  ),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0x28FFFFFF),
                      width: 0.6,
                    ),
                  ),
                ),
                if (errorMsg != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorMsg!,
                    style: const TextStyle(
                      color: AppleColors.systemRed,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                CupertinoButton.filled(
                  key: const ValueKey('spider-pack-import-submit'),
                  onPressed: busy ? null : submit,
                  child: busy
                      ? const CupertinoActivityIndicator(color: Colors.white)
                      : const Text(
                          '验证并导入扩展包',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
    inputCtrl.dispose();
    if (imported != null && mounted) {
      setState(() {});
      widget.onChanged();
      _notify(
        '已导入扩展包',
        '「${imported.name}」包含 ${imported.rules.length} 条跨平台适配规则，已立即生效。',
      );
    }
  }

  Future<void> _managePack(SpiderAdapterPack pack) async {
    final ruleSummary = pack.rules
        .take(5)
        .map(
          (r) =>
              '• ${r.matchApis.isNotEmpty ? r.matchApis.join(", ") : r.matchNamePattern} → ${r.kind.displayName}',
        )
        .join('\n');
    final extra = pack.rules.length > 5
        ? '\n…等共 ${pack.rules.length} 条规则'
        : '';
    final choice = await showAppleNativeAlert(
      context,
      title: '${pack.name} (${pack.version})',
      message:
          '${pack.description.isNotEmpty ? '${pack.description}\n\n' : ''}$ruleSummary$extra',
      actions: [
        if (pack.sourceUrl.isNotEmpty)
          const AppleNativeAlertAction(id: 'refresh', title: '从链接更新'),
        const AppleNativeAlertAction(
          id: 'delete',
          title: '移除扩展包',
          isDestructive: true,
        ),
        const AppleNativeAlertAction(id: 'ok', title: '关闭', isDefault: true),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'delete') {
      await widget.storage.removeSpiderAdapterPack(pack.id);
      if (mounted) setState(() {});
      widget.onChanged();
    } else if (choice == 'refresh' && pack.sourceUrl.isNotEmpty) {
      setState(() => _importingPack = true);
      try {
        final refreshed = await widget.client.fetchSpiderAdapterPack(
          pack.sourceUrl,
        );
        final updated = widget.storage.spiderAdapterPacks
            .map((p) => p.id == pack.id ? refreshed.copyWith(id: pack.id) : p)
            .toList();
        await widget.storage.saveSpiderAdapterPacks(updated);
        if (mounted) {
          setState(() {});
          widget.onChanged();
          _notify('已更新扩展包', '「${refreshed.name}」已更新至 ${refreshed.version}。');
        }
      } catch (e) {
        if (mounted) {
          _notify('更新失败', CmsClient.cleanErrorMessage(e));
        }
      } finally {
        if (mounted) setState(() => _importingPack = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.sites
        .where((s) => !CspBridge.isPickerHiddenUtilitySite(s))
        .toList();
    var nativeCount = 0;
    var packCount = 0;
    var gatewayCount = 0;
    var unsupportedCount = 0;
    for (final s in visible) {
      if (s.usesAdapterPack) {
        packCount++;
      } else if (s.usesSpiderGateway) {
        gatewayCount++;
      } else if (s.supported) {
        nativeCount++;
      } else {
        unsupportedCount++;
      }
    }
    final packs = widget.storage.spiderAdapterPacks;
    final hasGatewayUrl =
        SpiderGatewayConfig.normalizeBaseUrl(_urlCtrl.text).isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Live Coverage Summary (Local-First priority)
        IosSettingsGroup(
          header: '当前片源解析覆盖（本机优先）',
          footer:
              '执行优先级：本机内置适配 → 扩展插件包（本地 JS/DRPY/Python/T4）→ 您自建的蜘蛛网关。已在本机适配的片源永不经过网关。',
          children: [
            IosSettingsRow(
              icon: CupertinoIcons.checkmark_shield_fill,
              iconColor: AppleColors.systemGreen,
              title: '本机原生已适配',
              trailingText: '$nativeCount 条',
            ),
            IosSettingsRow(
              icon: CupertinoIcons.cube_box_fill,
              iconColor: AppleColors.systemPurple,
              title: '扩展插件包接管',
              trailingText: '$packCount 条',
            ),
            IosSettingsRow(
              icon: CupertinoIcons.antenna_radiowaves_left_right,
              iconColor: AppleColors.systemTeal,
              title: '自建网关兜底接管',
              trailingText: '$gatewayCount 条',
            ),
            IosSettingsRow(
              icon: CupertinoIcons.exclamationmark_triangle_fill,
              iconColor: unsupportedCount > 0
                  ? AppleColors.systemOrange
                  : const Color(0xFF636366),
              title: '暂未适配（含 .so 依赖）',
              trailingText: '$unsupportedCount 条',
            ),
          ],
        ),
        const SizedBox(height: 22),

        // 2. Short-Term Solution: Hot-Pluggable Script Adapter Packs
        IosSettingsGroup(
          header: '脚本扩展包（热更新 · 纯本地运行）',
          footer:
              '无需发版即可通过社区或自编的 JS / DRPY2 / Python / T4 脚本扩展包接管未适配的 csp_* 线路，一次编写即可在 iOS、macOS、Windows、鸿蒙通用。',
          children: [
            for (final pack in packs)
              IosSettingsRow(
                key: ValueKey('spider-pack-row-${pack.id}'),
                icon: CupertinoIcons.cube_box_fill,
                iconColor: pack.enabled
                    ? AppleColors.systemPurple
                    : const Color(0xFF636366),
                title: pack.name,
                subtitle: '${pack.rules.length} 条规则 · v${pack.version}',
                trailing: IosNativeSwitch(
                  value: pack.enabled,
                  activeColor: AppleColors.systemGreen,
                  accessibilityLabel: '启用 ${pack.name}',
                  onChanged: (v) async {
                    await widget.storage.setSpiderAdapterPackEnabled(
                      pack.id,
                      v,
                    );
                    if (mounted) setState(() {});
                    widget.onChanged();
                  },
                ),
                onTap: () => _managePack(pack),
              ),
            IosSettingsRow(
              key: const ValueKey('spider-import-pack-row'),
              icon: CupertinoIcons.plus_circle_fill,
              iconColor: AppleColors.systemBlue,
              title: _importingPack ? '正在更新扩展包…' : '导入脚本扩展包（URL / JSON）',
              showChevron: true,
              onTap: _importingPack ? null : _openImportPackDialog,
            ),
            IosSettingsRow(
              key: const ValueKey('spider-copy-template-row'),
              icon: CupertinoIcons.doc_on_doc_fill,
              iconColor: AppleColors.systemIndigo,
              title: '复制扩展包 JSON 模板',
              trailingText: 'v1 规范',
              onTap: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: SpiderPluginRegistry.samplePackTemplateJson(),
                  ),
                );
                _notify(
                  '已复制模板',
                  '已复制 marco-adapter-pack-v1 规范模板到剪贴板，修改后可直接粘贴导入。',
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 22),

        // 3. Mid-Term Solution: Optional BYO Spider Gateway (Zero Author Server)
        IosSettingsGroup(
          header: '自建蜘蛛网关兜底（可选 · 零官方服务器）',
          footer:
              '默认关闭。Marco Movie 不提供也不托管任何官方中转服务；启用后仅连接您自己在局域网 Android 端或个人 NAS / Docker 上运行的网关，仅传输目录与播放链接 JSON，视频画面仍由本机直连播放。',
          children: [
            IosSettingsSwitchRow(
              key: const ValueKey('spider-gateway-switch'),
              icon: CupertinoIcons.personalhotspot,
              iconColor: AppleColors.systemTeal,
              title: '启用自建蜘蛛网关兜底',
              subtitle: _gatewayEnabled
                  ? (widget.storage.spiderGatewayConfig.deviceName.isNotEmpty
                      ? '当前连接：${widget.storage.spiderGatewayConfig.deviceName}'
                      : '仅接管本机与扩展包均未适配的 .so 线路')
                  : '关闭状态，所有请求均在本地完成',
              value: _gatewayEnabled,
              onChanged: (v) async {
                setState(() => _gatewayEnabled = v);
                await _saveGateway(enabledOverride: v);
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '网关地址（局域网 Android 端或自建 Docker）',
                    style: TextStyle(
                      color: Color(0x99EBEBF5),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  CupertinoTextField(
                    key: const ValueKey('spider-gateway-url-input'),
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    placeholder: '例如 http://127.0.0.1:9981 或 https://gateway.example',
                    placeholderStyle: const TextStyle(
                      color: Color(0x66EBEBF5),
                      fontSize: 14,
                    ),
                    style: const TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 14.5,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '访问令牌（Bearer Token，仅保存在本机安全存储）',
                    style: TextStyle(
                      color: Color(0x99EBEBF5),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  CupertinoTextField(
                    key: const ValueKey('spider-gateway-token-input'),
                    controller: _tokenCtrl,
                    obscureText: _tokenObscured,
                    autocorrect: false,
                    placeholder: '输入 Android 端或自建服务显示的令牌',
                    placeholderStyle: const TextStyle(
                      color: Color(0x66EBEBF5),
                      fontSize: 14,
                    ),
                    style: const TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 14.5,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    suffix: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () =>
                          setState(() => _tokenObscured = !_tokenObscured),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Icon(
                          _tokenObscured
                              ? CupertinoIcons.eye
                              : CupertinoIcons.eye_slash,
                          size: 18,
                          color: const Color(0x99EBEBF5),
                        ),
                      ),
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  if (_gatewayStatusText != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _gatewayStatusText!,
                      style: TextStyle(
                        color: _gatewayStatusOk == true
                            ? AppleColors.systemGreen
                            : (_gatewayStatusOk == false
                                ? AppleColors.systemOrange
                                : AppleColors.labelSecondary),
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IosSettingsRow(
              key: const ValueKey('spider-gateway-discover-btn'),
              icon: CupertinoIcons.wifi,
              iconColor: AppleColors.systemBlue,
              title: _discoveringLan ? '正在搜索局域网 Android 端…' : '局域网发现 Android 端',
              trailing: _discoveringLan
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              showChevron: !_discoveringLan,
              onTap: _discoveringLan ? null : _discoverLanAndroidGateways,
            ),
            IosSettingsRow(
              key: const ValueKey('spider-gateway-test-btn'),
              icon: CupertinoIcons.bolt_horizontal_circle_fill,
              iconColor: hasGatewayUrl
                  ? AppleColors.systemGreen
                  : const Color(0xFF636366),
              title: _testingGateway ? '正在测试网关连通性…' : '测试网关连接',
              trailing: _testingGateway
                  ? const CupertinoActivityIndicator(radius: 9)
                  : null,
              showChevron: !_testingGateway,
              onTap: _testingGateway ? null : _testGatewayConnection,
            ),
            IosSettingsRow(
              key: const ValueKey('spider-gateway-save-btn'),
              title: '保存网关配置',
              titleColor: AppleColors.systemBlue,
              onTap: () => _saveGateway(),
            ),
          ],
        ),
      ],
    );
  }
}
