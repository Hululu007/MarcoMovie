// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ai_service.dart';

/// Authentication / subscription connection mode inspired by OpenMinis's
/// multi-provider architecture, restricted strictly to official documented
/// OAuth/Device flows, standard BYOK API keys, and local loopback services.
enum AiAuthMode {
  apiKey('api_key', 'API Key'),
  codexOAuth('codex_oauth', 'GPT 订阅账号登录'),
  openRouterOAuth('openrouter_oauth', 'OpenRouter PKCE 授权'),
  githubCopilotDeviceFlow('github_copilot_device', 'GitHub Copilot 登录'),
  localNoAuth('local_no_auth', '本地免密服务');

  final String id;
  final String labelZh;

  const AiAuthMode(this.id, this.labelZh);

  static AiAuthMode fromId(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    for (final mode in AiAuthMode.values) {
      if (mode.id == normalized) return mode;
    }
    return AiAuthMode.apiKey;
  }
}

/// Returns `true` when [baseUrl] points strictly to a local loopback interface
/// (`127.0.0.1`, `localhost`, or `::1`), allowing zero-key local inference
/// engines such as Ollama and LM Studio.
bool isLoopbackAiBaseUrl(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host.trim().toLowerCase();
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}

/// Sanitizes diagnostic strings so API keys, OAuth tokens, or authorization
/// headers are never surfaced in UI toasts or logs.
String redactAiSecret(String input) {
  if (input.isEmpty) return input;
  var out = input;
  out = out.replaceAll(
    RegExp(r'\bsk-(?:or-v1-|ant-|proj-)?[A-Za-z0-9_\-]{8,}'),
    '[REDACTED]',
  );
  out = out.replaceAll(
    RegExp(r'\bgh[pousr]_[A-Za-z0-9]{10,}'),
    '[REDACTED]',
  );
  out = out.replaceAll(
    RegExp(r'\bAIza[0-9A-Za-z\-_]{16,}'),
    '[REDACTED]',
  );
  out = out.replaceAll(
    RegExp(r'(Bearer\s+)[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
    r'$1[REDACTED]',
  );
  out = out.replaceAll(
    RegExp(
      r'((?:x-api-key|x-goog-api-key|api[_-]?key|access_token|token)\s*[:=]\s*)[^\s,;"}]+',
      caseSensitive: false,
    ),
    r'$1[REDACTED]',
  );
  return out;
}

/// Curated vendor preset for one-click profile creation.
///
/// NOTE: Presets are only templates shown when the user explicitly adds a
/// provider. Default app state always ships with zero active providers and an
/// empty active Base URL.
@immutable
class AiProviderPreset {
  final String id;
  final String name;
  final String description;
  final AiApiProtocol protocol;
  final AiAuthMode authMode;
  final String defaultBaseUrl;
  final String defaultModel;
  final String defaultFastModel;
  final List<String> suggestedModels;

  const AiProviderPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.protocol,
    required this.authMode,
    required this.defaultBaseUrl,
    required this.defaultModel,
    this.defaultFastModel = '',
    this.suggestedModels = const <String>[],
  });
}

