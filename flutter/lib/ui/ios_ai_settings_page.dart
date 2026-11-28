import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart' show Colors, Material, MaterialType;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ai_lab_gate.dart';
import '../core/ai_service.dart';
import '../core/ai_title_cleaner.dart';
import '../core/ohos_runtime.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'ios_settings.dart';
import 'official_channel_notice.dart';

/// True when running on iOS where AI Assistant surfaces are enabled.
bool get isIosAiFeatureSupported =>
    !kIsWeb && !OhosRuntime.isOhos && defaultTargetPlatform == TargetPlatform.iOS;

/// Pushes the standalone iOS AI Viewing Lab settings page.
Future<void> pushIosAiSettingsPage(
  BuildContext context, {
  String backLabel = '设置',
  AiService? service,
  Future<bool> Function(Uri uri)? urlLauncherOverride,
}) async {
  if (!isIosAiFeatureSupported) return;
  await Navigator.of(context).push<void>(
    buildApplePageRoute<void>(
      builder: (_) => IosAiSettingsPage(
        backLabel: backLabel,
        service: service,
        urlLauncherOverride: urlLauncherOverride,
      ),
    ),
  );
}

/// Presents the Apple-style bottom sheet for entering or replacing a unified
/// three-platform `MMAILAB1.` Ed25519 offline passcode.
/// Returns `true` if a valid passcode was verified and activated.
Future<bool> showIosAiLabPasscodeSheet(
  BuildContext context, {
  AiService? service,
  bool isReplacing = false,
  Future<bool> Function(Uri uri)? urlLauncherOverride,
}) async {
  final effectiveService = service ?? AiService.instance;
  final unlocked = await showIos27LiquidSheet<bool>(
    context: context,
    title: isReplacing ? '更换内测口令' : '开启 AI 观影实验室',
    maxWidth: 480,
    builder: (sheetCtx) => _IosAiLabPasscodeSheetContent(
      service: effectiveService,
      isReplacing: isReplacing,
      urlLauncherOverride: urlLauncherOverride,
    ),
  );
  return unlocked == true;
}

class _IosAiLabPasscodeSheetContent extends StatefulWidget {
  final AiService service;
  final bool isReplacing;
  final Future<bool> Function(Uri uri)? urlLauncherOverride;

  const _IosAiLabPasscodeSheetContent({
    required this.service,
    required this.isReplacing,
    this.urlLauncherOverride,
  });

  @override
  State<_IosAiLabPasscodeSheetContent> createState() =>
      _IosAiLabPasscodeSheetContentState();
}

