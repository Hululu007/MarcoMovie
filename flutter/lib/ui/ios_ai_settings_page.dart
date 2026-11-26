import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';

import '../core/ai_service.dart';
import '../core/ai_title_cleaner.dart';
import '../core/ohos_runtime.dart';
import 'apple_theme.dart';
import 'ios_settings.dart';

/// True when running on iOS where Phase 1 BYO-API AI surfaces are enabled.
bool get isIosAiFeatureSupported =>
    !kIsWeb && !OhosRuntime.isOhos && defaultTargetPlatform == TargetPlatform.iOS;

/// Pushes the standalone iOS BYO-API AI Assistant settings page.
Future<void> pushIosAiSettingsPage(
  BuildContext context, {
  String backLabel = '设置',
  AiService? service,
}) async {
  if (!isIosAiFeatureSupported) return;
  await Navigator.of(context).push<void>(
    buildApplePageRoute<void>(
      builder: (_) => IosAiSettingsPage(
        backLabel: backLabel,
        service: service,
      ),
    ),
  );
}

/// Native iOS 26/27 inset-grouped settings page for Bring-Your-Own-API (BYO-API)
/// AI Assistant configuration, Keychain credential storage, connection testing,
/// monthly token quota, and response cache management.
class IosAiSettingsPage extends StatefulWidget {
  final String backLabel;
  final AiService? service;
  final VoidCallback? onChanged;

  const IosAiSettingsPage({
    super.key,
    this.backLabel = '设置',
    this.service,
    this.onChanged,
  });

  @override
  State<IosAiSettingsPage> createState() => _IosAiSettingsPageState();
}

class _IosAiSettingsPageState extends State<IosAiSettingsPage> {
  late final AiService _service;
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _fastModelCtrl = TextEditingController();
  final TextEditingController _budgetCtrl = TextEditingController();

  AiConfig _config = const AiConfig();
  bool _obscureApiKey = true;
  bool _testingConnection = false;
  AiConnectionTestResult? _testResult;
  String? _cacheStatusNotice;