const List<AiProviderPreset> kAiProviderPresets = <AiProviderPreset>[
  AiProviderPreset(
    id: 'openrouter',
    name: 'OpenRouter',
    description: '支持官方 PKCE 浏览器一键授权，聚合多款主流大模型',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.openRouterOAuth,
    defaultBaseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4o-mini',
    defaultFastModel: 'openai/gpt-4o-mini',
    suggestedModels: <String>[
      'openai/gpt-4o-mini',
      'anthropic/claude-3.5-haiku',
      'google/gemini-2.5-flash',
      'deepseek/deepseek-chat',
    ],
  ),
  AiProviderPreset(
    id: 'github_copilot',
    name: 'GitHub Copilot',
    description: '使用官方 GitHub 设备码 (RFC 8628) 登录已有 Copilot 订阅',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.githubCopilotDeviceFlow,
    defaultBaseUrl: 'https://api.githubcopilot.com',
    defaultModel: 'gpt-4o',
    defaultFastModel: 'gpt-4o-mini',
    suggestedModels: <String>[
      'gpt-4o',
      'gpt-4o-mini',
      'claude-3.5-sonnet',
    ],
  ),
  AiProviderPreset(
    id: 'ollama',
    name: '本地 Ollama',
    description: '本机离线推理（127.0.0.1:11434），无需 API Key',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.localNoAuth,
    defaultBaseUrl: 'http://127.0.0.1:11434/v1',
    defaultModel: 'qwen2.5:7b',
    defaultFastModel: 'qwen2.5:7b',
  ),
  AiProviderPreset(
    id: 'lm_studio',
    name: '本地 LM Studio',
    description: '本机 OpenAI 兼容服务（127.0.0.1:1234），无需 API Key',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.localNoAuth,
    defaultBaseUrl: 'http://127.0.0.1:1234/v1',
    defaultModel: 'local-model',
    defaultFastModel: 'local-model',
  ),
  AiProviderPreset(
    id: 'deepseek',
    name: 'DeepSeek',
    description: 'DeepSeek 官方 OpenAI 兼容接口',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    defaultFastModel: 'deepseek-chat',
    suggestedModels: <String>['deepseek-chat', 'deepseek-reasoner'],
  ),
  AiProviderPreset(
    id: 'dashscope',
    name: '通义千问 DashScope',
    description: '阿里云百炼 OpenAI 兼容接口',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    defaultFastModel: 'qwen-turbo',
    suggestedModels: <String>['qwen-plus', 'qwen-turbo', 'qwen-max'],
  ),
  AiProviderPreset(
    id: 'moonshot',
    name: 'Kimi Moonshot',
    description: '月之暗面 Kimi 官方 API',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
    defaultFastModel: 'moonshot-v1-8k',
    suggestedModels: <String>['moonshot-v1-8k', 'kimi-k2-0711-preview'],
  ),
  AiProviderPreset(
    id: 'siliconflow',
    name: '硅基流动 SiliconFlow',
    description: 'SiliconFlow 托管开源模型接口',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'Qwen/Qwen2.5-7B-Instruct',
    defaultFastModel: 'Qwen/Qwen2.5-7B-Instruct',
  ),
  AiProviderPreset(
    id: 'bigmodel',
    name: '智谱 BigModel',
    description: '智谱 GLM 开放平台接口',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4-flash',
    defaultFastModel: 'glm-4-flash',
  ),
  AiProviderPreset(
    id: 'openai',
    name: 'OpenAI',
    description: 'OpenAI 官方 API',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
    defaultFastModel: 'gpt-4o-mini',
    suggestedModels: <String>['gpt-4o-mini', 'gpt-4o', 'gpt-4.1-mini'],
  ),
  AiProviderPreset(
    id: 'anthropic',
    name: 'Anthropic Claude',
    description: 'Anthropic Messages 官方 API',
    protocol: AiApiProtocol.anthropicMessages,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://api.anthropic.com',
    defaultModel: 'claude-3-5-haiku-latest',
    defaultFastModel: 'claude-3-5-haiku-latest',
    suggestedModels: <String>[
      'claude-3-5-haiku-latest',
      'claude-3-7-sonnet-latest',
    ],
  ),
  AiProviderPreset(
    id: 'gemini',
    name: 'Google Gemini',
    description: 'Google AI Studio Gemini 官方 API',
    protocol: AiApiProtocol.geminiGenerateContent,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    defaultModel: 'gemini-2.5-flash',
    defaultFastModel: 'gemini-2.5-flash',
    suggestedModels: <String>['gemini-2.5-flash', 'gemini-2.5-pro'],
  ),
  AiProviderPreset(
    id: 'custom',
    name: '自定义兼容接口',
    description: '支持任意 OpenAI / Anthropic / Gemini 兼容服务或私有网关',
    protocol: AiApiProtocol.openaiCompatible,
    authMode: AiAuthMode.apiKey,
    defaultBaseUrl: '',
    defaultModel: '',
    defaultFastModel: '',
  ),
];

AiProviderPreset? findAiProviderPreset(String id) {
  final target = id.trim().toLowerCase();
  for (final preset in kAiProviderPresets) {
    if (preset.id == target) return preset;
  }
  return null;
}

