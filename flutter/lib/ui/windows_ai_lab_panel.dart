// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/ai_lab_passcode.dart';
import '../core/ai_oauth_manager.dart';
import '../core/ai_provider_profiles.dart';
import '../core/ai_service.dart';
import '../core/ai_title_cleaner.dart';
import 'apple_theme.dart';
import 'official_channel_notice.dart' show launchExternalOfficialUrl;
import 'windows_appearance.dart';

/// Windows Settings -> 「AI 实验室」 control center.
///
/// Gated by offline RFC 8032 Ed25519 signed passcodes ([AiLabPasscodeStore]).
/// Once unlocked, exposes an OpenMinis-inspired compliant multi-provider hub:
/// - Official OpenRouter PKCE browser OAuth
/// - Official GitHub Copilot RFC 8628 Device Code Flow
/// - Zero-config local loopback discovery (Ollama / LM Studio)
/// - Multi-instance BYOK profiles with `/v1/models` catalog discovery
/// - Dual-tier model routing, monthly token budget, and Phase-1 toggles
class WindowsAiLabPanel extends StatefulWidget {
  final AiService? service;
  final AiLabPasscodeStore? passcodeStore;
  final Future<bool> Function(Uri uri)? urlOpener;
  final http.Client? discoveryHttpClient;
  final VoidCallback? onChanged;

  const WindowsAiLabPanel({
    super.key,
    this.service,
    this.passcodeStore,
    this.urlOpener,
    this.discoveryHttpClient,
    this.onChanged,
  });

  @override
  State<WindowsAiLabPanel> createState() => _WindowsAiLabPanelState();
}

class _WindowsAiLabPanelState extends State<WindowsAiLabPanel> {
  late final AiService _service;
  late final AiLabPasscodeStore _passcodeStore;

  final TextEditingController _passcodeCtrl = TextEditingController();
  final TextEditingController _profileNameCtrl = TextEditingController();
  final TextEditingController _baseUrlCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _fastModelCtrl = TextEditingController();

  bool _obscureApiKey = true;
  bool _unlocking = false;
  String? _passcodeStatus;
  bool _passcodeStatusError = false;

  AiApiProtocol _editingProtocol = AiApiProtocol.openaiCompatible;
  AiAuthMode _editingAuthMode = AiAuthMode.apiKey;
  String _editingProfileId = '';
  String _editingPresetId = 'custom';
  String _editingAccountLabel = '';

  bool _testingConnection = false;
  AiConnectionTestResult? _testResult;

  bool _fetchingModels = false;
  List<String> _fetchedModels = const <String>[];
  String? _modelsError;

  bool _discoveringLocal = false;
  List<AiLocalDiscoveryResult> _localResults = const <AiLocalDiscoveryResult>[];
  String? _localDiscoveryNote;