  static const List<(int, String)> _budgetPresets = <(int, String)>[
    (0, '不限配额'),
    (50000, '5 万'),
    (200000, '20 万'),
    (500000, '50 万'),
  ];

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AiService.instance;
    _service.addListener(_onServiceChanged);
    unawaited(_loadInitialState());
  }

  Future<void> _loadInitialState() async {
    await _service.ensureLoaded();
    final key = await _service.readApiKey();
    if (!mounted) return;
    final cfg = _service.config;
    setState(() {
      _config = cfg;
      if (_baseUrlCtrl.text != cfg.baseUrl) {
        _baseUrlCtrl.text = cfg.baseUrl;
      }
      if (_apiKeyCtrl.text != key) {
        _apiKeyCtrl.text = key;
      }
      if (_modelCtrl.text != cfg.model) {
        _modelCtrl.text = cfg.model;
      }
      if (_fastModelCtrl.text != cfg.fastModel) {
        _fastModelCtrl.text = cfg.fastModel;
      }
      final budgetText =
          cfg.monthlyTokenBudget > 0 ? '${cfg.monthlyTokenBudget}' : '';
      if (_budgetCtrl.text != budgetText) {
        _budgetCtrl.text = budgetText;
      }
    });
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {
      _config = _service.config;
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _fastModelCtrl.dispose();
    _budgetCtrl.dispose();
    super.dispose();
  }

  AiConfig _draftConfigFromControllers([AiConfig? base]) {
    final seed = base ?? _config;
    final rawBudget = _budgetCtrl.text.trim();
    final parsedBudget =
        rawBudget.isEmpty ? 0 : (int.tryParse(rawBudget) ?? seed.monthlyTokenBudget);
    return seed.copyWith(
      baseUrl: _baseUrlCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
      fastModel: _fastModelCtrl.text.trim(),
      monthlyTokenBudget: parsedBudget < 0 ? 0 : parsedBudget,
    );
  }

  Future<void> _persistDraft({AiConfig? overrideConfig}) async {
    final next = overrideConfig ?? _draftConfigFromControllers();
    _config = next;
    await _service.saveConfig(next);
    await _service.setApiKey(_apiKeyCtrl.text);
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _handleTestConnection() async {
    if (_testingConnection) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _testingConnection = true;
      _testResult = null;
      _cacheStatusNotice = null;
    });
    await _persistDraft();
    final result = await _service.testConnection(
      configOverride: _config,
      apiKeyOverride: _apiKeyCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _testingConnection = false;
      _testResult = result;
    });
  }

  Future<void> _handleClearCache() async {
    HapticFeedback.selectionClick();
    await _service.clearCache();
    AiTitleCleaner.instance.clearMemoryCache();
    if (!mounted) return;
    setState(() {
      _cacheStatusNotice = '已清空 AI 本地响应缓存';
    });
    widget.onChanged?.call();
  }

  Widget _buildSwitchCell({
    required Key rowKey,
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return IosSettingsRow(
      key: rowKey,
      icon: icon,
      iconColor: iconColor,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: CupertinoSwitch(
        value: value,
        activeTrackColor: AppleColors.systemGreen,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildLabeledTextField({
    required BuildContext context,
    required Key fieldKey,
    required String label,
    required TextEditingController controller,
    required String placeholder,
    TextInputType keyboardType = TextInputType.text,
    bool obscureText = false,
    Widget? suffix,
    List<TextInputFormatter>? inputFormatters,
    required ValueChanged<String> onChanged,
  }) {
    final p = ApplePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: p.labelSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: CupertinoTextField(
                  key: fieldKey,
                  controller: controller,
                  placeholder: placeholder,
                  obscureText: obscureText,
                  keyboardType: keyboardType,
                  autocorrect: false,
                  enableSuggestions: !obscureText,
                  inputFormatters: inputFormatters,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 9,
                  ),
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 15.5,
                  ),
                  placeholderStyle: TextStyle(
                    color: p.labelTertiary,
                    fontSize: 14.5,
                  ),
                  decoration: BoxDecoration(
                    color: p.isDark
                        ? const Color(0xFF28282E)
                        : const Color(0xFFF1F3F8),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: p.isDark
                          ? const Color(0x24FFFFFF)
                          : const Color(0x14000000),
                      width: 0.6,
                    ),
                  ),
                  onChanged: onChanged,
                  onEditingComplete: () => unawaited(_persistDraft()),
                ),
              ),
              if (suffix != null) ...[
                const SizedBox(width: 8),
                suffix,
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyBanner(BuildContext context) {
    final p = ApplePalette.of(context);
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: p.isDark
              ? const [Color(0x3832549A), Color(0x281E1E28)]
              : const [Color(0xFFEAF1FF), Color(0xFFF4F6FC)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: p.systemBlue.withValues(alpha: p.isDark ? 0.35 : 0.22),
          width: 0.75,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: p.systemBlue.withValues(alpha: p.isDark ? 0.24 : 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              CupertinoIcons.lock_shield_fill,
              color: p.systemBlue,
              size: 19,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '自带密钥（BYO-API）与本地隐私保护',
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '• 应用零内置接口与密钥，API 密钥仅保存在本机 iOS 钥匙串（Keychain），绝不写入明文配置或云端同步。\n'
                  '• 仅发送您的找片描述或待清洗文件名，模型只返回片名等结构化元数据，绝不生成或上传播放链接。\n'
                  '• 进入隐私空间后自动硬性阻断全部外部 AI 请求。',
                  style: TextStyle(
                    color: p.labelSecondary,
                    fontSize: 12.5,
                    height: 1.48,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) return const SizedBox.shrink();
    final p = ApplePalette.of(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final hPad = screenWidth >= 600 ? 24.0 : 18.0;
    final usage = _service.monthlyUsage;
    final cacheCount = _service.cachedEntryCount;

    return IosSettingsScaffold(
      title: 'AI 助手',
      backLabel: widget.backLabel,
      body: ListView(
        key: const ValueKey('ios-ai-settings-page'),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(hPad, 16, hPad, safeBottom + 44),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 740),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPrivacyBanner(context),
                  const SizedBox(height: 18),
                  IosSettingsGroup(
                    footer: '默认关闭且接口地址为空；填写您自有的兼容接口、密钥与模型后即可生效。',
                    children: [
                      _buildSwitchCell(
                        rowKey: const ValueKey('ios-ai-enable-switch'),
                        icon: CupertinoIcons.sparkles,
                        iconColor: AppleColors.systemIndigo,
                        title: '启用 AI 助手',
                        subtitle: _service.isConfigured
                            ? '已就绪 · ${_config.protocol.labelZh}'
                            : '需填写接口地址、API 密钥与主模型名称',
                        value: _config.enabled,
                        onChanged: (val) {
                          final next = _draftConfigFromControllers()
                              .copyWith(enabled: val);
                          unawaited(_persistDraft(overrideConfig: next));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SettingsChoices<AiApiProtocol>(
                    title: '接口协议',
                    footer:
                        '支持标准 OpenAI 兼容 Chat Completions、Anthropic Messages 与 Google Gemini GenerateContent 协议。',
                    value: _config.protocol,
                    choices: const <(AiApiProtocol, String)>[
                      (AiApiProtocol.openaiCompatible, 'OpenAI 兼容接口'),
                      (AiApiProtocol.anthropicMessages, 'Anthropic Messages'),
                      (AiApiProtocol.geminiGenerateContent, 'Google Gemini'),
                    ],
                    onSelected: (protocol) async {
                      final next = _draftConfigFromControllers()
                          .copyWith(protocol: protocol);
                      await _persistDraft(overrideConfig: next);
                    },
                  ),
                  IosSettingsGroup(
                    header: '接口地址、密钥与模型',
                    footer:
                        '示例接口格式如 https://api.example/v1（应用不预置任何服务商地址）。轻量清洗模型留空时默认复用主模型。',
                    dividerIndent: 16,
                    children: [
                      _buildLabeledTextField(
                        context: context,
                        fieldKey: const ValueKey('ios-ai-baseurl-field'),
                        label: '接口地址 (Base URL)',
                        controller: _baseUrlCtrl,
                        placeholder: 'https://api.example/v1',
                        keyboardType: TextInputType.url,
                        onChanged: (_) {
                          unawaited(_persistDraft());
                        },
                      ),
                      _buildLabeledTextField(
                        context: context,
                        fieldKey: const ValueKey('ios-ai-apikey-field'),
                        label: 'API 密钥（仅存本机钥匙串）',
                        controller: _apiKeyCtrl,
                        placeholder: '输入您的 API Key',
                        obscureText: _obscureApiKey,
                        suffix: CupertinoButton(
                          padding: const EdgeInsets.all(6),
                          minimumSize: const Size(34, 34),
                          onPressed: () {
                            setState(() => _obscureApiKey = !_obscureApiKey);
                          },
                          child: Icon(
                            _obscureApiKey
                                ? CupertinoIcons.eye_slash
                                : CupertinoIcons.eye,
                            size: 18,
                            color: p.labelSecondary,
                          ),
                        ),
                        onChanged: (v) {
                          unawaited(_service.setApiKey(v));
                        },
                      ),
                      _buildLabeledTextField(
                        context: context,
                        fieldKey: const ValueKey('ios-ai-model-field'),
                        label: '主模型名称',
                        controller: _modelCtrl,
                        placeholder: 'model-chat',
                        onChanged: (_) {
                          unawaited(_persistDraft());
                        },
                      ),
                      _buildLabeledTextField(
                        context: context,
                        fieldKey: const ValueKey('ios-ai-fast-model-field'),
                        label: '轻量清洗模型（可选）',
                        controller: _fastModelCtrl,
                        placeholder: '留空则默认使用主模型',
                        onChanged: (_) {
                          unawaited(_persistDraft());
                        },
                      ),
                      IosSettingsRow(
                        key: const ValueKey('ios-ai-test-btn'),
                        icon: CupertinoIcons.bolt_horizontal_circle_fill,
                        iconColor: AppleColors.systemBlue,
                        title: _testingConnection ? '正在测试连接…' : '测试连接',
                        titleColor: p.systemBlue,
                        trailingText: _testResult == null
                            ? null
                            : (_testResult!.ok
                                ? '${_testResult!.latencyMs} ms'
                                : '未通过'),
                        onTap: _testingConnection ? null : _handleTestConnection,
                      ),
                    ],
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      key: const ValueKey('ios-ai-test-result-banner'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: (_testResult!.ok
                                ? AppleColors.systemGreen
                                : AppleColors.systemOrange)
                            .withValues(alpha: p.isDark ? 0.18 : 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: (_testResult!.ok
                                  ? AppleColors.systemGreen
                                  : AppleColors.systemOrange)
                              .withValues(alpha: 0.40),
                          width: 0.7,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _testResult!.ok
                                ? CupertinoIcons.checkmark_seal_fill
                                : CupertinoIcons.exclamationmark_triangle_fill,
                            size: 18,
                            color: _testResult!.ok
                                ? AppleColors.systemGreen
                                : AppleColors.systemOrange,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              _testResult!.messageZh,
                              style: TextStyle(
                                color: p.labelPrimary,
                                fontSize: 13.5,
                                height: 1.38,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  IosSettingsGroup(
                    header: '功能开关',
                    footer:
                        '自然语言找片仅在您已配置的自有片源中匹配真实可播结果；文件名智能清洗在浏览网盘/WebDAV/SMB 目录时后台静默增强。',
                    children: [
                      _buildSwitchCell(
                        rowKey: const ValueKey('ios-ai-nlsearch-switch'),
                        icon: CupertinoIcons.search_circle_fill,
                        iconColor: AppleColors.systemTeal,
                        title: '自然语言找片',
                        subtitle: '按题材、氛围或情节描述匹配自有片源中的影片',
                        value: _config.nlSearchEnabled,
                        onChanged: (val) {
                          final next = _draftConfigFromControllers()
                              .copyWith(nlSearchEnabled: val);
                          unawaited(_persistDraft(overrideConfig: next));
                        },
                      ),
                      _buildSwitchCell(
                        rowKey: const ValueKey('ios-ai-titleclean-switch'),
                        icon: CupertinoIcons.wand_stars,
                        iconColor: AppleColors.systemPurple,
                        title: '文件名与标题智能清洗',
                        subtitle: '自动提炼杂乱文件名中的标准片名、年份与季集号',
                        value: _config.titleCleanupEnabled,
                        onChanged: (val) {
                          final next = _draftConfigFromControllers()
                              .copyWith(titleCleanupEnabled: val);
                          unawaited(_persistDraft(overrideConfig: next));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  IosSettingsGroup(
                    header: '月度配额与缓存（${usage.monthKey}）',
                    footer:
                        '相同查询与文件名命中本地 SHA-256 缓存时消耗 0 Token；达到月度 Token 上限后自动停止发起外部请求。',
                    dividerIndent: 16,
                    children: [
                      IosSettingsRow(
                        icon: CupertinoIcons.chart_bar_alt_fill,
                        iconColor: AppleColors.systemGreen,
                        title: '本月用量统计',
                        subtitle:
                            '输入 ${usage.promptTokens} · 输出 ${usage.completionTokens} · 本地缓存 $cacheCount 条',
                        trailingText:
                            '本月调用 ${usage.requestCount} 次 · 约 ${usage.totalTokens} tokens',
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '月度 Token 预算上限（0 表示不限）',
                              style: TextStyle(
                                color: p.labelSecondary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final preset in _budgetPresets)
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      _budgetCtrl.text =
                                          preset.$1 > 0 ? '${preset.$1}' : '';
                                      final next = _draftConfigFromControllers()
                                          .copyWith(
                                        monthlyTokenBudget: preset.$1,
                                      );
                                      unawaited(
                                        _persistDraft(overrideConfig: next),
                                      );
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 11,
                                        vertical: 5.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _config.monthlyTokenBudget ==
                                                preset.$1
                                            ? p.systemBlue
                                            : (p.isDark
                                                ? const Color(0xFF2C2C34)
                                                : const Color(0xFFEAECEF)),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        preset.$2,
                                        style: TextStyle(
                                          color: _config.monthlyTokenBudget ==
                                                  preset.$1
                                              ? Colors.white
                                              : p.labelPrimary,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            CupertinoTextField(
                              key: const ValueKey('ios-ai-budget-field'),
                              controller: _budgetCtrl,
                              placeholder: '自定义月度上限（留空或 0 为不限）',
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 8,
                              ),
                              style: TextStyle(
                                color: p.labelPrimary,
                                fontSize: 14.5,
                              ),
                              placeholderStyle: TextStyle(
                                color: p.labelTertiary,
                                fontSize: 13.5,
                              ),
                              decoration: BoxDecoration(
                                color: p.isDark
                                    ? const Color(0xFF28282E)
                                    : const Color(0xFFF1F3F8),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              onChanged: (_) => unawaited(_persistDraft()),
                            ),
                          ],
                        ),
                      ),
                      IosSettingsRow(
                        key: const ValueKey('ios-ai-clear-cache-btn'),
                        icon: CupertinoIcons.trash_fill,
                        iconColor: AppleColors.systemOrange,
                        title: '清空 AI 缓存',
                        trailingText: _cacheStatusNotice ?? '$cacheCount 条',
                        onTap: _handleClearCache,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