/// Non-secret metadata for a single configured AI provider instance.
///
/// Secrets (API keys or OAuth access tokens) are stored exclusively in
/// [SecureStorageBackend] keyed by `marco_ai_profile_secret_<id>`.
@immutable
class AiProviderProfile {
  final String id;
  final String name;
  final String presetId;
  final AiApiProtocol protocol;
  final AiAuthMode authMode;
  final String baseUrl;
  final String model;
  final String fastModel;
  final String accountLabel;
  final int createdAtMs;
  final int updatedAtMs;

  const AiProviderProfile({
    required this.id,
    required this.name,
    this.presetId = 'custom',
    this.protocol = AiApiProtocol.openaiCompatible,
    this.authMode = AiAuthMode.apiKey,
    this.baseUrl = '',
    this.model = '',
    this.fastModel = '',
    this.accountLabel = '',
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
  });

  bool get requiresApiKey =>
      authMode != AiAuthMode.localNoAuth && !isLoopbackAiBaseUrl(baseUrl);

  String get effectiveFastModel {
    final fast = fastModel.trim();
    return fast.isNotEmpty ? fast : model.trim();
  }

  AiProviderProfile copyWith({
    String? id,
    String? name,
    String? presetId,
    AiApiProtocol? protocol,
    AiAuthMode? authMode,
    String? baseUrl,
    String? model,
    String? fastModel,
    String? accountLabel,
    int? createdAtMs,
    int? updatedAtMs,
  }) {
    return AiProviderProfile(
      id: (id ?? this.id).trim(),
      name: (name ?? this.name).trim(),
      presetId: (presetId ?? this.presetId).trim(),
      protocol: protocol ?? this.protocol,
      authMode: authMode ?? this.authMode,
      baseUrl: (baseUrl ?? this.baseUrl).trim(),
      model: (model ?? this.model).trim(),
      fastModel: (fastModel ?? this.fastModel).trim(),
      accountLabel: (accountLabel ?? this.accountLabel).trim(),
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'presetId': presetId,
        'protocol': protocol.id,
        'authMode': authMode.id,
        'baseUrl': baseUrl,
        'model': model,
        'fastModel': fastModel,
        'accountLabel': accountLabel,
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
      };

  factory AiProviderProfile.fromJson(Map<String, dynamic> json) {
    return AiProviderProfile(
      id: (json['id'] ?? '').toString().trim(),
      name: (json['name'] ?? '').toString().trim(),
      presetId: (json['presetId'] ?? 'custom').toString().trim(),
      protocol: AiApiProtocol.fromId(json['protocol']?.toString()),
      authMode: AiAuthMode.fromId(json['authMode']?.toString()),
      baseUrl: (json['baseUrl'] ?? '').toString().trim(),
      model: (json['model'] ?? '').toString().trim(),
      fastModel: (json['fastModel'] ?? '').toString().trim(),
      accountLabel: (json['accountLabel'] ?? '').toString().trim(),
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  factory AiProviderProfile.fromPreset(
    AiProviderPreset preset, {
    required String id,
    String? customName,
    String? modelOverride,
    String? accountLabel,
    int? nowMs,
  }) {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return AiProviderProfile(
      id: id,
      name: (customName != null && customName.trim().isNotEmpty)
          ? customName.trim()
          : preset.name,
      presetId: preset.id,
      protocol: preset.protocol,
      authMode: preset.authMode,
      baseUrl: preset.defaultBaseUrl,
      model: (modelOverride != null && modelOverride.trim().isNotEmpty)
          ? modelOverride.trim()
          : preset.defaultModel,
      fastModel: preset.defaultFastModel,
      accountLabel: (accountLabel ?? '').trim(),
      createdAtMs: ts,
      updatedAtMs: ts,
    );
  }
}

/// Discovered local offline LLM runtime (Ollama / LM Studio).
@immutable
class AiLocalDiscoveryResult {
  final String providerId;
  final String providerName;
  final String baseUrl;
  final List<String> models;

  const AiLocalDiscoveryResult({
    required this.providerId,
    required this.providerName,
    required this.baseUrl,
    required this.models,
  });
}

/// Zero-config loopback scanner for local Ollama and LM Studio services.
abstract final class AiLocalDiscovery {
  static const String ollamaTagsUrl = 'http://127.0.0.1:11434/api/tags';
  static const String ollamaOpenAiBaseUrl = 'http://127.0.0.1:11434/v1';
  static const String lmStudioModelsUrl = 'http://127.0.0.1:1234/v1/models';
  static const String lmStudioOpenAiBaseUrl = 'http://127.0.0.1:1234/v1';

  static Future<List<AiLocalDiscoveryResult>> discover({
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final ephemeral = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final results = await Future.wait<AiLocalDiscoveryResult?>(
        <Future<AiLocalDiscoveryResult?>>[
          _probeOllama(client, timeout),
          _probeLmStudio(client, timeout),
        ],
      );
      return results.whereType<AiLocalDiscoveryResult>().toList(growable: false);
    } finally {
      if (ephemeral) client.close();
    }
  }

  static Future<AiLocalDiscoveryResult?> _probeOllama(
    http.Client client,
    Duration timeout,
  ) async {
    try {
      final resp = await client
          .get(
            Uri.parse(ollamaTagsUrl),
            headers: const <String, String>{'Accept': 'application/json'},
          )
          .timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      final models = <String>{};
      if (decoded is Map && decoded['models'] is List) {
        for (final item in decoded['models'] as List) {
          if (item is Map) {
            final name = (item['name'] ?? item['model'] ?? '').toString().trim();
            if (name.isNotEmpty) models.add(name);
          }
        }
      }
      final sorted = models.toList()..sort();
      return AiLocalDiscoveryResult(
        providerId: 'ollama',
        providerName: '本地 Ollama',
        baseUrl: ollamaOpenAiBaseUrl,
        models: List<String>.unmodifiable(sorted),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<AiLocalDiscoveryResult?> _probeLmStudio(
    http.Client client,
    Duration timeout,
  ) async {
    try {
      final resp = await client
          .get(
            Uri.parse(lmStudioModelsUrl),
            headers: const <String, String>{'Accept': 'application/json'},
          )
          .timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      final models = <String>{};
      if (decoded is Map && decoded['data'] is List) {
        for (final item in decoded['data'] as List) {
          if (item is Map) {
            final id = (item['id'] ?? '').toString().trim();
            if (id.isNotEmpty) models.add(id);
          }
        }
      }
      final sorted = models.toList()..sort();
      return AiLocalDiscoveryResult(
        providerId: 'lm_studio',
        providerName: '本地 LM Studio',
        baseUrl: lmStudioOpenAiBaseUrl,
        models: List<String>.unmodifiable(sorted),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Fetches available model IDs from OpenAI-compatible, Anthropic, Gemini, or
/// Ollama endpoints so users can pick models instead of typing IDs by hand.
abstract final class AiModelCatalogFetcher {
  static Future<List<String>> fetchModels({
    required AiApiProtocol protocol,
    required String baseUrl,
    String apiKey = '',
    AiAuthMode authMode = AiAuthMode.apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    var trimmed = baseUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final parsed = Uri.tryParse(trimmed);
    if (trimmed.isEmpty ||
        parsed == null ||
        !parsed.hasAuthority ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const AiServiceException(
        AiErrorCode.invalidEndpoint,
        '请先填写有效的接口地址 (Base URL)',
      );
    }

    final key = apiKey.trim();
    final isLocal =
        authMode == AiAuthMode.localNoAuth || isLoopbackAiBaseUrl(trimmed);
    if (!isLocal && key.isEmpty) {
      throw const AiServiceException(
        AiErrorCode.unconfigured,
        '拉取模型列表前请先填写 API 密钥或完成登录授权',
      );
    }

    final Uri modelsUri;
    final headers = <String, String>{
      'Accept': 'application/json',
      ...extraHeaders,
    };

    switch (protocol) {
      case AiApiProtocol.openaiCompatible:
        var root = trimmed;
        if (root.toLowerCase().endsWith('/chat/completions')) {
          root = root.substring(0, root.length - '/chat/completions'.length);
        }
        modelsUri = Uri.parse(
          root.toLowerCase().endsWith('/models') ? root : '$root/models',
        );
        if (key.isNotEmpty) {
          headers['Authorization'] = 'Bearer $key';
        }
      case AiApiProtocol.anthropicMessages:
        var root = trimmed;
        if (root.toLowerCase().endsWith('/messages')) {
          root = root.substring(0, root.length - '/messages'.length);
        }
        final rootUri = Uri.parse(root);
        modelsUri = Uri.parse(
          (rootUri.path.isEmpty || rootUri.path == '/')
              ? '$root/v1/models'
              : '$root/models',
        );
        if (key.isNotEmpty) {
          headers['x-api-key'] = key;
        }
        headers['anthropic-version'] = '2023-06-01';
      case AiApiProtocol.geminiGenerateContent:
        var root = trimmed;
        final modelsIdx = root.toLowerCase().indexOf('/models/');
        if (modelsIdx > 0) {
          root = root.substring(0, modelsIdx);
        }
        modelsUri = Uri.parse(
          root.toLowerCase().endsWith('/models') ? root : '$root/models',
        );
        if (key.isNotEmpty) {
          headers['x-goog-api-key'] = key;
        }
    }

    final ephemeral = httpClient == null;
    final client = httpClient ?? http.Client();
    try {
      final resp = await client.get(modelsUri, headers: headers).timeout(timeout);
      final rawBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // Fallback for Ollama servers where `/v1/models` might not be exposed
        // on older builds: probe `/api/tags` on the same loopback host.
        if (protocol == AiApiProtocol.openaiCompatible &&
            isLoopbackAiBaseUrl(trimmed)) {
          final fallbackUri = parsed.replace(path: '/api/tags', query: '');
          final fallbackResp = await client
              .get(
                fallbackUri,
                headers: const <String, String>{'Accept': 'application/json'},
              )
              .timeout(timeout);
          if (fallbackResp.statusCode >= 200 && fallbackResp.statusCode < 300) {
            return _parseModelList(
              utf8.decode(fallbackResp.bodyBytes, allowMalformed: true),
            );
          }
        }
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          throw AiServiceException(
            AiErrorCode.unauthorized,
            '鉴权失败（HTTP ${resp.statusCode}），请检查密钥或重新授权',
            statusCode: resp.statusCode,
          );
        }
        throw AiServiceException(
          AiErrorCode.networkError,
          '拉取模型列表失败（HTTP ${resp.statusCode}）',
          statusCode: resp.statusCode,
        );
      }
      return _parseModelList(rawBody);
    } on AiServiceException {
      rethrow;
    } on TimeoutException {
      throw const AiServiceException(
        AiErrorCode.timeout,
        '拉取模型列表超时，请检查网络连接',
      );
    } catch (e) {
      throw AiServiceException(
        AiErrorCode.networkError,
        '拉取模型列表失败：${redactAiSecret(e.toString())}',
      );
    } finally {
      if (ephemeral) client.close();
    }
  }

  static List<String> _parseModelList(String rawBody) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawBody);
    } catch (_) {
      throw const AiServiceException(
        AiErrorCode.malformedResponse,
        '模型列表接口返回了非 JSON 内容',
      );
    }
    final out = <String>{};
    if (decoded is Map) {
      if (decoded['data'] is List) {
        for (final item in decoded['data'] as List) {
          if (item is Map) {
            final id = (item['id'] ?? '').toString().trim();
            if (id.isNotEmpty) out.add(id);
          }
        }
      }
      if (decoded['models'] is List) {
        for (final item in decoded['models'] as List) {
          if (item is Map) {
            var name = (item['name'] ?? item['id'] ?? '').toString().trim();
            if (name.startsWith('models/')) {
              name = name.substring('models/'.length);
            }
            if (name.isNotEmpty) out.add(name);
          } else if (item is String && item.trim().isNotEmpty) {
            out.add(item.trim());
          }
        }
      }
    }
    final sorted = out.toList()..sort();
    return List<String>.unmodifiable(sorted);
  }
}