  String? _statusNotice;

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
    _passcodeStore = widget.passcodeStore ?? AiLabPasscodeStore.instance;
    _service.addListener(_onServiceChanged);
    _passcodeStore.addListener(_onPasscodeChanged);
    unawaited(_initAsync());
  }

  Future<void> _initAsync() async {
    await Future.wait<void>(<Future<void>>[
      _passcodeStore.ensureLoaded(),
      _service.ensureLoaded(),
    ]);
    await _syncEditorsFromActiveProfile();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged?.call();
  }

  void _onPasscodeChanged() {
    if (!mounted) return;
    setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _syncEditorsFromActiveProfile() async {
    final active = _service.activeProfile;
    final cfg = _service.config;
    final secret = active != null
        ? await _service.readProfileSecret(active.id)
        : await _service.readApiKey();
    if (!mounted) return;
    setState(() {
      _editingProfileId = active?.id ?? '';
      _editingPresetId = active?.presetId ?? 'custom';
      _editingAccountLabel = active?.accountLabel ?? '';
      _editingProtocol = active?.protocol ?? cfg.protocol;
      _editingAuthMode = active?.authMode ?? AiAuthMode.apiKey;
      _profileNameCtrl.text = active?.name ?? '';
      _baseUrlCtrl.text = active?.baseUrl ?? cfg.baseUrl;
      _modelCtrl.text = active?.model ?? cfg.model;
      _fastModelCtrl.text = active?.fastModel ?? cfg.fastModel;
      _apiKeyCtrl.text = secret;
    });
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _passcodeStore.removeListener(_onPasscodeChanged);
    _passcodeCtrl.dispose();
    _profileNameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _fastModelCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleUnlock() async {
    if (_unlocking) return;
    setState(() {
      _unlocking = true;
      _passcodeStatus = null;
      _passcodeStatusError = false;
    });
    try {
      final result = await _passcodeStore.unlockWithPasscode(_passcodeCtrl.text);
      if (!mounted) return;
      setState(() {
        _passcodeStatus = result.messageZh;
        _passcodeStatusError = !result.isValid;
        if (result.isValid) {
          _passcodeCtrl.clear();
        }
      });
      if (result.isValid) {
        await _syncEditorsFromActiveProfile();
      }
    } finally {
      if (mounted) {
        setState(() => _unlocking = false);
      }
    }
  }

  Future<void> _pastePasscode() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = (data?.text ?? '').trim();
      if (!mounted) return;
      if (text.isEmpty) {
        setState(() {
          _passcodeStatus = '剪贴板为空，请先复制 Ed25519 签名口令';
          _passcodeStatusError = true;
        });
        return;
      }
      _passcodeCtrl.text = text;
      setState(() {
        _passcodeStatus = '已粘贴口令，点击「验证并解锁」完成离线验签';
        _passcodeStatusError = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _passcodeStatus = '无法读取剪贴板，请手动按 Ctrl+V 粘贴';
        _passcodeStatusError = true;
      });
    }
  }

  Future<void> _saveCurrentEditor({bool showToast = true}) async {
    final baseUrl = _baseUrlCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final fastModel = _fastModelCtrl.text.trim();
    final key = _apiKeyCtrl.text.trim();
    final name = _profileNameCtrl.text.trim().isNotEmpty
        ? _profileNameCtrl.text.trim()
        : (findAiProviderPreset(_editingPresetId)?.name ?? '自定义服务商');

    final id = _editingProfileId.isNotEmpty
        ? _editingProfileId
        : 'profile_${DateTime.now().millisecondsSinceEpoch}';
    final profile = AiProviderProfile(
      id: id,
      name: name,
      presetId: _editingPresetId,
      protocol: _editingProtocol,
      authMode: _editingAuthMode,
      baseUrl: baseUrl,
      model: model,
      fastModel: fastModel,
      accountLabel: _editingAccountLabel,
    );
    await _service.saveProfile(
      profile,
      secret: key,
      activate: true,
    );
    if (!mounted) return;
    setState(() {
      _editingProfileId = id;
      if (showToast) {
        _statusNotice = '配置已保存到本机（密钥已加密存储，不会参与云同步）';
      }
    });
  }

  Future<void> _switchProfile(AiProviderProfile profile) async {
    await _service.activateProfile(profile.id);
    await _syncEditorsFromActiveProfile();
    if (!mounted) return;
    setState(() {
      _fetchedModels = const <String>[];
      _modelsError = null;
      _testResult = null;
      _statusNotice = '已切换至「${profile.name}」';
    });
  }

  Future<void> _deleteProfile(AiProviderProfile profile) async {
    await _service.deleteProfile(profile.id);
    await _syncEditorsFromActiveProfile();
    if (!mounted) return;
    setState(() {
      _fetchedModels = const <String>[];
      _testResult = null;
      _statusNotice = '已删除服务商「${profile.name}」并清除其本地密钥';
    });
  }

  Future<void> _applyPreset(AiProviderPreset preset) async {
    final id = 'preset_${preset.id}_${DateTime.now().millisecondsSinceEpoch}';
    final profile = AiProviderProfile.fromPreset(preset, id: id);
    await _service.saveProfile(
      profile,
      secret: '',
      activate: true,
      enableAiWhenActivating: preset.authMode == AiAuthMode.localNoAuth,
    );
    await _syncEditorsFromActiveProfile();
    if (!mounted) return;
    setState(() {
      _fetchedModels = preset.suggestedModels;
      _modelsError = null;
      _testResult = null;
      _statusNotice = '已添加「${preset.name}」模板，请补充密钥或完成授权后测试连接';
    });
  }

  Future<void> _openAddProviderPresetDialog() async {
    final selected = await showDialog<AiProviderPreset>(
      context: context,
      builder: (dialogCtx) {
        final isDark = Theme.of(dialogCtx).brightness == Brightness.dark;
        final bg = isDark ? const Color(0xFF161C25) : const Color(0xFFFAFBFD);
        final border =
            isDark ? const Color(0x26FFFFFF) : const Color(0x1A0F172A);
        final ink = isDark ? const Color(0xFFF2F5FA) : const Color(0xFF131B26);
        final muted =
            isDark ? const Color(0xFFA7B4C7) : const Color(0xFF556377);
        return Dialog(
          backgroundColor: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: border),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540, maxHeight: 580),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选择 AI 服务商模板',
                          style: TextStyle(
                            color: ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(dialogCtx).pop(),
                        icon: Icon(CupertinoIcons.xmark, size: 16, color: muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '所有密钥与 OAuth 令牌均仅保存在本机系统加密凭据库中，不内置任何官方密钥。',
                    style: TextStyle(color: muted, fontSize: 12.2),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: kAiProviderPresets.length,
                      separatorBuilder: (_, __) => Divider(height: 1, color: border),
                      itemBuilder: (_, idx) {
                        final preset = kAiProviderPresets[idx];
                        return ListTile(
                          key: ValueKey('win-ai-preset-${preset.id}'),
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          title: Row(
                            children: [
                              Text(
                                preset.name,
                                style: TextStyle(
                                  color: ink,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: border,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  preset.authMode.labelZh,
                                  style: TextStyle(color: muted, fontSize: 10.5),
                                ),
                              ),
                            ],
                          ),
                          subtitle: Text(
                            preset.description,
                            style: TextStyle(color: muted, fontSize: 11.8),
                          ),
                          trailing: Icon(
                            CupertinoIcons.chevron_right,
                            size: 14,
                            color: muted,
                          ),
                          onTap: () => Navigator.of(dialogCtx).pop(preset),
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
    if (selected == null || !mounted) return;
    if (selected.authMode == AiAuthMode.openRouterOAuth) {
      await _startOpenRouterOAuth();
    } else if (selected.authMode == AiAuthMode.githubCopilotDeviceFlow) {
      await _startGitHubCopilotDeviceFlow();
    } else {
      await _applyPreset(selected);
    }
  }

  Future<void> _startOpenRouterOAuth() async {
    final cancelToken = AiOAuthCancelToken();
    Uri? authUri;
    String statusText = '正在启动本机 127.0.0.1 PKCE 回调服务并打开浏览器…';
    bool done = false;

    final result = await showDialog<OpenRouterOAuthResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            if (!done && authUri == null) {
              done = true;
              unawaited(
                OpenRouterPkceManager.authorize(
                  cancelToken: cancelToken,
                  urlOpener: widget.urlOpener,
                  onAuthorizeUriReady: (uri, _) {
                    authUri = uri;
                    if (ctx.mounted) {
                      setDialogState(() {
                        statusText =
                            '已在浏览器打开 OpenRouter 官方授权页，请在浏览器确认授权…';
                      });
                    }
                  },
                ).then((res) {
                  if (dialogCtx.mounted) {
                    Navigator.of(dialogCtx).pop(res);
                  }
                }).catchError((Object err) {
                  if (ctx.mounted) {
                    setDialogState(() {
                      statusText = redactAiSecret(err.toString());
                    });
                  }
                }),
              );
            }
            return AlertDialog(
              key: const ValueKey('win-ai-openrouter-oauth-dialog'),
              title: const Text('OpenRouter PKCE 一键授权'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(statusText),
                    if (authUri != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () {
                          unawaited(
                            Clipboard.setData(
                              ClipboardData(text: authUri.toString()),
                            ),
                          );
                        },
                        icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 14),
                        label: const Text('复制授权链接'),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelToken.cancel();
                    Navigator.of(dialogCtx).pop();
                  },
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;
    final preset = findAiProviderPreset('openrouter')!;
    final existing = _service.profiles
        .where((p) => p.authMode == AiAuthMode.openRouterOAuth)
        .firstOrNull;
    final profile = (existing ??
            AiProviderProfile.fromPreset(
              preset,
              id: 'openrouter_oauth_${DateTime.now().millisecondsSinceEpoch}',
            ))
        .copyWith(
      authMode: AiAuthMode.openRouterOAuth,
      baseUrl: OpenRouterPkceManager.defaultApiBaseUrl,
      accountLabel: result.accountLabel,
    );
    await _service.saveProfile(
      profile,
      secret: result.apiKey,
      activate: true,
      enableAiWhenActivating: true,
    );
    await _syncEditorsFromActiveProfile();
    if (!mounted) return;
    setState(() {
      _statusNotice = 'OpenRouter PKCE 授权成功，密钥已写入本机加密存储并启用';
    });
  }

  Future<void> _startGitHubCopilotDeviceFlow() async {
    final cancelToken = AiOAuthCancelToken();
    CopilotDeviceCodePrompt? prompt;
    String status = '正在向 GitHub 请求 RFC 8628 设备验证码…';
    bool started = false;
    bool finished = false;

    final githubToken = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            if (!started) {
              started = true;
              unawaited(() async {
                try {
                  final p = await GitHubCopilotDeviceFlow.instance
                      .requestDeviceCode();
                  prompt = p;
                  if (ctx.mounted) {
                    setDialogState(() {
                      status = '请复制下方 8 位设备码并在浏览器完成 GitHub 授权，窗口将自动检测登录状态。';
                    });
                  }
                  final token = await GitHubCopilotDeviceFlow.instance
                      .pollAccessToken(p, cancelToken: cancelToken);
                  finished = true;
                  if (dialogCtx.mounted) {
                    Navigator.of(dialogCtx).pop(token);
                  }
                } catch (e) {
                  finished = true;
                  if (ctx.mounted) {
                    setDialogState(() {
                      status = redactAiSecret(e.toString());
                    });
                  }
                }
              }());
            }
            return AlertDialog(
              key: const ValueKey('win-ai-copilot-device-dialog'),
              title: const Text('GitHub Copilot 官方设备码登录'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(status),
                    if (prompt != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: SelectableText(
                                prompt!.userCode,
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 3,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                unawaited(
                                  Clipboard.setData(
                                    ClipboardData(text: prompt!.userCode),
                                  ),
                                );
                              },
                              child: const Text('复制代码'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () {
                          final opener =
                              widget.urlOpener ?? launchExternalOfficialUrl;
                          unawaited(opener(Uri.parse(prompt!.verificationUri)));
                        },
                        icon: const Icon(CupertinoIcons.globe, size: 15),
                        label: Text('打开 ${prompt!.verificationUri}'),
                      ),
                    ],
                    if (!finished) ...[
                      const SizedBox(height: 14),
                      const LinearProgressIndicator(minHeight: 2),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelToken.cancel();
                    Navigator.of(dialogCtx).pop();
                  },
                  child: const Text('取消'),
                ),
              ],
            );
          },
        );
      },
    );

    if (githubToken == null || !mounted) return;
    final preset = findAiProviderPreset('github_copilot')!;
    final existing = _service.profiles
        .where((p) => p.authMode == AiAuthMode.githubCopilotDeviceFlow)
        .firstOrNull;
    final profile = (existing ??
            AiProviderProfile.fromPreset(
              preset,
              id: 'copilot_device_${DateTime.now().millisecondsSinceEpoch}',
            ))
        .copyWith(
      authMode: AiAuthMode.githubCopilotDeviceFlow,
      baseUrl: GitHubCopilotDeviceFlow.defaultApiBaseUrl,
      accountLabel: 'GitHub Copilot',
    );
    await _service.saveProfile(
      profile,
      secret: githubToken,
      activate: true,
      enableAiWhenActivating: true,
    );
    await _syncEditorsFromActiveProfile();
    if (!mounted) return;
    setState(() {
      _statusNotice = 'GitHub Copilot 登录成功，令牌已写入本机加密存储并自动管理短期会话';
    });
  }

  Future<void> _discoverLocalModels() async {
    if (_discoveringLocal) return;
    setState(() {
      _discoveringLocal = true;
      _localDiscoveryNote = '正在扫描本机 Ollama (11434) 与 LM Studio (1234)…';
    });
    try {
      final results = await AiLocalDiscovery.discover(
        httpClient: widget.discoveryHttpClient,
      );
      if (!mounted) return;
      setState(() {
        _localResults = results;
        _localDiscoveryNote = results.isEmpty
            ? '未在本机 11434 / 1234 端口检测到运行中的 Ollama 或 LM Studio 服务'
            : '发现 ${results.length} 个本机离线推理服务，点击下方模型即可一键导入使用';
      });
    } finally {
      if (mounted) {
        setState(() => _discoveringLocal = false);
      }
    }
  }

  Future<void> _importLocalModel(
    AiLocalDiscoveryResult runtime,
    String modelId,
  ) async {
    final profile = AiProviderProfile(
      id: 'local_${runtime.providerId}_${DateTime.now().millisecondsSinceEpoch}',
      name: '${runtime.providerName} ($modelId)',
      presetId: runtime.providerId,
      protocol: AiApiProtocol.openaiCompatible,
      authMode: AiAuthMode.localNoAuth,
      baseUrl: runtime.baseUrl,
      model: modelId,
      fastModel: modelId,
      accountLabel: '本机离线推理',
    );
    await _service.saveProfile(
      profile,
      secret: '',
      activate: true,
      enableAiWhenActivating: true,
    );
    await _syncEditorsFromActiveProfile();
    if (!mounted) return;
    setState(() {
      _fetchedModels = runtime.models;
      _statusNotice = '已导入本机模型 $modelId（免 API Key）并启用 AI 实验室';
    });
  }

  Future<void> _fetchModelsForCurrentEditor() async {
    if (_fetchingModels) return;
    setState(() {
      _fetchingModels = true;
      _modelsError = null;
    });
    try {
      final draftConfig = _service.config.copyWith(
        protocol: _editingProtocol,
        baseUrl: _baseUrlCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        fastModel: _fastModelCtrl.text.trim(),
      );
      final models = await _service.fetchAvailableModels(
        configOverride: draftConfig,
        apiKeyOverride: _apiKeyCtrl.text.trim(),
        authModeOverride: _editingAuthMode,
      );
      if (!mounted) return;
      setState(() {
        _fetchedModels = models;
        if (models.isEmpty) {
          _modelsError = '服务返回了空的模型列表，请手动填写模型 ID';
        } else {
          if (_modelCtrl.text.trim().isEmpty) {
            _modelCtrl.text = models.first;
          }
          _statusNotice = '成功拉取 ${models.length} 个可用模型，点击标签即可填入';
        }
      });
    } on AiServiceException catch (e) {
      if (!mounted) return;
      setState(() => _modelsError = e.messageZh);
    } catch (e) {
      if (!mounted) return;
      setState(() => _modelsError = redactAiSecret(e.toString()));
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  Future<void> _runTestConnection() async {
    if (_testingConnection) return;
    await _saveCurrentEditor(showToast: false);
    setState(() {
      _testingConnection = true;
      _testResult = null;
    });
    try {
      final draftConfig = _service.config.copyWith(
        protocol: _editingProtocol,
        baseUrl: _baseUrlCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        fastModel: _fastModelCtrl.text.trim(),
      );
      final res = await _service.testConnection(
        configOverride: draftConfig,
        apiKeyOverride: _apiKeyCtrl.text.trim(),
        authModeOverride: _editingAuthMode,
      );
      if (!mounted) return;
      setState(() => _testResult = res);
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }

  Widget _buildLockedGate(BuildContext context) {
    final isDark = winDark(context);
    final border = winSurfaceBorder(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WinSettingsGroup(
          header: 'AI 实验室 · Ed25519 离线口令解锁',
          footer:
              '口令采用 RFC 8032 Ed25519 非对称离线签名校验，全程在本机完成验证，无需登录任何官方云账号，也不会向第三方上报你的设备信息。',
          children: [
            Padding(
              key: const ValueKey('windows-ai-lab-lock-card'),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: winAccent(context).withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          CupertinoIcons.lock_shield_fill,
                          color: winAccent(context),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '实验性功能 · 输入离线签名口令解锁',
                              style: TextStyle(
                                color: winInk(context),
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '支持 OpenRouter PKCE / GitHub Copilot 设备码 / 本地 Ollama & LM Studio / 多服务商 BYOK，兼容全平台统一 MMAILAB1 离线签名口令。',
                              style: TextStyle(
                                color: winMuted(context),
                                fontSize: 12.2,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('windows-ai-lab-passcode-input'),
                    controller: _passcodeCtrl,
                    maxLines: 3,
                    minLines: 2,
                    style: TextStyle(
                      color: winInk(context),
                      fontFamily: 'Consolas',
                      fontSize: 12.5,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Ed25519 离线签名口令',
                      hintText: '粘贴形如 MMAILAB1.<payload>.<signature> 的口令',
                      filled: true,
                      fillColor: isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.03),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: border),
                      ),
                    ),
                    onSubmitted: (_) => _handleUnlock(),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      WinButton(
                        _unlocking ? '正在验签…' : '验证并解锁',
                        key: const ValueKey('windows-ai-lab-unlock-btn'),
                        selected: true,
                        icon: CupertinoIcons.checkmark_shield,
                        onPressed: _unlocking ? null : _handleUnlock,
                      ),
                      WinButton(
                        '从剪贴板粘贴',
                        key: const ValueKey('windows-ai-lab-paste-btn'),
                        icon: CupertinoIcons.doc_on_clipboard,
                        onPressed: _unlocking ? null : _pastePasscode,
                      ),
                    ],
                  ),
                  if (_passcodeStatus != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _passcodeStatus!,
                      key: const ValueKey('windows-ai-lab-passcode-status'),
                      style: TextStyle(
                        color: _passcodeStatusError
                            ? AppleColors.systemOrange
                            : AppleColors.systemGreen,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        WinSettingsGroup(
          header: '解锁后可用的一期实验能力',
          children: const [
            WinSettingsRow(
              title: '1. 多服务商订阅与本地模型中心',
              subtitle:
                  '支持 OpenRouter PKCE 授权、GitHub Copilot 官方设备码登录、本地 Ollama / LM Studio 自动发现与任意 BYOK 兼容接口',
              icon: CupertinoIcons.layers_alt,
            ),
            WinSettingsRow(
              title: '2. AI 自然语言找片',
              subtitle: '在搜索页用剧情/风格/模糊记忆描述找片，一键在你的已配置片源中检索',
              icon: CupertinoIcons.search,
            ),
            WinSettingsRow(
              title: '3. 网盘/混乱选集智能净化',
              subtitle: '在详情页一键整理压制组乱码文件名，提取规范片名与季集标识，不阻塞起播',
              icon: CupertinoIcons.wand_stars,
            ),
            WinSettingsRow(
              title: '4. AI 为你挑片（按需个性化推荐）',
              subtitle: '仅在主动点击时基于公开观看历史与收藏推荐好片，隐私空间全程硬性阻断',
              icon: CupertinoIcons.sparkles,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTextField({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    final isDark = winDark(context);
    final border = winSurfaceBorder(context);
    return TextField(
      key: key,
      controller: controller,
      obscureText: obscureText,
      style: TextStyle(color: winInk(context), fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffixIcon,
        isDense: true,
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_passcodeStore.isUnlocked) {
      return _buildLockedGate(context);
    }

    final cfg = _service.config;
    final usage = _service.monthlyUsage;
    final payload = _passcodeStore.activePayload;
    final tagParts = <String>[
      'Ed25519 离线口令已解锁',
      if (payload != null && payload.tag.isNotEmpty) payload.tag,
      if (payload?.shared == true) '频道通用',
      if (payload?.experimentalOAuth == true) '实验 OAuth 权限',
    ];
    final unlockTag = tagParts.join(' · ');
    final isLocalEndpoint = _editingAuthMode == AiAuthMode.localNoAuth ||
        isLoopbackAiBaseUrl(_baseUrlCtrl.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WinPanel(
          key: const ValueKey('windows-ai-lab-unlocked-bar'),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              const Icon(
                CupertinoIcons.checkmark_seal_fill,
                color: AppleColors.systemGreen,
                size: 20,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      unlockTag,
                      style: TextStyle(
                        color: winInk(context),
                        fontSize: 13.8,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '所有密钥均由 Windows 系统凭据库加密保管 · 隐私空间硬性禁网 · 严格禁止模型返回外部播放链接',
                      style: TextStyle(color: winMuted(context), fontSize: 11.8),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              WinButton(
                '重新锁定',
                key: const ValueKey('windows-ai-lab-relock-btn'),
                icon: CupertinoIcons.lock,
                onPressed: () async {
                  await _passcodeStore.lock();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        WinSettingsGroup(
          header: 'AI 实验室总控',
          children: [
            WinSettingsRow(
              key: const ValueKey('windows-ai-lab-enable-row'),
              title: '启用 AI 实验室',
              subtitle: _service.isConfigured
                  ? '当前就绪：${_service.activeProfile?.name ?? cfg.protocol.labelZh} · ${cfg.model}'
                  : '开启并完成下方任一服务商接入后，即可在搜索、详情页与「我的」中使用 AI 能力',
              icon: CupertinoIcons.sparkles,
              trailing: CupertinoSwitch(
                key: const ValueKey('windows-ai-lab-enable-switch'),
                value: cfg.enabled,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await _service.saveConfig(cfg.copyWith(enabled: v));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        WinSettingsGroup(
          header: '订阅账号与多服务商接入',
          footer:
              '仅采用各平台官方公开的 OAuth / 设备码授权、标准 API Key 与本机回环离线模型，不伪装或逆向第三方客户端。',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      WinButton(
                        'OpenRouter 一键授权',
                        key: const ValueKey('win-ai-openrouter-oauth-btn'),
                        icon: CupertinoIcons.bolt_circle,
                        onPressed: _startOpenRouterOAuth,
                      ),
                      WinButton(
                        'GitHub Copilot 登录',
                        key: const ValueKey('win-ai-copilot-device-btn'),
                        icon: CupertinoIcons.device_laptop,
                        onPressed: _startGitHubCopilotDeviceFlow,
                      ),
                      WinButton(
                        _discoveringLocal ? '扫描本机中…' : '发现本地模型',
                        key: const ValueKey('win-ai-discover-local-btn'),
                        icon: CupertinoIcons.desktopcomputer,
                        onPressed:
                            _discoveringLocal ? null : _discoverLocalModels,
                      ),
                      WinButton(
                        '添加 API 服务商',
                        key: const ValueKey('win-ai-add-provider-btn'),
                        selected: true,
                        icon: CupertinoIcons.add,
                        onPressed: _openAddProviderPresetDialog,
                      ),
                    ],
                  ),
                  if (_localDiscoveryNote != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _localDiscoveryNote!,
                      key: const ValueKey('win-ai-local-discovery-note'),
                      style: TextStyle(color: winMuted(context), fontSize: 12),
                    ),
                  ],
                  if (_localResults.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    for (final runtime in _localResults)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: winSurfaceBorder(context)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${runtime.providerName} · ${runtime.baseUrl}',
                                style: TextStyle(
                                  color: winInk(context),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12.8,
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (runtime.models.isEmpty)
                                WinButton(
                                  '导入 ${runtime.providerName}',
                                  onPressed: () =>
                                      _importLocalModel(runtime, 'local-model'),
                                )
                              else
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final m in runtime.models.take(12))
                                      WinButton(
                                        '使用 $m',
                                        key: ValueKey('win-ai-local-model-$m'),
                                        onPressed: () =>
                                            _importLocalModel(runtime, m),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  if (_service.profiles.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      '已配置服务商实例（点击一键热切）',
                      style: TextStyle(
                        color: winMuted(context),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final profile in _service.profiles)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Container(
                          key: ValueKey('win-ai-profile-${profile.id}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: profile.id == cfg.activeProfileId
                                ? winAccent(context).withValues(alpha: 0.12)
                                : Colors.transparent,
                            border: Border.all(
                              color: profile.id == cfg.activeProfileId
                                  ? winAccent(context)
                                  : winSurfaceBorder(context),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${profile.name} · ${profile.authMode.labelZh}',
                                      style: TextStyle(
                                        color: winInk(context),
                                        fontSize: 13.2,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${profile.model.isEmpty ? "未选模型" : profile.model} · ${profile.baseUrl}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: winMuted(context),
                                        fontSize: 11.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              WinButton(
                                profile.id == cfg.activeProfileId ? '当前使用' : '切换',
                                selected: profile.id == cfg.activeProfileId,
                                onPressed: profile.id == cfg.activeProfileId
                                    ? null
                                    : () => _switchProfile(profile),
                              ),
                              const SizedBox(width: 6),
                              IconButton(
                                tooltip: '删除该服务商',
                                icon: Icon(
                                  CupertinoIcons.trash,
                                  size: 16,
                                  color: winMuted(context),
                                ),
                                onPressed: () => _deleteProfile(profile),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        WinSettingsGroup(
          header: '当前连接参数与双档模型路由',
          footer:
              '主推理模型用于自然语言找片与为你挑片；轻量高速模型用于网盘/混乱选集批量净化（留空时自动复用主模型）。',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final proto in AiApiProtocol.values)
                        WinButton(
                          proto.labelZh,
                          key: ValueKey('win-ai-proto-${proto.id}'),
                          selected: _editingProtocol == proto,
                          onPressed: () =>
                              setState(() => _editingProtocol = proto),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildTextField(
                    key: const ValueKey('win-ai-profile-name-input'),
                    controller: _profileNameCtrl,
                    label: '服务商备注名',
                    hint: '如：DeepSeek / OpenRouter / 本机 Ollama',
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    key: const ValueKey('win-ai-base-url-input'),
                    controller: _baseUrlCtrl,
                    label: '接口地址 (Base URL)',
                    hint: '如：https://api.deepseek.com/v1 或 http://127.0.0.1:11434/v1',
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    key: const ValueKey('win-ai-api-key-input'),
                    controller: _apiKeyCtrl,
                    label: _editingAuthMode == AiAuthMode.githubCopilotDeviceFlow
                        ? 'GitHub Copilot OAuth 令牌（自动管理）'
                        : isLocalEndpoint
                            ? 'API 密钥（本机回环可留空）'
                            : 'API 密钥（仅存本机系统加密凭据库）',
                    hint: isLocalEndpoint ? '本机 Ollama / LM Studio 无需填写' : 'sk-...',
                    obscureText: _obscureApiKey,
                    suffixIcon: IconButton(
                      tooltip: _obscureApiKey ? '显示密钥' : '隐藏密钥',
                      icon: Icon(
                        _obscureApiKey
                            ? CupertinoIcons.eye
                            : CupertinoIcons.eye_slash,
                        size: 16,
                      ),
                      onPressed: () =>
                          setState(() => _obscureApiKey = !_obscureApiKey),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          key: const ValueKey('win-ai-model-input'),
                          controller: _modelCtrl,
                          label: '主推理模型 (Main)',
                          hint: '如：deepseek-chat / gpt-4o-mini',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildTextField(
                          key: const ValueKey('win-ai-fast-model-input'),
                          controller: _fastModelCtrl,
                          label: '轻量高速模型 (Fast，可选)',
                          hint: '留空自动复用主模型',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      WinButton(
                        '保存配置',
                        key: const ValueKey('win-ai-save-config-btn'),
                        selected: true,
                        icon: CupertinoIcons.checkmark_alt,
                        onPressed: _saveCurrentEditor,
                      ),
                      WinButton(
                        _fetchingModels ? '拉取中…' : '拉取可用模型',
                        key: const ValueKey('win-ai-fetch-models-btn'),
                        icon: CupertinoIcons.arrow_2_circlepath,
                        onPressed:
                            _fetchingModels ? null : _fetchModelsForCurrentEditor,
                      ),
                      WinButton(
                        _testingConnection ? '测试中…' : '测试连接',
                        key: const ValueKey('win-ai-test-conn-btn'),
                        icon: CupertinoIcons.antenna_radiowaves_left_right,
                        onPressed: _testingConnection ? null : _runTestConnection,
                      ),
                    ],
                  ),
                  if (_modelsError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _modelsError!,
                      style: const TextStyle(
                        color: AppleColors.systemOrange,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (_fetchedModels.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      '可用模型（点击填入主模型）：',
                      style: TextStyle(color: winMuted(context), fontSize: 11.8),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final m in _fetchedModels.take(18))
                          ActionChip(
                            label: Text(m, style: const TextStyle(fontSize: 11.5)),
                            onPressed: () {
                              setState(() {
                                _modelCtrl.text = m;
                                if (_fastModelCtrl.text.trim().isEmpty) {
                                  _fastModelCtrl.text = m;
                                }
                              });
                            },
                          ),
                      ],
                    ),
                  ],
                  if (_testResult != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _testResult!.messageZh,
                      key: const ValueKey('win-ai-test-result'),
                      style: TextStyle(
                        color: _testResult!.ok
                            ? AppleColors.systemGreen
                            : AppleColors.systemOrange,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if (_statusNotice != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _statusNotice!,
                      style: TextStyle(color: winAccent(context), fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        WinSettingsGroup(
          header: '一期实验功能开关',
          children: [
            WinSettingsRow(
              title: 'AI 自然语言找片',
              subtitle: '在搜索页使用自然语言描述剧情、情绪或记忆片段，自动匹配你的片源',
              icon: CupertinoIcons.search,
              trailing: CupertinoSwitch(
                key: const ValueKey('win-ai-toggle-nl-search'),
                value: cfg.nlSearchEnabled,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await _service.saveConfig(cfg.copyWith(nlSearchEnabled: v));
                },
              ),
            ),
            WinSettingsRow(
              title: '网盘/混乱选集智能净化',
              subtitle: '在详情页整理杂乱压制组文件名并提取季集标识（使用轻量模型，自动缓存）',
              icon: CupertinoIcons.wand_stars,
              trailing: CupertinoSwitch(
                key: const ValueKey('win-ai-toggle-title-cleanup'),
                value: cfg.titleCleanupEnabled,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await _service
                      .saveConfig(cfg.copyWith(titleCleanupEnabled: v));
                },
              ),
            ),
            WinSettingsRow(
              title: 'AI 为你挑片（按需个性化推荐）',
              subtitle: '主动触发时仅发送去重后的公开观看记录与收藏片名，绝不读取隐私空间',
              icon: CupertinoIcons.sparkles,
              trailing: CupertinoSwitch(
                key: const ValueKey('win-ai-toggle-picks'),
                value: cfg.picksEnabled,
                activeTrackColor: AppleColors.systemGreen,
                onChanged: (v) async {
                  await _service.saveConfig(cfg.copyWith(picksEnabled: v));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        WinSettingsGroup(
          header: '本月用量限额与本地缓存',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '本月统计（${usage.monthKey}）：已调用 ${usage.requestCount} 次 · 约 ${usage.totalTokens} Tokens · 本地缓存 ${_service.cachedEntryCount} 条',
                          style: TextStyle(color: winMuted(context), fontSize: 12.2),
                        ),
                      ),
                      WinButton(
                        '清空缓存',
                        key: const ValueKey('win-ai-clear-cache-btn'),
                        onPressed: () async {
                          await _service.clearCache();
                          AiTitleCleaner.instance.clearMemoryCache();
                          if (mounted) {
                            setState(() => _statusNotice = '已清空本地 AI 响应与标题净化缓存');
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in _budgetPresets)
                        WinButton(
                          preset.$2,
                          key: ValueKey('win-ai-budget-${preset.$1}'),
                          selected: cfg.monthlyTokenBudget == preset.$1,
                          onPressed: () async {
                            await _service.saveConfig(
                              cfg.copyWith(monthlyTokenBudget: preset.$1),
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Opens the desktop dialog for Feature #2: AI Natural-Language Movie Search.
Future<void> showWindowsAiSearchDialog(
  BuildContext context, {
  required ValueChanged<String> onPickTitle,
  VoidCallback? onOpenSettings,
  AiService? service,
  bool isPrivateSession = false,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => _WindowsAiSearchDialog(
      service: service ?? AiService.instance,
      isPrivateSession: isPrivateSession,
      onPickTitle: (title) {
        Navigator.of(dialogCtx).pop();
        onPickTitle(title);
      },
      onOpenSettings: onOpenSettings == null
          ? null
          : () {
              Navigator.of(dialogCtx).pop();
              onOpenSettings();
            },
    ),
  );
}

class _WindowsAiSearchDialog extends StatefulWidget {
  final AiService service;
  final bool isPrivateSession;
  final ValueChanged<String> onPickTitle;
  final VoidCallback? onOpenSettings;

  const _WindowsAiSearchDialog({
    required this.service,
    required this.isPrivateSession,
    required this.onPickTitle,
    this.onOpenSettings,
  });

  @override
  State<_WindowsAiSearchDialog> createState() => _WindowsAiSearchDialogState();
}

class _WindowsAiSearchDialogState extends State<_WindowsAiSearchDialog> {
  final TextEditingController _queryCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  List<AiMovieCandidate> _candidates = const <AiMovieCandidate>[];

  static const List<String> _examples = <String>[
    '高分硬科幻太空探索电影',
    '多线反转不断的悬疑英美短剧',
    '适合周末放松的温柔治愈日剧',
  ];

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit([String? preset]) async {
    if (preset != null) {
      _queryCtrl.text = preset;
    }
    final q = _queryCtrl.text.trim();
    if (q.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.service.suggestSearchCandidates(
        q,
        isPrivateSession: widget.isPrivateSession,
      );
      if (!mounted) return;
      setState(() {
        _candidates = list;
        if (list.isEmpty) {
          _error = '暂未匹配到候选影片，请换一种描述试试';
        }
      });
    } on AiServiceException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.messageZh);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = redactAiSecret(e.toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF151B24) : const Color(0xFFFAFBFD);
    final border = isDark ? const Color(0x26FFFFFF) : const Color(0x1A0F172A);
    final ink = isDark ? const Color(0xFFF2F5FA) : const Color(0xFF131B26);
    final muted = isDark ? const Color(0xFFA7B4C7) : const Color(0xFF556377);
    final ready = widget.service.isConfigured &&
        widget.service.config.nlSearchEnabled &&
        !widget.isPrivateSession;

    return Dialog(
      key: const ValueKey('windows-ai-search-dialog'),
      backgroundColor: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(CupertinoIcons.sparkles, size: 19),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AI 自然语言找片',
                      style: TextStyle(
                        color: ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(CupertinoIcons.xmark, size: 16, color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '用自然语言描述剧情、年代或观影氛围，AI 给出标准片名候选后，直接在你的已配置片源中搜索。',
                style: TextStyle(color: muted, fontSize: 12.4),
              ),
              const SizedBox(height: 14),
              if (!ready) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isPrivateSession
                            ? '隐私空间已硬性禁用所有外部 AI 请求。'
                            : '请先在「设置 → AI 实验室」开启总开关并配置任一 AI 服务商或本机模型。',
                        style: TextStyle(color: ink, fontSize: 13),
                      ),
                      if (!widget.isPrivateSession &&
                          widget.onOpenSettings != null) ...[
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: widget.onOpenSettings,
                          child: const Text('前往 AI 实验室配置'),
                        ),
                      ],
                    ],
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('windows-ai-search-query-input'),
                        controller: _queryCtrl,
                        autofocus: true,
                        style: TextStyle(color: ink, fontSize: 13.5),
                        decoration: InputDecoration(
                          hintText: '例如：讲述时间循环的高口碑科幻片',
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      key: const ValueKey('windows-ai-search-submit-btn'),
                      onPressed: _loading ? null : _submit,
                      child: Text(_loading ? '思考中…' : 'AI 找片'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final sample in _examples)
                      ActionChip(
                        label: Text(sample, style: const TextStyle(fontSize: 11.5)),
                        onPressed: _loading ? null : () => _submit(sample),
                      ),
                  ],
                ),
                if (_loading) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(minHeight: 2),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: AppleColors.systemOrange,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                if (_candidates.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _candidates.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final item = _candidates[i];
                        return Container(
                          key: ValueKey('win-ai-search-candidate-$i'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: border),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.year.isNotEmpty
                                          ? '${item.title} (${item.year})'
                                          : item.title,
                                      style: TextStyle(
                                        color: ink,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13.8,
                                      ),
                                    ),
                                    if (item.reason.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        item.reason,
                                        style: TextStyle(
                                          color: muted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                key: ValueKey('win-ai-search-pick-$i'),
                                onPressed: () => widget.onPickTitle(item.title),
                                child: const Text('搜片源'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the desktop dialog for Feature #4: On-Demand Personalized AI Picks.
Future<void> showWindowsAiPicksDialog(
  BuildContext context, {
  required List<String> recentTitles,
  required List<String> favoriteTitles,
  required ValueChanged<String> onPickTitle,
  VoidCallback? onOpenSettings,
  AiService? service,
  bool isPrivateSession = false,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => _WindowsAiPicksDialog(
      service: service ?? AiService.instance,
      recentTitles: recentTitles,
      favoriteTitles: favoriteTitles,
      isPrivateSession: isPrivateSession,
      onPickTitle: (title) {
        Navigator.of(dialogCtx).pop();
        onPickTitle(title);
      },
      onOpenSettings: onOpenSettings == null
          ? null
          : () {
              Navigator.of(dialogCtx).pop();
              onOpenSettings();
            },
    ),
  );
}

class _WindowsAiPicksDialog extends StatefulWidget {
  final AiService service;
  final List<String> recentTitles;
  final List<String> favoriteTitles;
  final bool isPrivateSession;
  final ValueChanged<String> onPickTitle;
  final VoidCallback? onOpenSettings;

  const _WindowsAiPicksDialog({
    required this.service,
    required this.recentTitles,
    required this.favoriteTitles,
    required this.isPrivateSession,
    required this.onPickTitle,
    this.onOpenSettings,
  });

  @override
  State<_WindowsAiPicksDialog> createState() => _WindowsAiPicksDialogState();
}

class _WindowsAiPicksDialogState extends State<_WindowsAiPicksDialog> {
  final TextEditingController _moodCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  List<AiMovieCandidate> _picks = const <AiMovieCandidate>[];

  @override
  void dispose() {
    _moodCtrl.dispose();
    super.dispose();
  }

  Future<void> _generate({bool bypassCache = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.service.suggestPersonalizedRecommendations(
        recentTitles: widget.recentTitles,
        favoriteTitles: widget.favoriteTitles,
        moodHint: _moodCtrl.text.trim(),
        isPrivateSession: widget.isPrivateSession,
        bypassCache: bypassCache,
      );
      if (!mounted) return;
      setState(() {
        _picks = list;
        if (list.isEmpty) {
          _error = '暂未生成推荐，请稍后重试';
        }
      });
    } on AiServiceException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.messageZh);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = redactAiSecret(e.toString()));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF151B24) : const Color(0xFFFAFBFD);
    final border = isDark ? const Color(0x26FFFFFF) : const Color(0x1A0F172A);
    final ink = isDark ? const Color(0xFFF2F5FA) : const Color(0xFF131B26);
    final muted = isDark ? const Color(0xFFA7B4C7) : const Color(0xFF556377);
    final ready = widget.service.isConfigured &&
        widget.service.config.picksEnabled &&
        !widget.isPrivateSession;

    return Dialog(
      key: const ValueKey('windows-ai-picks-dialog'),
      backgroundColor: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(CupertinoIcons.sparkles, size: 19),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AI 为你挑片',
                      style: TextStyle(
                        color: ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(CupertinoIcons.xmark, size: 16, color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '按需触发：仅将去重后的 ${widget.recentTitles.take(8).length} 条公开近期观看与 ${widget.favoriteTitles.take(8).length} 条公开收藏片名发送给你配置的模型，不涉及隐私空间。',
                style: TextStyle(color: muted, fontSize: 12.2),
              ),
              const SizedBox(height: 14),
              if (!ready) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isPrivateSession
                            ? '隐私空间已硬性禁用 AI 为你挑片。'
                            : '请先在「设置 → AI 实验室」开启总开关并配置 AI 服务商。',
                        style: TextStyle(color: ink, fontSize: 13),
                      ),
                      if (!widget.isPrivateSession &&
                          widget.onOpenSettings != null) ...[
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: widget.onOpenSettings,
                          child: const Text('前往 AI 实验室配置'),
                        ),
                      ],
                    ],
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('windows-ai-picks-mood-input'),
                        controller: _moodCtrl,
                        style: TextStyle(color: ink, fontSize: 13.5),
                        decoration: InputDecoration(
                          hintText: '可选：补充今晚想看的氛围（如：节奏紧凑 / 轻松喜剧）',
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onSubmitted: (_) => _generate(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      key: const ValueKey('windows-ai-picks-generate-btn'),
                      onPressed: _loading ? null : () => _generate(),
                      child: Text(_loading ? '挑片中…' : '生成推荐'),
                    ),
                    if (_picks.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed:
                            _loading ? null : () => _generate(bypassCache: true),
                        child: const Text('换一批'),
                      ),
                    ],
                  ],
                ),
                if (_loading) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(minHeight: 2),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: AppleColors.systemOrange,
                      fontSize: 12.5,
                    ),
                  ),
                ],
                if (_picks.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _picks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final item = _picks[i];
                        return Container(
                          key: ValueKey('win-ai-picks-item-$i'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: border),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.year.isNotEmpty
                                          ? '${item.title} (${item.year})'
                                          : item.title,
                                      style: TextStyle(
                                        color: ink,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13.8,
                                      ),
                                    ),
                                    if (item.reason.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Text(
                                        item.reason,
                                        style: TextStyle(
                                          color: muted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                key: ValueKey('win-ai-picks-select-$i'),
                                onPressed: () => widget.onPickTitle(item.title),
                                child: const Text('搜片源'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