class _IosAiLabPasscodeSheetContentState
    extends State<_IosAiLabPasscodeSheetContent> {
  final TextEditingController _ctrl = TextEditingController();
  String? _errorMsg;
  String? _channelFeedback;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _handleOpenCommunity() async {
    HapticFeedback.selectionClick();
    final status = await openOfficialChannelUrl(
      OfficialChannelInfo.marcoCommunityChannelUri,
      urlOpener: widget.urlLauncherOverride,
    );
    if (!mounted) return;
    setState(() {
      if (status == OfficialLinkOpenStatus.opened) {
        _channelFeedback =
            '正在前往官方交流频道【${OfficialChannelInfo.marcoCommunityChannelName}】…';
      } else if (status == OfficialLinkOpenStatus.copiedFallback) {
        _channelFeedback =
            '已复制【${OfficialChannelInfo.marcoCommunityChannelName}】链接，请在浏览器打开';
      } else {
        _channelFeedback =
            '请访问：${OfficialChannelInfo.marcoCommunityChannelUrl}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final fieldBg =
        p.isDark ? const Color(0xFF282830) : const Color(0xFFF2F4F8);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        10,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        key: const ValueKey('ios-ai-lab-passcode-sheet'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '「AI 观影实验室」当前处于限量内测阶段，请输入官方签发的 MMAILAB1.… 口令（iOS / Windows / Android 移动端三端通用，纯本机离线 Ed25519 验签）。',
            style: TextStyle(
              color: p.labelSecondary,
              fontSize: 13.2,
              height: 1.48,
            ),
          ),
          const SizedBox(height: 14),
          CupertinoTextField(
            key: const ValueKey('ios-ai-lab-passcode-field'),
            controller: _ctrl,
            placeholder: '粘贴 MMAILAB1.… 口令（支持带说明文字整段粘贴）',
            minLines: 2,
            maxLines: 3,
            autocorrect: false,
            enableSuggestions: false,
            padding: const EdgeInsets.all(12),
            style: TextStyle(color: p.labelPrimary, fontSize: 13.5),
            decoration: BoxDecoration(
              color: fieldBg,
              borderRadius: BorderRadius.circular(12),
            ),
            onChanged: (_) {
              if (_errorMsg != null) {
                setState(() => _errorMsg = null);
              }
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: CupertinoButton(
                    key: const ValueKey('ios-ai-lab-paste-btn'),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    color: p.systemBlue.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(13),
                    onPressed: () async {
                      HapticFeedback.selectionClick();
                      final clip =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (!mounted) return;
                      final raw = (clip?.text ?? '').trim();
                      if (raw.isEmpty) {
                        setState(() {
                          _errorMsg = '剪贴板为空，请先复制 MMAILAB1.… 口令';
                        });
                        return;
                      }
                      final extracted =
                          AiLabPasscodeVerifier.extractToken(raw);
                      setState(() {
                        _ctrl.text = extracted.startsWith('MMAILAB1.')
                            ? extracted
                            : raw;
                        _errorMsg = null;
                      });
                    },
                    child: Text(
                      '粘贴剪贴板口令',
                      style: TextStyle(
                        color: p.systemBlue,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: CupertinoButton(
                    key: const ValueKey('ios-ai-lab-unlock-btn'),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    color: AppleColors.systemBlue,
                    borderRadius: BorderRadius.circular(13),
                    onPressed: () async {
                      HapticFeedback.selectionClick();
                      final res = await widget.service
                          .verifyAndUnlockAiLab(_ctrl.text);
                      if (!mounted) return;
                      if (!res.isValid) {
                        setState(() => _errorMsg = res.messageZh);
                        return;
                      }
                      Navigator.of(context).pop(true);
                    },
                    child: Text(
                      widget.isReplacing ? '验证并更换' : '验证并开启',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_errorMsg != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: AppleColors.systemRed.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                _errorMsg!,
                key: const ValueKey('ios-ai-lab-gate-error'),
                style: const TextStyle(
                  color: AppleColors.systemRed,
                  fontSize: 12.8,
                  height: 1.4,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          CupertinoButton(
            key: const ValueKey('ios-ai-lab-community-btn'),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            minimumSize: const Size(44, 34),
            onPressed: () => unawaited(_handleOpenCommunity()),
            child: Text(
              '前往官方交流频道【${OfficialChannelInfo.marcoCommunityChannelName}】获取内测口令',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.systemBlue,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_channelFeedback != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _channelFeedback!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.labelSecondary,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Native iOS 26/27 inset-grouped settings page supporting BOTH:
/// 1. Bring-Your-Own-API (BYO-API) keys (OpenAI / Responses / Anthropic / Gemini)
/// 2. ChatGPT Plus / Pro / Team Subscription OAuth PKCE sign-in (OpenMinis-style)
/// plus live model catalog discovery, connection testing, monthly token quota,
/// and local response cache management.
class IosAiSettingsPage extends StatefulWidget {
  final String backLabel;
  final AiService? service;
  final VoidCallback? onChanged;
  @visibleForTesting
  final Future<bool> Function(Uri uri)? urlLauncherOverride;

  const IosAiSettingsPage({
    super.key,
    this.backLabel = '设置',
    this.service,
    this.onChanged,
    this.urlLauncherOverride,
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
  final TextEditingController _manualOAuthCtrl = TextEditingController();
  final TextEditingController _labPasscodeCtrl = TextEditingController();

  AiConfig _config = const AiConfig();
  bool _obscureApiKey = true;
  bool _testingConnection = false;
  int _connectionTestGen = 0;
  String _lastConnectionFingerprint = '';
  bool _fetchingModels = false;
  int _modelCatalogGen = 0;
  String _lastModelCatalogFingerprint = '';
  int _lastSeenByoEndpointGen = -1;
  int _lastSeenOAuthSessionGen = -1;
  bool _oauthSigningIn = false;
  bool _showManualOAuthBox = false;
  AiPendingOAuthLogin? _pendingOAuth;
  AiConnectionTestResult? _testResult;
  String? _modelCatalogNotice;
  String? _oauthNotice;
  bool _oauthNoticeIsError = false;
  String? _cacheStatusNotice;
  String? _labGateError;
  bool _hydratingGate = false;
  bool _refreshingQuota = false;
  bool _refreshingApiBalance = false;

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
    _hydratingGate = !_service.isLoaded && !_service.isLabUnlocked;
    _service.addListener(_onServiceChanged);
    unawaited(_loadInitialState());
  }

  Future<void> _loadInitialState() async {
    try {
      await _service.ensureLoaded();
      final key = await _service.readApiKey();
      if (!mounted) return;
      final cfg = _service.config;
      setState(() {
        _hydratingGate = false;
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
        _lastConnectionFingerprint = _currentConnectionFingerprint(cfg);
        _lastModelCatalogFingerprint = _currentModelCatalogFingerprint(cfg);
        _lastSeenByoEndpointGen = _service.byoEndpointGen;
        _lastSeenOAuthSessionGen = _service.oauthSessionGen;
      });
      if (!_service.isPrivacySessionActive &&
          _service.isLabUnlocked &&
          _service.isExperimentalOAuthAllowed &&
          _service.hasOAuthSession) {
        unawaited(_refreshQuotaSilently());
      }
      if (!_service.isPrivacySessionActive &&
          _service.isLabUnlocked &&
          cfg.authMode == AiAuthMode.apiKey &&
          cfg.baseUrl.trim().isNotEmpty &&
          key.trim().isNotEmpty) {
        unawaited(_refreshApiBalanceSilently());
      }
    } finally {
      if (mounted && _hydratingGate) {
        setState(() => _hydratingGate = false);
      }
    }
  }

  Future<void> _refreshQuotaSilently() async {
    if (_refreshingQuota) return;
    if (mounted) setState(() => _refreshingQuota = true);
    try {
      await _service.refreshSubscriptionQuota();
    } finally {
      if (mounted) setState(() => _refreshingQuota = false);
    }
  }

  Future<void> _refreshApiBalanceSilently({bool force = false}) async {
    if (_refreshingApiBalance) return;
    if (mounted) setState(() => _refreshingApiBalance = true);
    try {
      await _service.refreshApiBalance(
        configOverride: _draftConfigFromControllers(),
        apiKeyOverride: _apiKeyCtrl.text.trim(),
        force: force,
      );
    } finally {
      if (mounted) setState(() => _refreshingApiBalance = false);
    }
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final cfg = _service.config;
    final endpointChanged = _lastSeenByoEndpointGen >= 0 &&
        _service.byoEndpointGen != _lastSeenByoEndpointGen;
    final oauthChanged = _lastSeenOAuthSessionGen >= 0 &&
        _service.oauthSessionGen != _lastSeenOAuthSessionGen;
    final nextConnFp = _currentConnectionFingerprint(cfg);
    final nextCatalogFp = _currentModelCatalogFingerprint(cfg);
    final catalogFpChanged = _lastModelCatalogFingerprint.isNotEmpty &&
        nextCatalogFp != _lastModelCatalogFingerprint;
    final connFpChanged = _lastConnectionFingerprint.isNotEmpty &&
        nextConnFp != _lastConnectionFingerprint;
    _lastSeenByoEndpointGen = _service.byoEndpointGen;
    _lastSeenOAuthSessionGen = _service.oauthSessionGen;
    if (endpointChanged || oauthChanged || catalogFpChanged) {
      _modelCatalogGen++;
      _fetchingModels = false;
      _modelCatalogNotice = null;
    }
    if (endpointChanged || oauthChanged || connFpChanged) {
      _connectionTestGen++;
      _testingConnection = false;
      _testResult = null;
    }
    setState(() {
      if (_service.isLoaded && _hydratingGate) {
        _hydratingGate = false;
      }
      final modelHealed =
          _config.model != cfg.model ||
              (_modelCtrl.text.trim() == _config.model &&
                  cfg.model.trim().isNotEmpty);
      final fastHealed =
          _config.fastModel != cfg.fastModel &&
              _fastModelCtrl.text.trim() == _config.fastModel;
      _config = cfg;
      if ((_modelCtrl.text.trim().isEmpty && cfg.model.isNotEmpty) ||
          (modelHealed && _modelCtrl.text.trim() != cfg.model)) {
        _modelCtrl.text = cfg.model;
      }
      if (fastHealed && _fastModelCtrl.text.trim() != cfg.fastModel) {
        _fastModelCtrl.text = cfg.fastModel;
      }
      _lastConnectionFingerprint = nextConnFp;
      _lastModelCatalogFingerprint = nextCatalogFp;
    });
  }

  @override
  void dispose() {
    final pending = _pendingOAuth;
    _pendingOAuth = null;
    if (pending != null) {
      unawaited(pending.cancel());
    }
    _service.removeListener(_onServiceChanged);
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _fastModelCtrl.dispose();
    _budgetCtrl.dispose();
    _manualOAuthCtrl.dispose();
    _labPasscodeCtrl.dispose();
    super.dispose();
  }

  AiConfig _draftConfigFromControllers([AiConfig? base]) {
    final seed = base ?? _config;
    final rawBudget = _budgetCtrl.text.trim();
    final parsedBudget = rawBudget.isEmpty
        ? 0
        : (int.tryParse(rawBudget) ?? seed.monthlyTokenBudget);
    return seed.copyWith(
      baseUrl: _baseUrlCtrl.text.trim(),
      model: _modelCtrl.text.trim(),
      fastModel: _fastModelCtrl.text.trim(),
      monthlyTokenBudget: parsedBudget < 0 ? 0 : parsedBudget,
    );
  }

  String _currentConnectionFingerprint([AiConfig? cfgOverride]) {
    final cfg = cfgOverride ?? _draftConfigFromControllers();
    final oauthAcct = cfg.authMode == AiAuthMode.codexOAuth
        ? AiService.oauthAccountKey(_service.oauthSession)
        : '';
    return '${cfg.authMode.id}|${cfg.protocol.id}|${cfg.baseUrl.trim()}|${cfg.model.trim()}|${_apiKeyCtrl.text.trim()}|$oauthAcct';
  }

  String _currentModelCatalogFingerprint([AiConfig? cfgOverride]) {
    final cfg = cfgOverride ?? _draftConfigFromControllers();
    final oauthAcct = cfg.authMode == AiAuthMode.codexOAuth
        ? AiService.oauthAccountKey(_service.oauthSession)
        : '';
    return '${cfg.authMode.id}|${cfg.protocol.id}|${cfg.baseUrl.trim()}|${_apiKeyCtrl.text.trim()}|${cfg.activeProfileId.trim()}|$oauthAcct';
  }

  void _invalidateConnectionTestIfChanged([AiConfig? nextConfig]) {
    final fp = _currentConnectionFingerprint(nextConfig);
    if (fp != _lastConnectionFingerprint) {
      _lastConnectionFingerprint = fp;
      _connectionTestGen++;
      _testingConnection = false;
      _testResult = null;
    }
  }

  void _invalidateModelCatalogIfChanged([AiConfig? nextConfig]) {
    final fp = _currentModelCatalogFingerprint(nextConfig);
    if (fp != _lastModelCatalogFingerprint) {
      _lastModelCatalogFingerprint = fp;
      _modelCatalogGen++;
      _fetchingModels = false;
      _modelCatalogNotice = null;
    }
  }

  Future<void> _persistDraft({AiConfig? overrideConfig}) async {
    final next = overrideConfig ?? _draftConfigFromControllers();
    _invalidateConnectionTestIfChanged(next);
    _invalidateModelCatalogIfChanged(next);
    _config = next;
    await _service.saveConfig(next);
    if (next.authMode == AiAuthMode.apiKey) {
      await _service.setApiKey(_apiKeyCtrl.text);
    }
    _lastSeenByoEndpointGen = _service.byoEndpointGen;
    _lastSeenOAuthSessionGen = _service.oauthSessionGen;
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _switchAuthMode(AiAuthMode mode) async {
    if (mode == AiAuthMode.codexOAuth &&
        !_service.isExperimentalOAuthAllowed) {
      HapticFeedback.heavyImpact();
      setState(() {
        _oauthNotice =
            '当前内测口令未包含实验性 OpenAI OAuth 权限，请使用个人 API 密钥或点击上方「更换口令」';
        _oauthNoticeIsError = true;
      });
      return;
    }
    if (_config.authMode == mode) return;
    HapticFeedback.selectionClick();
    var nextModel = _modelCtrl.text.trim();
    if (mode == AiAuthMode.codexOAuth && nextModel.isEmpty) {
      nextModel = AiService.fallbackCodexModels.first.id;
      _modelCtrl.text = nextModel;
    }
    final next = _draftConfigFromControllers().copyWith(
      authMode: mode,
      model: nextModel,
    );
    _connectionTestGen++;
    _modelCatalogGen++;
    _lastConnectionFingerprint = _currentConnectionFingerprint(next);
    _lastModelCatalogFingerprint = _currentModelCatalogFingerprint(next);
    setState(() {
      _testingConnection = false;
      _fetchingModels = false;
      _testResult = null;
      _modelCatalogNotice = null;
      _oauthNotice = null;
    });
    await _persistDraft(overrideConfig: next);
  }

  Future<void> _handleStartOAuthLogin() async {
    if (_oauthSigningIn) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _oauthSigningIn = true;
      _oauthNotice = null;
      _oauthNoticeIsError = false;
      _testResult = null;
    });

    final prevPending = _pendingOAuth;
    if (prevPending != null) {
      await prevPending.cancel();
    }

    try {
      final pending = await _service.startInteractiveCodexLogin();
      _pendingOAuth = pending;
      if (mounted) {
        setState(() {
          _showManualOAuthBox = true;
        });
      }

      var opened = false;
      if (widget.urlLauncherOverride != null) {
        opened = await widget.urlLauncherOverride!(pending.request.authorizeUri);
      } else {
        opened = await IosLiquidGlassBridge.presentSafariAuth(
          pending.request.authorizeUri.toString(),
        );
        if (!opened) {
          opened = await launchUrl(
            pending.request.authorizeUri,
            mode: LaunchMode.externalApplication,
          );
        }
      }

      if (!opened && mounted) {
        await Clipboard.setData(
          ClipboardData(text: pending.request.authorizeUri.toString()),
        );
        setState(() {
          _oauthNotice = '无法自动唤起浏览器，已将登录授权链接复制到剪贴板，请在浏览器打开完成授权。';
          _oauthNoticeIsError = false;
        });
      }

      final session = await pending.future;
      await IosLiquidGlassBridge.dismissSafariAuth();
      if (!mounted) return;
      _pendingOAuth = null;
      _modelCtrl.text = _service.config.model;
      setState(() {
        _config = _service.config;
        _oauthSigningIn = false;
        _showManualOAuthBox = false;
        _manualOAuthCtrl.clear();
        _oauthNotice =
            '已成功登录 ${session.planBadgeLabel}（${session.maskedIdentity}），已自动匹配可用模型';
        _oauthNoticeIsError = false;
      });
      widget.onChanged?.call();
    } on AiServiceException catch (e) {
      await IosLiquidGlassBridge.dismissSafariAuth();
      if (!mounted) return;
      setState(() {
        _oauthSigningIn = false;
        _oauthNotice = e.messageZh;
        _oauthNoticeIsError = true;
      });
    } catch (_) {
      await IosLiquidGlassBridge.dismissSafariAuth();
      if (!mounted) return;
      setState(() {
        _oauthSigningIn = false;
        _oauthNotice = '订阅账号登录未完成，可重试或使用下方回调链接导入';
        _oauthNoticeIsError = true;
      });
    }
  }

  Future<void> _handleCompleteManualOAuth() async {
    final raw = _manualOAuthCtrl.text.trim();
    if (raw.isEmpty) {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final clipText = (clip?.text ?? '').trim();
      if (clipText.isNotEmpty) {
        _manualOAuthCtrl.text = clipText;
      }
    }
    FocusScope.of(context).unfocus();
    try {
      final session = await _service.completeManualOAuthInput(
        _manualOAuthCtrl.text,
        pendingRequest: _pendingOAuth?.request,
      );
      final pending = _pendingOAuth;
      _pendingOAuth = null;
      if (pending != null) {
        unawaited(pending.cancel());
      }
      await IosLiquidGlassBridge.dismissSafariAuth();
      if (!mounted) return;
      _modelCtrl.text = _service.config.model;
      setState(() {
        _config = _service.config;
        _oauthSigningIn = false;
        _showManualOAuthBox = false;
        _manualOAuthCtrl.clear();
        _oauthNotice =
            '授权导入成功：${session.planBadgeLabel}（${session.maskedIdentity}）';
        _oauthNoticeIsError = false;
      });
      widget.onChanged?.call();
    } on AiServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _oauthNotice = e.messageZh;
        _oauthNoticeIsError = true;
      });
    }
  }

  Future<void> _handleSignOutOAuth() async {
    HapticFeedback.mediumImpact();
    _modelCatalogGen++;
    _connectionTestGen++;
    setState(() {
      _fetchingModels = false;
      _modelCatalogNotice = null;
      _testingConnection = false;
      _testResult = null;
    });
    await _service.signOutOAuth();
    if (!mounted) return;
    _lastSeenOAuthSessionGen = _service.oauthSessionGen;
    _lastModelCatalogFingerprint = _currentModelCatalogFingerprint();
    _lastConnectionFingerprint = _currentConnectionFingerprint();
    setState(() {
      _fetchingModels = false;
      _modelCatalogNotice = null;
      _oauthNotice = '已退出订阅账号并清除钥匙串令牌';
      _oauthNoticeIsError = false;
      _testResult = null;
    });
    widget.onChanged?.call();
  }

  Future<void> _handleFetchAndPickModel({required bool forFastModel}) async {
    if (_fetchingModels) return;
    FocusScope.of(context).unfocus();
    await _persistDraft();
    if (!mounted) return;

    final initiatingCfg = _draftConfigFromControllers();
    final initiatingKey = _apiKeyCtrl.text.trim();
    final initiatingFp = _currentModelCatalogFingerprint(initiatingCfg);
    final initiatingEndpointGen = _service.byoEndpointGen;
    final initiatingOAuthGen = _service.oauthSessionGen;
    final fetchGen = ++_modelCatalogGen;
    _lastModelCatalogFingerprint = initiatingFp;
    _lastSeenByoEndpointGen = initiatingEndpointGen;
    _lastSeenOAuthSessionGen = initiatingOAuthGen;

    bool isCatalogStillValid() =>
        mounted &&
        fetchGen == _modelCatalogGen &&
        _currentModelCatalogFingerprint() == initiatingFp &&
        _service.byoEndpointGen == initiatingEndpointGen &&
        _service.oauthSessionGen == initiatingOAuthGen;

    setState(() {
      _fetchingModels = true;
      _modelCatalogNotice = null;
    });

    List<AiModelOption> models = const <AiModelOption>[];
    var usedOfflineFallback = false;
    String? fallbackNotice;
    try {
      models = await _service.fetchAvailableModelOptions(
        configOverride: initiatingCfg,
        apiKeyOverride: initiatingKey,
      );
    } on AiServiceException catch (e) {
      if (!isCatalogStillValid()) return;
      if (initiatingCfg.authMode == AiAuthMode.codexOAuth &&
          _service.hasOAuthSession &&
          _service.isExperimentalOAuthAllowed &&
          !_service.isPrivacySessionActive &&
          (e.code == AiErrorCode.networkError || e.code == AiErrorCode.timeout)) {
        models = List<AiModelOption>.unmodifiable([
          for (final fb in AiService.fallbackCodexModels)
            fb.copyWithPriority(fb.priority, isLocalFallback: true),
        ]);
        usedOfflineFallback = true;
        fallbackNotice = '当前离线或接口不可达，以下为内置目录（待验证）';
      } else {
        setState(() {
          _fetchingModels = false;
          _modelCatalogNotice = e.messageZh;
        });
        return;
      }
    } catch (_) {
      if (!isCatalogStillValid()) return;
      if (initiatingCfg.authMode == AiAuthMode.codexOAuth &&
          _service.hasOAuthSession &&
          _service.isExperimentalOAuthAllowed &&
          !_service.isPrivacySessionActive) {
        models = List<AiModelOption>.unmodifiable([
          for (final fb in AiService.fallbackCodexModels)
            fb.copyWithPriority(fb.priority, isLocalFallback: true),
        ]);
        usedOfflineFallback = true;
        fallbackNotice = '当前离线或接口不可达，以下为内置目录（待验证）';
      } else {
        setState(() {
          _fetchingModels = false;
          _modelCatalogNotice = '拉取模型列表失败，请检查网络或配置';
        });
        return;
      }
    }

    if (!isCatalogStillValid()) return;
    final svcCfg = _service.config;
    if (svcCfg.authMode == AiAuthMode.codexOAuth) {
      if (AiService.isDisallowedCodexModelSlug(_modelCtrl.text) &&
          svcCfg.model.isNotEmpty) {
        _modelCtrl.text = svcCfg.model;
      }
      if (AiService.isDisallowedCodexModelSlug(_fastModelCtrl.text)) {
        _fastModelCtrl.text = svcCfg.fastModel;
      }
    }
    final liveCount = models.where((m) => !m.isLocalFallback).length;
    setState(() {
      _fetchingModels = false;
      if (usedOfflineFallback || liveCount == 0) {
        _modelCatalogNotice =
            fallbackNotice ?? '在线列表暂不可达，以下为内置目录（待验证）';
      } else {
        final fallbackCount = models.length - liveCount;
        _modelCatalogNotice = fallbackCount > 0
            ? '已获取 $liveCount 个在线模型（另含 $fallbackCount 个内置待验证）'
            : '已获取 $liveCount 个可用模型';
      }
    });

    if (models.isEmpty) return;
    final picked = await _showModelPickerModal(
      context: context,
      models: models,
      currentId:
          forFastModel ? _fastModelCtrl.text.trim() : _modelCtrl.text.trim(),
      title: forFastModel ? '选择轻量清洗模型' : '选择主模型',
      allowClear: forFastModel,
    );
    if (!isCatalogStillValid() || picked == null) return;
    if (forFastModel) {
      _fastModelCtrl.text = picked;
    } else {
      _modelCtrl.text = picked;
    }
    await _persistDraft();
  }

  Future<String?> _showModelPickerModal({
    required BuildContext context,
    required List<AiModelOption> models,
    required String currentId,
    required String title,
    required bool allowClear,
  }) {
    final searchCtrl = TextEditingController();
    return showCupertinoModalPopup<String>(
      context: context,
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final p = ApplePalette.of(ctx);
            final q = searchCtrl.text.trim().toLowerCase();
            final filtered = q.isEmpty
                ? models
                : models
                    .where(
                      (m) =>
                          m.id.toLowerCase().contains(q) ||
                          m.displayName.toLowerCase().contains(q) ||
                          m.description.toLowerCase().contains(q),
                    )
                    .toList(growable: false);
            return Material(
              type: MaterialType.transparency,
              child: Container(
                key: const ValueKey('ios-ai-model-picker-sheet'),
                height: MediaQuery.sizeOf(ctx).height * 0.68,
                decoration: BoxDecoration(
                  color: p.isDark
                      ? const Color(0xFF1C1C20)
                      : const Color(0xFFF6F7FB),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(26)),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 38,
                        height: 4.5,
                        decoration: BoxDecoration(
                          color: p.labelTertiary.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 12, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: TextStyle(
                                  color: p.labelPrimary,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (allowClear)
                              CupertinoButton(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                minimumSize: const Size(0, 0),
                                onPressed: () => Navigator.of(ctx).pop(''),
                                child: Text(
                                  '跟随主模型',
                                  style: TextStyle(
                                    color: p.systemBlue,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            CupertinoButton(
                              padding: const EdgeInsets.all(6),
                              minimumSize: const Size(32, 32),
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: Icon(
                                CupertinoIcons.xmark_circle_fill,
                                color: p.labelTertiary,
                                size: 22,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: CupertinoSearchTextField(
                          controller: searchCtrl,
                          placeholder: '搜索模型 ID 或名称',
                          onChanged: (_) => setModalState(() {}),
                        ),
                      ),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                  '无匹配的模型',
                                  style: TextStyle(
                                    color: p.labelSecondary,
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 2, 16, 20),
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) => Container(
                                  height: 0.5,
                                  color: p.isDark
                                      ? const Color(0x18FFFFFF)
                                      : const Color(0x12000000),
                                ),
                                itemBuilder: (_, idx) {
                                  final item = filtered[idx];
                                  final selected = item.id.toLowerCase() ==
                                      currentId.toLowerCase();
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      Navigator.of(ctx).pop(item.id);
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 11,
                                        horizontal: 4,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Flexible(
                                                      child: Text(
                                                        item.hasDistinctDisplayName
                                                            ? '${item.displayName} (${item.id})'
                                                            : item.id,
                                                        style: TextStyle(
                                                          color: p.labelPrimary,
                                                          fontSize: 15,
                                                          fontWeight: selected
                                                              ? FontWeight.w700
                                                              : FontWeight.w500,
                                                        ),
                                                      ),
                                                    ),
                                                    if (item.isLocalFallback) ...[
                                                      const SizedBox(width: 6),
                                                      Container(
                                                        key: ValueKey(
                                                          'model-fallback-badge-${item.id}',
                                                        ),
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 2,
                                                        ),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: p.labelTertiary
                                                              .withValues(
                                                            alpha: 0.16,
                                                          ),
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                            6,
                                                          ),
                                                        ),
                                                        child: Text(
                                                          '待验证',
                                                          style: TextStyle(
                                                            color:
                                                                p.labelSecondary,
                                                            fontSize: 10.5,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                                if (item.description.isNotEmpty)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                      top: 3,
                                                    ),
                                                    child: Text(
                                                      item.description,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: p.labelSecondary,
                                                        fontSize: 12.5,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          if (selected)
                                            Icon(
                                              CupertinoIcons.checkmark_alt,
                                              color: p.systemBlue,
                                              size: 19,
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(searchCtrl.dispose);
  }

  Future<void> _handleTestConnection() async {
    if (_testingConnection) return;
    FocusScope.of(context).unfocus();
    final targetConfig = _draftConfigFromControllers();
    final targetKey = _apiKeyCtrl.text.trim();
    final startFp = _currentConnectionFingerprint(targetConfig);
    _lastConnectionFingerprint = startFp;
    final testGen = ++_connectionTestGen;
    setState(() {
      _testingConnection = true;
      _testResult = null;
      _cacheStatusNotice = null;
    });
    await _persistDraft(overrideConfig: targetConfig);
    if (!mounted ||
        testGen != _connectionTestGen ||
        startFp != _currentConnectionFingerprint()) {
      return;
    }
    final result = await _service.testConnection(
      configOverride: targetConfig,
      apiKeyOverride: targetKey,
    );
    if (!mounted ||
        testGen != _connectionTestGen ||
        startFp != _currentConnectionFingerprint() ||
        result.stale) {
      return;
    }
    setState(() {
      _testingConnection = false;
      _testResult = result;
    });
    if (result.ok && targetConfig.authMode == AiAuthMode.apiKey) {
      unawaited(_refreshApiBalanceSilently(force: true));
    }
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
    Widget? headerAction,
    List<TextInputFormatter>? inputFormatters,
    required ValueChanged<String> onChanged,
  }) {
    final p = ApplePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: p.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              if (headerAction != null) headerAction,
            ],
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
                  '订阅直连 & 自带密钥（BYO-API）双模式隐私保护',
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '• 支持登录 GPT 订阅账号（Plus / Pro / Team OAuth 直连）或配置个人 API 密钥；所有令牌与密钥仅保存在本机 iOS 钥匙串（Keychain），零第三方中转。\n'
                  '• 仅发送找片描述或待清洗文件名，模型只返回片名等结构化元数据，绝不生成或上传播放链接。\n'
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

  Widget _buildAuthModeSelector(BuildContext context) {
    final p = ApplePalette.of(context);
    final allowOAuth = _service.isExperimentalOAuthAllowed;
    final effectiveMode = allowOAuth ? _config.authMode : AiAuthMode.apiKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            '连接方式',
            style: TextStyle(
              color: p.labelSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        CupertinoSlidingSegmentedControl<AiAuthMode>(
          key: const ValueKey('ios-ai-auth-mode-segment'),
          groupValue: effectiveMode,
          backgroundColor: p.isDark
              ? const Color(0xFF1C1C22)
              : const Color(0xFFE5E7EF),
          thumbColor: p.isDark ? const Color(0xFF343540) : Colors.white,
          children: <AiAuthMode, Widget>{
            AiAuthMode.apiKey: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Text(
                '个人 API 密钥',
                style: TextStyle(
                  color: p.labelPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AiAuthMode.codexOAuth: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Text(
                allowOAuth ? 'GPT 订阅账号登录' : 'GPT 订阅账号（实验性）',
                style: TextStyle(
                  color: allowOAuth ? p.labelPrimary : p.labelSecondary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          },
          onValueChanged: (mode) {
            if (mode != null) unawaited(_switchAuthMode(mode));
          },
        ),
        if (!allowOAuth && _oauthNotice != null && _oauthNoticeIsError) ...[
          const SizedBox(height: 10),
          _buildNoticeBanner(
            context,
            key: const ValueKey('ios-ai-oauth-gate-notice'),
            ok: false,
            text: _oauthNotice!,
          ),
        ],
      ],
    );
  }

  Widget _buildFetchModelsChip(BuildContext context, {required bool forFast}) {
    final p = ApplePalette.of(context);
    return GestureDetector(
      key: ValueKey(
        forFast ? 'ios-ai-fetch-fast-models-btn' : 'ios-ai-fetch-models-btn',
      ),
      behavior: HitTestBehavior.opaque,
      onTap: _fetchingModels
          ? null
          : () => unawaited(_handleFetchAndPickModel(forFastModel: forFast)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: p.systemBlue.withValues(alpha: p.isDark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_fetchingModels)
              const Padding(
                padding: EdgeInsets.only(right: 5),
                child: CupertinoActivityIndicator(radius: 6.5),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  CupertinoIcons.list_bullet_indent,
                  size: 13,
                  color: p.systemBlue,
                ),
              ),
            Text(
              forFast ? '选择模型' : '拉取模型列表',
              style: TextStyle(
                color: p.systemBlue,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCodexOAuthSection(BuildContext context) {
    final p = ApplePalette.of(context);
    final session = _service.oauthSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IosSettingsGroup(
          header: 'GPT 订阅账号授权（PKCE 直连）',
          footer:
              '直接使用您的 ChatGPT Plus / Pro / Team 订阅额度调用模型，无需额外充值按量 API。授权令牌仅保存在本机钥匙串并支持自动续期。',
          dividerIndent: 16,
          children: [
            if (session != null && session.isValid) ...[
              IosSettingsRow(
                key: const ValueKey('ios-ai-oauth-account-row'),
                icon: CupertinoIcons.person_crop_circle_badge_checkmark,
                iconColor: AppleColors.systemGreen,
                title: session.planBadgeLabel,
                subtitle: '${session.maskedIdentity} · 支持自动刷新令牌',
                trailingText: '已连接',
              ),
              IosSettingsRow(
                key: const ValueKey('ios-ai-oauth-signout-btn'),
                icon: CupertinoIcons.square_arrow_right,
                iconColor: AppleColors.systemRed,
                title: '退出订阅账号',
                titleColor: AppleColors.systemRed,
                onTap: _handleSignOutOAuth,
              ),
            ] else ...[
              IosSettingsRow(
                key: const ValueKey('ios-ai-oauth-login-btn'),
                icon: CupertinoIcons.person_badge_plus_fill,
                iconColor: AppleColors.systemBlue,
                title: _oauthSigningIn
                    ? '正在等待浏览器完成授权…'
                    : '浏览器登录 ChatGPT 订阅账号',
                subtitle: '支持 Apple / Google 快捷登录与通行密钥（Passkey）',
                titleColor: p.systemBlue,
                trailing: _oauthSigningIn
                    ? const CupertinoActivityIndicator(radius: 9)
                    : null,
                onTap: _oauthSigningIn ? null : _handleStartOAuthLogin,
              ),
              IosSettingsRow(
                key: const ValueKey('ios-ai-oauth-manual-toggle'),
                icon: CupertinoIcons.link,
                iconColor: AppleColors.systemIndigo,
                title: _showManualOAuthBox ? '收起手动回调导入' : '粘贴回调链接或 Token 导入',
                subtitle: '若代理软件拦截了 localhost 回调，可手动粘贴完成绑定',
                onTap: () {
                  setState(() => _showManualOAuthBox = !_showManualOAuthBox);
                },
              ),
              if (_showManualOAuthBox)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CupertinoTextField(
                        key: const ValueKey('ios-ai-oauth-manual-field'),
                        controller: _manualOAuthCtrl,
                        placeholder:
                            '粘贴 http://localhost:1455/auth/callback?code=... 或 auth.json',
                        minLines: 2,
                        maxLines: 3,
                        autocorrect: false,
                        padding: const EdgeInsets.all(10),
                        style: TextStyle(color: p.labelPrimary, fontSize: 13.5),
                        decoration: BoxDecoration(
                          color: p.isDark
                              ? const Color(0xFF28282E)
                              : const Color(0xFFF1F3F8),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: CupertinoButton.filled(
                              key: const ValueKey('ios-ai-oauth-manual-submit'),
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              minimumSize: const Size(0, 38),
                              onPressed: _handleCompleteManualOAuth,
                              child: const Text(
                                '读取并验证授权',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          if (_oauthSigningIn) ...[
                            const SizedBox(width: 10),
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              minimumSize: const Size(0, 38),
                              onPressed: () async {
                                final pending = _pendingOAuth;
                                _pendingOAuth = null;
                                if (pending != null) await pending.cancel();
                                if (mounted) {
                                  setState(() => _oauthSigningIn = false);
                                }
                              },
                              child: Text(
                                '取消等待',
                                style: TextStyle(
                                  color: p.labelSecondary,
                                  fontSize: 13.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
        if (_oauthNotice != null) ...[
          const SizedBox(height: 10),
          _buildNoticeBanner(
            context,
            key: const ValueKey('ios-ai-oauth-notice-banner'),
            ok: !_oauthNoticeIsError,
            text: _oauthNotice!,
          ),
        ],
        const SizedBox(height: 18),
        IosSettingsGroup(
          header: '订阅模型与连接验证',
          footer: _modelCatalogNotice ??
              '点击「拉取模型列表」直接选取当前订阅支持的真实模型 ID（如 gpt-5.4 等），避免手动输入显示名称报错。',
          dividerIndent: 16,
          children: [
            _buildLabeledTextField(
              context: context,
              fieldKey: const ValueKey('ios-ai-model-field'),
              label: '主模型 ID',
              controller: _modelCtrl,
              placeholder: 'gpt-5.4',
              headerAction: _buildFetchModelsChip(context, forFast: false),
              onChanged: (_) => unawaited(_persistDraft()),
            ),
            _buildLabeledTextField(
              context: context,
              fieldKey: const ValueKey('ios-ai-fast-model-field'),
              label: '轻量清洗模型（可选）',
              controller: _fastModelCtrl,
              placeholder: '留空则默认使用主模型',
              headerAction: _buildFetchModelsChip(context, forFast: true),
              onChanged: (_) => unawaited(_persistDraft()),
            ),
            IosSettingsRow(
              key: const ValueKey('ios-ai-test-btn'),
              icon: CupertinoIcons.bolt_horizontal_circle_fill,
              iconColor: AppleColors.systemBlue,
              title: _testingConnection ? '正在测试连接…' : '测试连接',
              titleColor: p.systemBlue,
              trailingText: _testResult == null
                  ? null
                  : (_testResult!.ok ? '${_testResult!.latencyMs} ms' : '未通过'),
              onTap: _testingConnection ? null : _handleTestConnection,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildApiKeySection(BuildContext context) {
    final p = ApplePalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsChoices<AiApiProtocol>(
          title: '接口协议',
          footer:
              '支持标准 OpenAI 兼容（含 Chat Completions 与 Responses 及推理模型自适应）、Anthropic Messages 与 Google Gemini 协议。',
          value: _config.protocol,
          choices: const <(AiApiProtocol, String)>[
            (AiApiProtocol.openaiCompatible, 'OpenAI 兼容接口'),
            (AiApiProtocol.anthropicMessages, 'Anthropic Messages'),
            (AiApiProtocol.geminiGenerateContent, 'Google Gemini'),
          ],
          onSelected: (protocol) async {
            final next =
                _draftConfigFromControllers().copyWith(protocol: protocol);
            await _persistDraft(overrideConfig: next);
          },
        ),
        IosSettingsGroup(
          header: '接口地址、密钥与模型',
          footer: _modelCatalogNotice ??
              '填写接口地址与密钥后，建议点击「拉取模型列表」直接选择服务端支持的真实模型 ID（轻量清洗模型留空时默认复用主模型）。',
          dividerIndent: 16,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final preset in AiService.quickApiPresets)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        _baseUrlCtrl.text = preset.baseUrl;
                        final next = _draftConfigFromControllers().copyWith(
                          protocol: preset.protocol,
                          baseUrl: preset.baseUrl,
                        );
                        unawaited(_persistDraft(overrideConfig: next));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4.5,
                        ),
                        decoration: BoxDecoration(
                          color: _baseUrlCtrl.text.trim() == preset.baseUrl
                              ? p.systemBlue
                              : (p.isDark
                                  ? const Color(0xFF2C2C34)
                                  : const Color(0xFFEAECEF)),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          preset.label,
                          style: TextStyle(
                            color: _baseUrlCtrl.text.trim() == preset.baseUrl
                                ? Colors.white
                                : p.labelPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
                setState(() {
                  _invalidateConnectionTestIfChanged();
                  _invalidateModelCatalogIfChanged();
                });
                unawaited(_service.setApiKey(v));
              },
            ),
            _buildLabeledTextField(
              context: context,
              fieldKey: const ValueKey('ios-ai-model-field'),
              label: '主模型名称',
              controller: _modelCtrl,
              placeholder: '点击右上角拉取或输入模型 ID',
              headerAction: _buildFetchModelsChip(context, forFast: false),
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
              headerAction: _buildFetchModelsChip(context, forFast: true),
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
      ],
    );
  }

  Widget _buildNoticeBanner(
    BuildContext context, {
    required Key key,
    required bool ok,
    required String text,
  }) {
    final p = ApplePalette.of(context);
    final accent = ok ? AppleColors.systemGreen : AppleColors.systemOrange;
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: p.isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: accent.withValues(alpha: 0.40),
          width: 0.7,
        ),
      ),
      child: Row(
        children: [
          Icon(
            ok
                ? CupertinoIcons.checkmark_seal_fill
                : CupertinoIcons.exclamationmark_triangle_fill,
            size: 18,
            color: accent,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: p.labelPrimary,
                fontSize: 13.5,
                height: 1.38,
              ),
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
      title: 'AI 观影实验室',
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
              child: _hydratingGate && !_service.isLabUnlocked
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: CupertinoActivityIndicator()),
                    )
                  : !_service.isLabUnlocked
                      ? _buildLabPasscodeGateView(context)
                      : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildLabUnlockedHeaderBanner(context),
                        const SizedBox(height: 14),
                        _buildPrivacyBanner(context),
                        const SizedBox(height: 18),
                        IosSettingsGroup(
                          footer: '默认关闭；可配置个人 API 密钥（或凭专属口令开启 GPT 订阅账号登录）后启用。',
                          children: [
                            _buildSwitchCell(
                              rowKey: const ValueKey('ios-ai-enable-switch'),
                              icon: CupertinoIcons.sparkles,
                              iconColor: AppleColors.systemIndigo,
                              title: '启用 AI 观影实验室',
                              subtitle: _service.isConfigured
                                  ? '已就绪 · ${_service.statusSummaryZh}'
                                  : (_config.authMode == AiAuthMode.codexOAuth &&
                                          _service.isExperimentalOAuthAllowed
                                      ? '需登录 GPT 订阅账号并选择模型'
                                      : '需填写接口地址、API 密钥与主模型名称'),
                              value: _config.enabled,
                              onChanged: (val) {
                                final next = _draftConfigFromControllers()
                                    .copyWith(enabled: val);
                                unawaited(_persistDraft(overrideConfig: next));
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _buildAuthModeSelector(context),
                        const SizedBox(height: 18),
                        if (_config.authMode == AiAuthMode.codexOAuth &&
                            _service.isExperimentalOAuthAllowed)
                          _buildCodexOAuthSection(context)
                        else
                          _buildApiKeySection(context),
                        if (_testResult != null) ...[
                          const SizedBox(height: 10),
                          _buildNoticeBanner(
                            context,
                            key: const ValueKey('ios-ai-test-result-banner'),
                            ok: _testResult!.ok,
                            text: _testResult!.messageZh,
                          ),
                        ],
                        const SizedBox(height: 20),
                        IosSettingsGroup(
                          header: '核心观影实验场景与基础增强',
                          footer:
                              '所有 AI 能力聚焦双语字幕、零剧透看点科普、片尾彩蛋提示、自有源选片与故障排障，不编造未核实台词且绝不上传播放链接；开启隐私空间期间全局硬性阻断。',
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
                              subtitle: '浏览网盘/WebDAV/SMB 时自动提炼标准片名与季集号',
                              value: _config.titleCleanupEnabled,
                              onChanged: (val) {
                                final next = _draftConfigFromControllers()
                                    .copyWith(titleCleanupEnabled: val);
                                unawaited(_persistDraft(overrideConfig: next));
                              },
                            ),
                            _buildSwitchCell(
                              rowKey:
                                  const ValueKey('ios-ai-subtranslate-switch'),
                              icon: CupertinoIcons.captions_bubble_fill,
                              iconColor: AppleColors.systemBlue,
                              title: '播放器 AI 实时双语字幕与外挂精译',
                              subtitle: '支持内封字幕实时双语直显、外挂字幕术语锁定与时间轴微调',
                              value: _config.subtitleTranslateEnabled,
                              onChanged: (val) {
                                final next = _draftConfigFromControllers()
                                    .copyWith(subtitleTranslateEnabled: val);
                                unawaited(_persistDraft(overrideConfig: next));
                              },
                            ),
                            _buildSwitchCell(
                              rowKey:
                                  const ValueKey('ios-ai-watchbrief-switch'),
                              icon: CupertinoIcons.film_fill,
                              iconColor: AppleColors.systemIndigo,
                              title: '零剧透看点、设定背景与片尾彩蛋',
                              subtitle: '客观梳理创作背景、片尾彩蛋提示与自由观影问答，不泄底',
                              value: _config.spoilerFreeRecapEnabled,
                              onChanged: (val) {
                                final next = _draftConfigFromControllers()
                                    .copyWith(spoilerFreeRecapEnabled: val);
                                unawaited(_persistDraft(overrideConfig: next));
                              },
                            ),
                            _buildSwitchCell(
                              rowKey: const ValueKey('ios-ai-mood-switch'),
                              icon: CupertinoIcons.sparkles,
                              iconColor: AppleColors.systemPink,
                              title: '观影口味画像与「今晚看什么」',
                              subtitle: '根据本地收藏与当前心情策展自有片单（播放页支持同好接力）',
                              value: _config.moodCurationEnabled,
                              onChanged: (val) {
                                final next = _draftConfigFromControllers()
                                    .copyWith(moodCurationEnabled: val);
                                unawaited(_persistDraft(overrideConfig: next));
                              },
                            ),
                            _buildSwitchCell(
                              rowKey: const ValueKey('ios-ai-diag-switch'),
                              icon: CupertinoIcons.wrench_fill,
                              iconColor: AppleColors.systemOrange,
                              title: '播放异常与源故障智能排障',
                              subtitle: '脱敏分析流媒体报错并提供一键内核/响度/线路修复',
                              value: _config.smartDiagnosticsEnabled,
                              onChanged: (val) {
                                final next = _draftConfigFromControllers()
                                    .copyWith(smartDiagnosticsEnabled: val);
                                unawaited(_persistDraft(overrideConfig: next));
                              },
                            ),
                            _buildSwitchCell(
                              rowKey:
                                  const ValueKey('ios-ai-danmumatch-switch'),
                              icon: CupertinoIcons.captions_bubble,
                              iconColor: AppleColors.systemCyan,
                              title: 'AI 全网弹幕搜索与自动匹配',
                              subtitle: '从公开弹幕源检索匹配当前剧集的弹幕并智能校对时间轴',
                              value: _config.danmuMatchEnabled,
                              onChanged: (val) {
                                final next = _draftConfigFromControllers()
                                    .copyWith(danmuMatchEnabled: val);
                                unawaited(_persistDraft(overrideConfig: next));
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _buildCustomSkillsGroup(context),
                        const SizedBox(height: 20),
                        IosSettingsGroup(
                          header: '用量统计、额度余额与缓存（${usage.monthKey}）',
                          footer:
                              '点击「本月用量统计与调用明细」可查看每次请求详情、API 账户余额及 GPT 订阅 5 小时 / 周额度；相同查询命中本地 SHA-256 缓存时消耗 0 Token。',
                          dividerIndent: 16,
                          children: [
                            IosSettingsRow(
                              key: const ValueKey('ios-ai-usage-detail-row'),
                              icon: CupertinoIcons.chart_bar_alt_fill,
                              iconColor: AppleColors.systemGreen,
                              title: '本月用量统计与调用明细',
                              subtitle:
                                  '输入 ${usage.promptTokens} · 输出 ${usage.completionTokens} · 缓存 $cacheCount 条',
                              trailingText:
                                  '${usage.requestCount} 次 · ${usage.totalTokens} tok',
                              showChevron: true,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                Navigator.of(context).push<void>(
                                  buildApplePageRoute<void>(
                                    builder: (_) => IosAiUsageDetailPage(
                                      service: _service,
                                      backLabel: 'AI 观影实验室',
                                    ),
                                  ),
                                );
                              },
                            ),
                            if (_config.authMode == AiAuthMode.codexOAuth &&
                                _service.hasOAuthSession)
                              _buildInlineSubscriptionQuotaSummary(context),
                            if (_config.authMode == AiAuthMode.apiKey &&
                                _baseUrlCtrl.text.trim().isNotEmpty &&
                                _apiKeyCtrl.text.trim().isNotEmpty)
                              _buildInlineApiBalanceSummary(context),
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

  Widget _buildLabPasscodeGateView(BuildContext context) {
    final p = ApplePalette.of(context);
    final cardBg = p.isDark ? const Color(0xFF1C1C22) : Colors.white;
    final fieldBg = p.isDark ? const Color(0xFF282830) : const Color(0xFFF2F4F8);
    return DecoratedBox(
      key: const ValueKey('ios-ai-lab-gate-card'),
      decoration: ShapeDecoration(
        color: cardBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: p.isDark ? const Color(0x24FFFFFF) : const Color(0x14000000),
            width: 0.75,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF6366F1), Color(0xFFA855F7)],
                  ),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const SizedBox(
                  width: 54,
                  height: 54,
                  child: Icon(
                    CupertinoIcons.lock_shield_fill,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'AI 观影实验室 · 内测中',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.labelPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '当前处于限量内测阶段，请输入官方离线签发的 MMAILAB1.… 口令（iOS / Windows / Android 移动端三端通用）。'
              '解锁前播放页、详情页与搜索栏均保持纯净隐藏；验签全程在本机离线完成。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: p.labelSecondary,
                fontSize: 13.2,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            CupertinoTextField(
              key: const ValueKey('ios-ai-lab-passcode-field'),
              controller: _labPasscodeCtrl,
              placeholder: '粘贴 MMAILAB1.… 离线签名口令（支持整段粘贴）',
              minLines: 2,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              padding: const EdgeInsets.all(12),
              style: TextStyle(color: p.labelPrimary, fontSize: 13.5),
              decoration: BoxDecoration(
                color: fieldBg,
                borderRadius: BorderRadius.circular(12),
              ),
              onChanged: (_) {
                if (_labGateError != null) {
                  setState(() => _labGateError = null);
                }
              },
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                key: const ValueKey('ios-ai-lab-paste-btn'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: const Size(44, 28),
                onPressed: () async {
                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                  final raw = (clip?.text ?? '').trim();
                  if (!mounted || raw.isEmpty) return;
                  final extracted = AiLabPasscodeVerifier.extractToken(raw);
                  setState(() {
                    _labPasscodeCtrl.text =
                        extracted.startsWith('MMAILAB1.') ? extracted : raw;
                    _labGateError = null;
                  });
                },
                child: Text(
                  '粘贴剪贴板口令',
                  style: TextStyle(
                    color: p.systemBlue,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (_labGateError != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: AppleColors.systemRed.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  _labGateError!,
                  key: const ValueKey('ios-ai-lab-gate-error'),
                  style: const TextStyle(
                    color: AppleColors.systemRed,
                    fontSize: 12.8,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              height: 46,
              child: CupertinoButton(
                key: const ValueKey('ios-ai-lab-unlock-btn'),
                color: AppleColors.systemBlue,
                borderRadius: BorderRadius.circular(14),
                onPressed: () async {
                  HapticFeedback.selectionClick();
                  final res = await _service
                      .verifyAndUnlockAiLab(_labPasscodeCtrl.text);
                  if (!mounted) return;
                  if (!res.isValid) {
                    setState(() => _labGateError = res.messageZh);
                    return;
                  }
                  setState(() => _labGateError = null);
                  widget.onChanged?.call();
                },
                child: const Text(
                  '验证口令并开启 AI 观影实验室',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            CupertinoButton(
              key: const ValueKey('ios-ai-lab-community-btn'),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              minimumSize: const Size(44, 32),
              onPressed: () async {
                HapticFeedback.selectionClick();
                await openOfficialChannelUrl(
                  OfficialChannelInfo.marcoCommunityChannelUri,
                  urlOpener: widget.urlLauncherOverride,
                );
              },
              child: Text(
                '前往官方交流频道【${OfficialChannelInfo.marcoCommunityChannelName}】获取内测口令',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.systemBlue,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabUnlockedHeaderBanner(BuildContext context) {
    final p = ApplePalette.of(context);
    final payload = _service.activePasscodePayload;
    final tagLabel = (payload != null && payload.tag.trim().isNotEmpty)
        ? payload.tag.trim()
        : '官方内测';
    final scopeLabel = payload?.platformScopeLabelZh ?? '三端通用';
    final channelLabel = payload?.channelTypeLabelZh ?? '内测授权';
    final expiryLabel = payload?.expiryLabelZh ?? '已激活';

    return Container(
      key: const ValueKey('ios-ai-lab-unlocked-card'),
      padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
      decoration: BoxDecoration(
        color: AppleColors.systemPurple.withValues(alpha: p.isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppleColors.systemPurple.withValues(alpha: p.isDark ? 0.34 : 0.22),
          width: 0.7,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.checkmark_shield_fill,
                color: AppleColors.systemPurple,
                size: 18,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'AI 观影实验室已开启 · $tagLabel（$channelLabel）',
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '适用平台：$scopeLabel  ·  有效期：$expiryLabel'
            '${payload?.experimentalOAuth == true ? "  ·  含实验性 OAuth" : ""}',
            style: TextStyle(
              color: p.labelSecondary,
              fontSize: 12.2,
              height: 1.38,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              GestureDetector(
                key: const ValueKey('ios-ai-lab-replace-btn'),
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  final changed = await showIosAiLabPasscodeSheet(
                    context,
                    service: _service,
                    isReplacing: true,
                    urlLauncherOverride: widget.urlLauncherOverride,
                  );
                  if (changed && mounted) {
                    setState(() {});
                    widget.onChanged?.call();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
                  decoration: BoxDecoration(
                    color: p.systemBlue.withValues(alpha: p.isDark ? 0.22 : 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '更换口令',
                    style: TextStyle(
                      color: p.systemBlue,
                      fontSize: 12.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                key: const ValueKey('ios-ai-lab-lock-btn'),
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  await _service.lockAiLab();
                  if (mounted) setState(() {});
                  widget.onChanged?.call();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
                  decoration: BoxDecoration(
                    color: AppleColors.systemRed.withValues(alpha: p.isDark ? 0.20 : 0.11),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    '退出内测并重新锁定',
                    style: TextStyle(
                      color: AppleColors.systemRed,
                      fontSize: 12.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCustomSkillsGroup(BuildContext context) {
    final allSkills = _config.effectiveSkills;
    return IosSettingsGroup(
      header: '扩展 AI 技能卡（Prompt Skills）',
      footer: '支持使用 {{title}}、{{year}}、{{episode}}、{{overview}}、{{subtitles}} 模板变量挂载到详情页或播放器更多菜单。',
      dividerIndent: 16,
      children: [
        for (final skill in allSkills)
          IosSettingsRow(
            icon: CupertinoIcons.sparkles,
            iconColor: skill.id.startsWith('builtin_')
                ? AppleColors.systemIndigo
                : AppleColors.systemOrange,
            title: skill.name,
            subtitle: '${skill.target.labelZh} · ${skill.useFastModel ? "轻量模型" : "主力模型"}',
            trailingText: skill.id.startsWith('builtin_') ? '内置' : '删除',
            onTap: skill.id.startsWith('builtin_')
                ? null
                : () {
                    final nextCustom = _config.customSkills
                        .where((s) => s.id != skill.id)
                        .toList();
                    final next = _draftConfigFromControllers()
                        .copyWith(customSkills: nextCustom);
                    unawaited(_persistDraft(overrideConfig: next));
                  },
          ),
        IosSettingsRow(
          key: const ValueKey('ios-ai-add-skill-btn'),
          icon: CupertinoIcons.add_circled_solid,
          iconColor: AppleColors.systemBlue,
          title: '新增自定义 AI 技能卡',
          showChevron: true,
          onTap: () => _showAddCustomSkillSheet(context),
        ),
      ],
    );
  }

  Future<void> _showAddCustomSkillSheet(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final tplCtrl = TextEditingController(
      text: '请围绕《{{title}}》（{{year}}）{{episode}}，分析：',
    );
    AiSkillTarget target = AiSkillTarget.both;
    bool useFast = false;

    await showIos27LiquidSheet<void>(
      context: context,
      title: '新增自定义 AI 技能卡',
      maxWidth: 480,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final p = ApplePalette.of(ctx);
          final fieldBg =
              p.isDark ? const Color(0xFF282830) : const Color(0xFFF2F4F8);
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              18,
              12,
              18,
              24 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CupertinoTextField(
                  controller: nameCtrl,
                  placeholder: '技能名称（如：豆瓣风无剧透短评）',
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: fieldBg,
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
                const SizedBox(height: 10),
                CupertinoTextField(
                  controller: tplCtrl,
                  placeholder: '输入提示词模板…',
                  minLines: 3,
                  maxLines: 5,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: fieldBg,
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
                const SizedBox(height: 10),
                CupertinoSlidingSegmentedControl<AiSkillTarget>(
                  groupValue: target,
                  children: const {
                    AiSkillTarget.both: Text('双端显示', style: TextStyle(fontSize: 12)),
                    AiSkillTarget.detailOnly: Text('仅详情页', style: TextStyle(fontSize: 12)),
                    AiSkillTarget.playerOnly: Text('仅播放器', style: TextStyle(fontSize: 12)),
                  },
                  onValueChanged: (v) {
                    if (v != null) setModalState(() => target = v);
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '优先使用轻量极速模型',
                        style: TextStyle(color: p.labelPrimary, fontSize: 13.5),
                      ),
                    ),
                    CupertinoSwitch(
                      value: useFast,
                      onChanged: (v) => setModalState(() => useFast = v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 44,
                  child: CupertinoButton(
                    color: AppleColors.systemBlue,
                    borderRadius: BorderRadius.circular(13),
                    onPressed: () {
                      final name = nameCtrl.text.trim();
                      final tpl = tplCtrl.text.trim();
                      if (name.isEmpty || tpl.isEmpty) return;
                      final created = AiCustomSkill(
                        id: 'skill_${DateTime.now().millisecondsSinceEpoch}',
                        name: name,
                        promptTemplate: tpl,
                        target: target,
                        useFastModel: useFast,
                      );
                      final next = _draftConfigFromControllers().copyWith(
                        customSkills: [..._config.customSkills, created],
                      );
                      unawaited(_persistDraft(overrideConfig: next));
                      Navigator.of(ctx).pop();
                    },
                    child: const Text(
                      '保存技能卡',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    nameCtrl.dispose();
    tplCtrl.dispose();
  }

  Widget _buildInlineSubscriptionQuotaSummary(BuildContext context) {
    final p = ApplePalette.of(context);
    final snap = _service.subscriptionQuota;
    final now = DateTime.now();
    final local5h = _service.rollingWindowUsage(const Duration(hours: 5));
    final local7d = _service.rollingWindowUsage(const Duration(days: 7));
    return Padding(
      key: const ValueKey('ios-ai-sub-quota-card'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.speedometer,
                size: 15,
                color: p.systemBlue,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'GPT 订阅额度（5 小时 / 周额度）',
                  style: TextStyle(
                    color: p.labelPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              GestureDetector(
                key: const ValueKey('ios-ai-refresh-quota-btn'),
                behavior: HitTestBehavior.opaque,
                onTap: _refreshingQuota ? null : _refreshQuotaSilently,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_refreshingQuota)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: CupertinoActivityIndicator(radius: 6),
                      )
                    else
                      Icon(
                        CupertinoIcons.refresh,
                        size: 13,
                        color: p.systemBlue,
                      ),
                    const SizedBox(width: 3),
                    Text(
                      '刷新额度',
                      style: TextStyle(
                        color: p.systemBlue,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _IosSubscriptionQuotaWindowBar(
            label: '5 小时窗口额度',
            window: snap?.fiveHourWindow,
            now: now,
            localSummary:
                '本机近 5h：${local5h.requests} 次 · ${local5h.totalTokens} tok',
          ),
          const SizedBox(height: 9),
          _IosSubscriptionQuotaWindowBar(
            label: '7 天周额度',
            window: snap?.weeklyWindow,
            now: now,
            localSummary:
                '本机近 7d：${local7d.requests} 次 · ${local7d.totalTokens} tok',
          ),
        ],
      ),
    );
  }

  Widget _buildInlineApiBalanceSummary(BuildContext context) {
    final p = ApplePalette.of(context);
    final bal = _service.apiBalance;
    return Padding(
      key: const ValueKey('ios-ai-api-balance-card'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
      child: _IosApiBalanceCardContent(
        balance: bal,
        refreshing: _refreshingApiBalance,
        refreshButtonKey: const ValueKey('ios-ai-refresh-balance-btn'),
        onRefresh: () => unawaited(_refreshApiBalanceSilently(force: true)),
        palette: p,
      ),
    );
  }
}

class _IosApiBalanceCardContent extends StatelessWidget {
  final AiApiBalanceSnapshot? balance;
  final bool refreshing;
  final Key? refreshButtonKey;
  final VoidCallback onRefresh;
  final ApplePalette palette;

  const _IosApiBalanceCardContent({
    required this.balance,
    required this.refreshing,
    required this.refreshButtonKey,
    required this.onRefresh,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final bal = balance;
    final ratio = bal?.usedRatio;
    final barColor = ratio != null && ratio >= 0.90
        ? AppleColors.systemRed
        : (ratio != null && ratio >= 0.72
              ? AppleColors.systemOrange
              : AppleColors.systemGreen);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              CupertinoIcons.creditcard_fill,
              size: 15,
              color: bal != null && bal.supported
                  ? AppleColors.systemGreen
                  : p.labelSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'API 账户余额',
                style: TextStyle(
                  color: p.labelPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            GestureDetector(
              key: refreshButtonKey,
              behavior: HitTestBehavior.opaque,
              onTap: refreshing ? null : onRefresh,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (refreshing)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: CupertinoActivityIndicator(radius: 6),
                    )
                  else
                    Icon(
                      CupertinoIcons.refresh,
                      size: 13,
                      color: p.systemBlue,
                    ),
                  const SizedBox(width: 3),
                  Text(
                    refreshing ? '查询中' : '刷新余额',
                    style: TextStyle(
                      color: p.systemBlue,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          bal == null
              ? (refreshing ? '正在尝试从当前 API 接口获取余额…' : '点击右上角尝试查询当前 API 余额')
              : bal.headlineTextZh,
          key: const ValueKey('ios-ai-api-balance-headline'),
          style: TextStyle(
            color: bal != null && bal.supported
                ? p.labelPrimary
                : p.labelSecondary,
            fontSize: bal != null && bal.supported ? 16 : 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (ratio != null) ...[
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 6,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: p.isDark
                        ? const Color(0xFF2C2C36)
                        : const Color(0xFFE4E7F0),
                  ),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: ratio,
                    child: ColoredBox(color: barColor),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 5),
        Text(
          bal == null
              ? '自动兼容 OneAPI / NewAPI / OpenRouter / DeepSeek / 硅基流动等标准余额接口'
              : bal.detailSubtitleZh,
          style: TextStyle(
            color: p.labelTertiary,
            fontSize: 11.5,
            height: 1.38,
          ),
        ),
      ],
    );
  }
}

class _IosSubscriptionQuotaWindowBar extends StatelessWidget {
  final String label;
  final AiSubscriptionQuotaWindow? window;
  final DateTime now;
  final String localSummary;

  const _IosSubscriptionQuotaWindowBar({
    required this.label,
    required this.window,
    required this.now,
    required this.localSummary,
  });

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final pct = window?.usedPercent;
    final hasRemote = pct != null;
    final ratio = hasRemote ? (pct / 100.0).clamp(0.0, 1.0) : 0.0;
    final barColor = ratio >= 0.90
        ? AppleColors.systemRed
        : (ratio >= 0.72 ? AppleColors.systemOrange : p.systemBlue);
    final countdown = window?.resetCountdownZh(now) ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: p.labelSecondary,
                  fontSize: 12.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              hasRemote
                  ? '已用 ${pct.toStringAsFixed(0)}% · 剩余 ${(100.0 - pct).clamp(0.0, 100.0).toStringAsFixed(0)}%'
                      '${countdown.isNotEmpty ? "（$countdown）" : ""}'
                  : localSummary,
              style: TextStyle(
                color: p.labelPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 6,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: p.isDark
                      ? const Color(0xFF2C2C36)
                      : const Color(0xFFE4E7F0),
                ),
                if (hasRemote)
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: ratio,
                    child: ColoredBox(color: barColor),
                  ),
              ],
            ),
          ),
        ),
        if (hasRemote) ...[
          const SizedBox(height: 3),
          Text(
            localSummary,
            style: TextStyle(color: p.labelTertiary, fontSize: 11.2),
          ),
        ],
      ],
    );
  }
}

/// Dedicated drill-down page showing subscription 5h/weekly quota windows,
/// per-feature token breakdown, and chronological AI call history.
class IosAiUsageDetailPage extends StatefulWidget {
  final AiService? service;
  final String backLabel;

  const IosAiUsageDetailPage({
    super.key,
    this.service,
    this.backLabel = 'AI 观影实验室',
  });

  @override
  State<IosAiUsageDetailPage> createState() => _IosAiUsageDetailPageState();
}

class _IosAiUsageDetailPageState extends State<IosAiUsageDetailPage> {
  late final AiService _service;
  bool _refreshing = false;
  bool _refreshingBalance = false;

  static String featureLabelZh(String raw) {
    switch (raw.trim()) {
      case 'live_subtitle_translate':
      case 'ai_sub_live_v1':
        return '实时内封双语字幕';
      case 'subtitle_translate':
      case 'subtitle_glossary':
      case 'subtitle_offset':
      case 'ai_sub_v1':
      case 'ai_sub_offset_v1':
        return '外挂字幕精译与对轴';
      case 'watch_brief':
      case 'ai_watch_brief_v1':
        return '零剧透看点与设定科普';
      case 'post_credits_guide':
      case 'ai_post_credits_v1':
        return '片尾彩蛋与版本提示';
      case 'work_qa':
      case 'ai_work_qa_v1':
        return '自由观影问答';
      case 'mood_sommelier':
      case 'ai_sommelier_v1':
        return '口味画像与片单策展';
      case 'nl_search':
      case 'nl_search_v1':
        return '自然语言找片';
      case 'title_cleanup':
      case 'title_clean_v1':
        return '文件名与标题清洗';
      case 'episode_curate':
      case 'ai_ep_curate_v1':
        return '杂乱剧集智能编排';
      case 'diagnostics':
      case 'ai_diag_v1':
        return '播放与源故障排障';
      case 'ai_danmu_match':
      case 'ai_danmu_match_v1':
        return 'AI 全网弹幕匹配';
      case 'ai_danmu_offset':
      case 'ai_danmu_offset_v1':
        return 'AI 弹幕时间轴校对';
      case 'connection_test':
      case 'ping':
        return '接口连接测试';
      default:
        if (raw.startsWith('custom_skill:') || raw.startsWith('skill:')) {
          return '扩展技能卡';
        }
        return raw.trim().isEmpty ? 'AI 请求' : raw.trim();
    }
  }

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? AiService.instance;
    _service.addListener(_onChanged);
    if (!_service.isPrivacySessionActive &&
        _service.isLabUnlocked &&
        _service.isExperimentalOAuthAllowed &&
        _service.hasOAuthSession) {
      unawaited(_refreshQuota());
    }
    if (!_service.isPrivacySessionActive &&
        _service.isLabUnlocked &&
        _service.activeAuthMode == AiAuthMode.apiKey &&
        _service.hasApiKey &&
        _service.config.baseUrl.trim().isNotEmpty) {
      unawaited(_refreshApiBalance());
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshQuota() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _service.refreshSubscriptionQuota();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _refreshApiBalance({bool force = false}) async {
    if (_refreshingBalance) return;
    setState(() => _refreshingBalance = true);
    try {
      await _service.refreshApiBalance(force: force);
    } finally {
      if (mounted) setState(() => _refreshingBalance = false);
    }
  }

  String _formatTime(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final usage = _service.monthlyUsage;
    final history = _service.usageHistory;
    final snap = _service.subscriptionQuota;
    final session = _service.oauthSession;
    final local5h = _service.rollingWindowUsage(const Duration(hours: 5));
    final local7d = _service.rollingWindowUsage(const Duration(days: 7));

    final byFeature = <String, ({int count, int tokens})>{};
    for (final item in history) {
      final label = featureLabelZh(item.feature);
      final prev = byFeature[label] ?? (count: 0, tokens: 0);
      byFeature[label] = (
        count: prev.count + 1,
        tokens: prev.tokens + item.totalTokens,
      );
    }
    final featureEntries = byFeature.entries.toList()
      ..sort((a, b) => b.value.tokens.compareTo(a.value.tokens));

    return IosSettingsScaffold(
      title: '用量统计与额度详情',
      backLabel: widget.backLabel,
      body: ListView(
        key: const ValueKey('ios-ai-usage-detail-page'),
        padding: EdgeInsets.fromLTRB(18, 16, 18, safeBottom + 40),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 740),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_service.hasOAuthSession) ...[
                    IosSettingsGroup(
                      header:
                          'GPT 订阅账号实时额度${session != null ? " · ${session.planBadgeLabel}" : ""}',
                      footer:
                          '5 小时窗口与 7 天周额度直接同步自您的 ChatGPT 订阅配额响应头与用量接口。',
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _IosSubscriptionQuotaWindowBar(
                                label: '5 小时滚动额度 (5h)',
                                window: snap?.fiveHourWindow,
                                now: DateTime.now(),
                                localSummary:
                                    '本机近 5h：${local5h.requests} 次 · ${local5h.totalTokens} tokens',
                              ),
                              const SizedBox(height: 12),
                              _IosSubscriptionQuotaWindowBar(
                                label: '7 天周额度 (Weekly)',
                                window: snap?.weeklyWindow,
                                now: DateTime.now(),
                                localSummary:
                                    '本机近 7d：${local7d.requests} 次 · ${local7d.totalTokens} tokens',
                              ),
                            ],
                          ),
                        ),
                        IosSettingsRow(
                          key: const ValueKey('ios-ai-usage-detail-refresh-btn'),
                          icon: CupertinoIcons.refresh_circled_solid,
                          iconColor: AppleColors.systemBlue,
                          title: _refreshing ? '正在同步订阅额度…' : '刷新实时订阅额度',
                          titleColor: p.systemBlue,
                          onTap: _refreshing ? null : _refreshQuota,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],
                  if (_service.activeAuthMode == AiAuthMode.apiKey &&
                      _service.hasApiKey &&
                      _service.config.baseUrl.trim().isNotEmpty) ...[
                    IosSettingsGroup(
                      header: 'API 账户余额与额度',
                      footer:
                          '仅向您自行填写的 API 接口同源查询标准余额路径，绝不转发密钥至第三方；若服务商未开放余额接口则静默隐藏数值。',
                      children: [
                        Padding(
                          key: const ValueKey('ios-ai-usage-detail-balance-card'),
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: _IosApiBalanceCardContent(
                            balance: _service.apiBalance,
                            refreshing: _refreshingBalance,
                            refreshButtonKey: const ValueKey(
                              'ios-ai-usage-detail-refresh-balance-btn',
                            ),
                            onRefresh: () =>
                                unawaited(_refreshApiBalance(force: true)),
                            palette: p,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],
                  IosSettingsGroup(
                    header: '本机用量汇总（${usage.monthKey}）',
                    dividerIndent: 16,
                    children: [
                      IosSettingsRow(
                        icon: CupertinoIcons.number_circle_fill,
                        iconColor: AppleColors.systemBlue,
                        title: '本月累计调用',
                        trailingText: '${usage.requestCount} 次',
                      ),
                      IosSettingsRow(
                        icon: CupertinoIcons.arrow_up_right_circle_fill,
                        iconColor: AppleColors.systemTeal,
                        title: '本月输入 / 输出 Tokens',
                        subtitle:
                            '输入 ${usage.promptTokens} · 输出 ${usage.completionTokens}',
                        trailingText: '共 ${usage.totalTokens}',
                      ),
                      IosSettingsRow(
                        icon: CupertinoIcons.clock_fill,
                        iconColor: AppleColors.systemIndigo,
                        title: '近 5 小时 / 近 7 天本机调用',
                        subtitle:
                            '5h：${local5h.requests} 次 (${local5h.totalTokens} tok)',
                        trailingText:
                            '7d：${local7d.requests} 次 (${local7d.totalTokens} tok)',
                      ),
                      IosSettingsRow(
                        icon: CupertinoIcons.archivebox_fill,
                        iconColor: AppleColors.systemGreen,
                        title: '本地零消耗响应缓存',
                        trailingText: '${_service.cachedEntryCount} 条',
                      ),
                    ],
                  ),
                  if (featureEntries.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    IosSettingsGroup(
                      header: '按功能模块分布',
                      dividerIndent: 16,
                      children: [
                        for (final e in featureEntries)
                          IosSettingsRow(
                            icon: CupertinoIcons.sparkles,
                            iconColor: AppleColors.systemPurple,
                            title: e.key,
                            subtitle: '调用 ${e.value.count} 次',
                            trailingText: '${e.value.tokens} tokens',
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                  IosSettingsGroup(
                    header: '最近调用明细（最多保留 ${AiService.maxUsageHistoryEntries} 条）',
                    dividerIndent: 16,
                    children: [
                      if (history.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(18),
                          child: Text(
                            '暂无调用记录。触发双语字幕、看点科普或连接测试后将在此显示每次请求的模型、耗时与 Token 明细。',
                            style: TextStyle(
                              color: p.labelSecondary,
                              fontSize: 13,
                              height: 1.45,
                            ),
                          ),
                        )
                      else
                        for (final log in history.take(60))
                          IosSettingsRow(
                            icon: log.authModeId == AiAuthMode.codexOAuth.id
                                ? CupertinoIcons.person_crop_circle_fill
                                : CupertinoIcons.bolt_circle_fill,
                            iconColor: log.authModeId == AiAuthMode.codexOAuth.id
                                ? AppleColors.systemGreen
                                : AppleColors.systemBlue,
                            title: featureLabelZh(log.feature),
                            subtitle:
                                '${_formatTime(log.timestampMs)} · ${log.model.isEmpty ? "默认模型" : log.model} · ${log.latencyMs}ms',
                            trailingText:
                                '入 ${log.promptTokens} / 出 ${log.completionTokens}',
                          ),
                      if (history.isNotEmpty)
                        IosSettingsRow(
                          key: const ValueKey('ios-ai-clear-usage-history-btn'),
                          icon: CupertinoIcons.trash_fill,
                          iconColor: AppleColors.systemRed,
                          title: '清空调用明细记录',
                          titleColor: AppleColors.systemRed,
                          onTap: () async {
                            HapticFeedback.mediumImpact();
                            await _service.clearUsageHistory();
                          },
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
