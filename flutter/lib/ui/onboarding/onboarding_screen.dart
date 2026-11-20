// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ohos_runtime.dart';
import '../ios_liquid_glass.dart';
import 'first_play_gesture_hint.dart';
import 'onboarding_prefs.dart';

/// Strictly fictional procedural demo poster metadata.
class DemoPosterItem {
  final String id;
  final String file;
  final String titleZh;
  final String titleEn;
  final String badgeZh;
  final String badgeEn;
  final List<String> specs;
  final double progress;
  final Color accentColor;

  const DemoPosterItem({
    required this.id,
    required this.file,
    required this.titleZh,
    required this.titleEn,
    this.badgeZh = '示例',
    this.badgeEn = 'DEMO',
    required this.specs,
    this.progress = 0.0,
    required this.accentColor,
  });

  String title({required bool zh}) => zh ? titleZh : titleEn;
  String badge({required bool zh}) => zh ? badgeZh : badgeEn;
  String get assetPath => 'assets/demo/$file';

  static List<DemoPosterItem> parseManifest(String rawJson) {
    if (rawJson.trim().isEmpty) return const <DemoPosterItem>[];
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return const <DemoPosterItem>[];
    final items = decoded['items'];
    if (items is! List) return const <DemoPosterItem>[];
    final result = <DemoPosterItem>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final specsRaw = map['specs'];
      final specs = specsRaw is List
          ? specsRaw
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
          : const <String>[];
      result.add(
        DemoPosterItem(
          id: (map['id'] ?? '').toString(),
          file: (map['file'] ?? '').toString(),
          titleZh: (map['titleZh'] ?? '示例').toString(),
          titleEn: (map['titleEn'] ?? 'Sample').toString(),
          badgeZh: (map['badgeZh'] ?? '示例').toString(),
          badgeEn: (map['badgeEn'] ?? 'DEMO').toString(),
          specs: specs,
          progress: ((map['progress'] is num)
                  ? (map['progress'] as num).toDouble()
                  : 0.0)
              .clamp(0.0, 1.0),
          accentColor: _parseHexColor(
            (map['accentHex'] ?? '#0A84FF').toString(),
          ),
        ),
      );
    }
    return result;
  }

  static Color _parseHexColor(String hex) {
    final cleaned = hex.trim().replaceFirst('#', '');
    if (cleaned.length == 6) {
      final parsed = int.tryParse(cleaned, radix: 16);
      if (parsed != null) return Color(0xFF000000 | parsed);
    }
    return const Color(0xFF0A84FF);
  }
}

/// Built-in fictional fallback list used before Wave 2 registers `assets/demo/`
/// in `flutter/pubspec.yaml` or in isolated widget tests.
const List<DemoPosterItem> kFallbackDemoPosters = <DemoPosterItem>[
  DemoPosterItem(
    id: 'demo_01',
    file: 'demo_01.png',
    titleZh: '示例 · 远航',
    titleEn: 'Sample · Horizon',
    specs: ['4K', 'DV · ATMOS', 'REMUX'],
    progress: 0.68,
    accentColor: Color(0xFF0A84FF),
  ),
  DemoPosterItem(
    id: 'demo_02',
    file: 'demo_02.png',
    titleZh: '示例 · 城市微光',
    titleEn: 'Sample · City Glow',
    specs: ['4K', 'HDR10+', 'DD+ 5.1'],
    progress: 0.34,
    accentColor: Color(0xFFBF5AF2),
  ),
  DemoPosterItem(
    id: 'demo_03',
    file: 'demo_03.png',
    titleZh: '示例 · 深空信标',
    titleEn: 'Sample · Deep Beacon',
    specs: ['4K', 'DV · ATMOS'],
    progress: 0.52,
    accentColor: Color(0xFF5AC8FA),
  ),
  DemoPosterItem(
    id: 'demo_04',
    file: 'demo_04.png',
    titleZh: '示例 · 海岸季风',
    titleEn: 'Sample · Coastal Wind',
    specs: ['4K', 'HLG', 'HEVC'],
    progress: 0.0,
    accentColor: Color(0xFF30D158),
  ),
  DemoPosterItem(
    id: 'demo_05',
    file: 'demo_05.png',
    titleZh: '示例 · 静夜回响',
    titleEn: 'Sample · Night Echo',
    specs: ['1080P', 'REMUX'],
    progress: 0.81,
    accentColor: Color(0xFF5E5CE6),
  ),
  DemoPosterItem(
    id: 'demo_06',
    file: 'demo_06.png',
    titleZh: '示例 · 云端走廊',
    titleEn: 'Sample · Cloud Corridor',
    specs: ['4K', 'HDR10'],
    progress: 0.0,
    accentColor: Color(0xFFFF9F0A),
  ),
];

/// Standalone 5-act story onboarding route for iPhone, iPad, macOS, Windows,
/// and Android Flutter builds.
///
/// Automatically bypassed on HarmonyOS NEXT (`OhosRuntime.isOhos`).
class OnboardingScreen extends StatefulWidget {
  static const int actCount = 5;

  final OnboardingPrefs prefs;
  final bool? isChinese;
  final FirstPlayHintPlatform? platformOverride;
  final bool initialReduceMotion;
  final bool initialReduceTransparency;
  final double initialTextScale;
  final WidgetBuilder? backgroundBuilder;
  final ValueChanged<String>? onImportConfig;
  final VoidCallback? onOpenSync;
  final void Function(
    bool reduceMotion,
    bool reduceTransparency,
    double textScale,
  )? onPersonalizationChanged;
  final ValueChanged<bool>? onFinished;

  const OnboardingScreen({
    super.key,
    required this.prefs,
    this.isChinese,
    this.platformOverride,
    this.initialReduceMotion = false,
    this.initialReduceTransparency = false,
    this.initialTextScale = 1.0,
    this.backgroundBuilder,
    this.onImportConfig,
    this.onOpenSync,
    this.onPersonalizationChanged,
    this.onFinished,
  });

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _act = 0;
  late bool _reduceMotion;
  late bool _reduceTransparency;
  late double _textScale;
  List<DemoPosterItem> _demoItems = kFallbackDemoPosters;
  bool _ohosBypassSent = false;

  @override
  void initState() {
    super.initState();
    _reduceMotion = widget.initialReduceMotion;
    _reduceTransparency = widget.initialReduceTransparency;
    _textScale = widget.initialTextScale.clamp(0.85, 1.35);
    if (OhosRuntime.isOhos) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _ohosBypassSent) return;
        _ohosBypassSent = true;
        widget.onFinished?.call(true);
      });
    } else {
      _loadDemoManifest();
    }
  }

  Future<void> _loadDemoManifest() async {
    try {
      final raw = await rootBundle.loadString('assets/demo/manifest.json');
      final parsed = DemoPosterItem.parseManifest(raw);
      if (mounted && parsed.isNotEmpty) {
        setState(() => _demoItems = parsed);
      }
    } catch (_) {
      // Expected before Wave 2 registers assets/demo/ in pubspec.yaml.
    }
  }

  Future<void> _finish({required bool skipped}) async {
    await widget.prefs.markOnboardingCompleted();
    if (!mounted) return;
    widget.onFinished?.call(skipped);
  }

  void _nextAct() {
    if (_act < OnboardingScreen.actCount - 1) {
      setState(() => _act++);
    } else {
      _finish(skipped: false);
    }
  }

  void _prevAct() {
    if (_act > 0) {
      setState(() => _act--);
    }
  }

  void _notifyPersonalization() {
    widget.onPersonalizationChanged?.call(
      _reduceMotion,
      _reduceTransparency,
      _textScale,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos) {
      return const SizedBox.shrink();
    }

    final locale = Localizations.maybeLocaleOf(context);
    final zh = widget.isChinese ?? (locale?.languageCode.toLowerCase() != 'en');
    final platform = widget.platformOverride ??
        resolveFirstPlayHintPlatform(platform: Theme.of(context).platform);
    final disableAnimations =
        _reduceMotion || MediaQuery.disableAnimationsOf(context);
    final highContrast =
        _reduceTransparency || MediaQuery.highContrastOf(context);

    return Scaffold(
      backgroundColor: const Color(0xFF09090C),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.backgroundBuilder != null)
            widget.backgroundBuilder!(context)
          else
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF09090C),
                    Color(0xFF101829),
                    Color(0xFF09090C),
                  ],
                ),
              ),
            ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 720;
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 40 : 20,
                    vertical: wide ? 24 : 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildTopBar(zh),
                      const SizedBox(height: 16),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: Duration(
                            milliseconds: disableAnimations ? 120 : 220,
                          ),
                          child: SingleChildScrollView(
                            key: ValueKey<int>(_act),
                            child: _buildActContent(
                              act: _act,
                              wide: wide,
                              zh: zh,
                              platform: platform,
                              highContrast: highContrast,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildBottomBar(zh),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(bool zh) {
    return Row(
      children: [
        Expanded(
          child: Text(
            zh ? 'Marco Movie · 新手引导' : 'Marco Movie · Welcome',
            style: const TextStyle(
              color: Color(0xFFF5F5F7),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        TextButton(
          key: const Key('onboarding_skip_button'),
          onPressed: () => _finish(skipped: true),
          child: Text(
            zh ? '跳过' : 'Skip',
            style: const TextStyle(
              color: Color(0xFFB0B3C2),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomBar(bool zh) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: _act > 0
              ? TextButton(
                  key: const Key('onboarding_prev_button'),
                  onPressed: _prevAct,
                  child: Text(
                    zh ? '上一幕' : 'Back',
                    style: const TextStyle(color: Color(0xFFF5F5F7)),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(OnboardingScreen.actCount, (index) {
              final active = index == _act;
              return AnimatedContainer(
                duration: Duration(milliseconds: _reduceMotion ? 0 : 180),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: active ? 22 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: active
                      ? const Color(0xFF0A84FF)
                      : const Color(0x55FFFFFF),
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
        ),
        _buildPrimaryCta(
          key: const Key('onboarding_next_button'),
          label: _act == OnboardingScreen.actCount - 1
              ? (zh ? '先进入首页' : 'Enter Home')
              : (zh ? '下一幕' : 'Next'),
          symbol: _act == OnboardingScreen.actCount - 1
              ? 'checkmark.circle.fill'
              : 'chevron.right',
          onTap: _nextAct,
        ),
      ],
    );
  }

  /// Primary CTA uses [IosNativeGlassButton] on iOS 26+ with clean Flutter
  /// fallback on iOS 15–18, Android, Windows, macOS, and tests.
  Widget _buildPrimaryCta({
    Key? key,
    required String label,
    required String symbol,
    required VoidCallback onTap,
  }) {
    final fallback = FilledButton(
      key: key,
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF0A84FF),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );

    return IosNativeGlassButton(
      style: 'capsule',
      label: label,
      trailingSymbol: symbol,
      tintColor: const Color(0xFF0A84FF),
      maxWidth: 200,
      height: 40,
      onTap: onTap,
      fallback: fallback,
    );
  }

  Widget _buildActContent({
    required int act,
    required bool wide,
    required bool zh,
    required FirstPlayHintPlatform platform,
    required bool highContrast,
  }) {
    switch (act) {
      case 0:
        return _buildAct1EmptyShell(wide, zh, platform, highContrast);
      case 1:
        return _buildAct2PosterWall(wide, zh, highContrast);
      case 2:
        return _buildAct3Sync(wide, zh, highContrast);
      case 3:
        return _buildAct4PlaybackHud(wide, zh, platform, highContrast);
      default:
        return _buildAct5Personalize(wide, zh, highContrast);
    }
  }

  Widget _buildSplit({
    required bool wide,
    required Widget left,
    required Widget right,
  }) {
    if (wide) {
      return Row(
        key: const Key('onboarding_wide_two_column'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 9, child: left),
          const SizedBox(width: 28),
          Expanded(flex: 11, child: right),
        ],
      );
    }
    return Column(
      key: const Key('onboarding_compact_single_column'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        left,
        const SizedBox(height: 18),
        right,
      ],
    );
  }

  Widget _buildGlassCard({
    required bool highContrast,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: highContrast
            ? const Color(0xF51E1E22)
            : const Color(0xCC161822),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highContrast
              ? const Color(0x73FFFFFF)
              : const Color(0x38FFFFFF),
          width: 1,
        ),
      ),
      child: child,
    );
  }

  Widget _buildActCopy({
    required String eyebrow,
    required String headline,
    required String body,
    Widget? action,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow,
          style: const TextStyle(
            color: Color(0xFF5AC8FA),
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          headline,
          style: TextStyle(
            color: const Color(0xFFF5F5F7),
            fontSize: 24 * _textScale,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          style: TextStyle(
            color: const Color(0xFFB0B3C2),
            fontSize: 14 * _textScale,
            height: 1.5,
          ),
        ),
        if (action != null) ...[
          const SizedBox(height: 16),
          action,
        ],
      ],
    );
  }

  Widget _buildAct1EmptyShell(
    bool wide,
    bool zh,
    FirstPlayHintPlatform platform,
    bool highContrast,
  ) {
    final platformTip = switch (platform) {
      FirstPlayHintPlatform.tv => zh
          ? '电视端支持局域网扫码推送与遥控器输入'
          : 'TV supports LAN QR push and remote input',
      FirstPlayHintPlatform.desktop => zh
          ? '桌面端支持地址粘贴、本地配置与备份一键还原'
          : 'Desktop supports URL paste, local files, and backup restore',
      FirstPlayHintPlatform.touch => zh
          ? '手机 / 平板 / iOS 支持剪贴板一键粘贴与本地文件导入'
          : 'Mobile / iPad / iOS supports one-tap clipboard paste and file import',
    };

    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '第 1 幕 · 自有配置与工具边界' : 'Act 1 · Your Own Sources',
        headline: zh ? '纯净播放与内容管理工具' : 'A Clean Player & Library Tool',
        body: zh
            ? 'Marco Movie 仅作播放与内容管理工具，不内置、不提供、不托管任何影视资源。首次启动配置地址默认为空，由您自行导入合法自有源。'
            : 'Marco Movie is strictly a playback and library tool. It bundles, provides, and hosts zero media content. Initial source address stays empty until you import your own.',
        action: _buildPrimaryCta(
          key: const Key('onboarding_act1_import_button'),
          label: zh ? '立即导入配置' : 'Import Config',
          symbol: 'square.and.arrow.down',
          onTap: () => widget.onImportConfig?.call(''),
        ),
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              zh ? '空配置地址预览（默认 ""）' : 'Empty Config Preview (Default "")',
              style: const TextStyle(
                color: Color(0xFF5AC8FA),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0x6609090C),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x38FFFFFF)),
              ),
              child: const Text(
                'https://your-own-config.example/config.json',
                style: TextStyle(color: Color(0xFFB0B3C2), fontSize: 13),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              platformTip,
              style: const TextStyle(color: Color(0xFFF5F5F7), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAct2PosterWall(bool wide, bool zh, bool highContrast) {
    final previewItems = _demoItems.take(6).toList();
    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '第 2 幕 · 海报墙、规格徽章与续播' : 'Act 2 · Poster Wall & Badges',
        headline: zh ? '规格一目了然，续播无缝衔接' : 'Clear Specs & Seamless Resume',
        body: zh
            ? '以下 14 张抽象几何海报均为程序化生成的虚构示例素材，展示纯文字规格徽章（4K、DV · ATMOS、HDR10+、REMUX）与继续观看进度条。'
            : 'These 14 procedurally generated abstract posters are fictional samples showcasing text-only spec badges (4K, DV · ATMOS, HDR10+, REMUX) and continue-watching progress.',
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              zh ? '示例海报墙（全部为虚构占位素材）' : 'Sample Poster Wall (Fictional)',
              style: const TextStyle(
                color: Color(0xFFFFB340),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 224,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: previewItems.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) =>
                    _buildDemoPosterCard(previewItems[index], zh),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDemoPosterCard(DemoPosterItem item, bool zh) {
    return SizedBox(
      width: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 112,
              height: 168,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    item.assetPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            const Color(0xFF09090C),
                            item.accentColor,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Mandatory UI-layer "示例 / DEMO" badge on every card.
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      key: Key('demo_badge_${item.id}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xD9101218),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: const Color(0x80FFFFFF),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        item.badge(zh: zh),
                        style: const TextStyle(
                          color: Color(0xFFF5F5F7),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (item.progress > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 4,
                        color: const Color(0x66000000),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: item.progress,
                          child: Container(color: const Color(0xFF0A84FF)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title(zh: zh),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFF5F5F7),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (item.specs.isNotEmpty)
            Text(
              item.specs.take(2).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF5AC8FA),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAct3Sync(bool wide, bool zh, bool highContrast) {
    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '第 3 幕 · 多端同步（WebDAV / 局域网）' : 'Act 3 · Multi-Device Sync',
        headline: zh ? '历史、收藏与订阅跨端同步' : 'Sync History, Favorites & Sources',
        body: zh
            ? '基于 marco-movie-sync v2 协议，支持自配 WebDAV 云盘与同一局域网点对点免云盘直连同步。隐私空间与网盘/Emby 登录凭据始终保持本机隔离。'
            : 'Powered by marco-movie-sync v2 with both self-hosted WebDAV and cloud-free LAN peer-to-peer sync. Privacy space and netdisk/Emby credentials stay strictly device-local.',
        action: OutlinedButton(
          key: const Key('onboarding_act3_sync_button'),
          onPressed: widget.onOpenSync,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFF5F5F7),
            side: const BorderSide(color: Color(0x55FFFFFF)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          child: Text(zh ? '配置同步' : 'Configure Sync'),
        ),
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSyncTile(
              title: zh ? '自配 WebDAV 云盘' : 'Self-Hosted WebDAV',
              subtitle: zh
                  ? '双向合并观看历史、收藏与公开订阅'
                  : 'Two-way merge for history, favorites & public subscriptions',
              accent: const Color(0xFF0A84FF),
            ),
            const SizedBox(height: 10),
            _buildSyncTile(
              title: zh ? '局域网点对点免云盘直连' : 'LAN Peer-to-Peer Direct',
              subtitle: zh
                  ? '同一局域网设备直接同步，零第三方服务器中转'
                  : 'Direct local network sync with zero cloud relay',
              accent: const Color(0xFF5AC8FA),
            ),
            const SizedBox(height: 12),
            Text(
              zh
                  ? '安全边界：隐私空间密码与网盘/Emby 登录凭据本机隔离，永不上传'
                  : 'Privacy boundary: Privacy space & netdisk/Emby credentials never sync',
              style: const TextStyle(
                color: Color(0xFFBF5AF2),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncTile({
    required String title,
    required String subtitle,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x5509090C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: accent,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xFFB0B3C2), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildAct4PlaybackHud(
    bool wide,
    bool zh,
    FirstPlayHintPlatform platform,
    bool highContrast,
  ) {
    final bullets = switch (platform) {
      FirstPlayHintPlatform.desktop => zh
          ? [
              '短按 / 长按 ← / →：快进快退与加速预览',
              'Space 暂停 · S / [ ] 切换倍速 · D 开关弹幕',
              '鼠标滚轮调节音量 · 静止 2.5 秒自动隐藏光标',
            ]
          : [
              'Short / Hold ← / →: Seek & accelerated scrub preview',
              'Space play/pause · S / [ ] speed · D toggle danmaku',
              'Scroll wheel volume · Cursor auto-hides after 2.5s idle',
            ],
      FirstPlayHintPlatform.tv => zh
          ? [
              '短按左右键：快进 / 快退 15 秒',
              '长按左右键：加速快进/快退预览，松手即播',
              '返回键：立即取消预览并恢复原位置',
            ]
          : [
              'Short Left / Right: Seek 15s',
              'Hold Left / Right: Accelerated scrub preview, release to play',
              'Back key: Cancel preview and restore position',
            ],
      FirstPlayHintPlatform.touch => zh
          ? [
              '长按 2.0× 倍速 → 左右滑调速（1.25×–3.0×）→ 上滑锁定',
              '画面两侧双击快进 / 快退，点击顶部锁定胶囊恢复',
              '左右半屏上下滑动分别调节亮度与音量',
            ]
          : [
              'Hold 2.0× speed -> slide to adjust (1.25×–3.0×) -> swipe up to lock',
              'Double-tap left/right sides to seek; tap top lock pill to reset',
              'Vertical drag on left/right halves adjusts brightness & volume',
            ],
    };

    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '第 4 幕 · 进阶播放操控与 HUD' : 'Act 4 · Playback Controls & HUD',
        headline: zh ? '顺手操控，沉浸观影 HUD' : 'Fluid Controls & Cinema HUD',
        body: zh
            ? '全新播放页集成起播规格提示、常驻细进度条、3 秒跳过片头倒计时与分片弹幕，并针对触控、遥控与键鼠分别优化手势与快捷键。'
            : 'The upgraded player combines start-up spec badges, thin progress bar, 3s skip-intro countdown, and windowed danmaku with tailored gestures and shortcuts.',
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              zh
                  ? '4K · DV · ATMOS   |   3s 跳过片头   |   分片弹幕'
                  : '4K · DV · ATMOS   |   3s Skip Intro   |   Danmaku',
              style: const TextStyle(
                color: Color(0xFFFFB340),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            for (final line in bullets) ...[
              Text(
                '•  $line',
                style: const TextStyle(
                  color: Color(0xFFF5F5F7),
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: const LinearProgressIndicator(
                value: 0.42,
                minHeight: 4,
                backgroundColor: Color(0x38FFFFFF),
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0A84FF)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAct5Personalize(bool wide, bool zh, bool highContrast) {
    return _buildSplit(
      wide: wide,
      left: _buildActCopy(
        eyebrow: zh ? '第 5 幕 · 个性化外观与立即开始' : 'Act 5 · Personalize & Launch',
        headline: zh ? '按您的观看习惯微调界面' : 'Tailor Comfort & Visuals',
        body: zh
            ? '可在此预览减少动态效果、降低透明度与动态字号缩放。随时可在「设置 -> 关于与帮助 -> 重新查看新手引导」再次打开本引导。'
            : 'Preview Reduce Motion, Reduce Transparency, and dynamic text scale. You can replay this guide anytime in Settings -> About & Help.',
        action: _buildPrimaryCta(
          key: const Key('onboarding_act5_import_button'),
          label: zh ? '立即导入配置' : 'Import Config Now',
          symbol: 'square.and.arrow.down',
          onTap: () async {
            await widget.prefs.markOnboardingCompleted();
            widget.onImportConfig?.call('');
            widget.onFinished?.call(false);
          },
        ),
      ),
      right: _buildGlassCard(
        highContrast: highContrast,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile.adaptive(
              key: const Key('onboarding_reduce_motion_switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                zh ? '减少动态效果' : 'Reduce Motion',
                style: const TextStyle(color: Color(0xFFF5F5F7), fontSize: 14),
              ),
              value: _reduceMotion,
              onChanged: (v) {
                setState(() => _reduceMotion = v);
                _notifyPersonalization();
              },
            ),
            SwitchListTile.adaptive(
              key: const Key('onboarding_reduce_transparency_switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                zh ? '降低透明度（高对比纯色）' : 'Reduce Transparency',
                style: const TextStyle(color: Color(0xFFF5F5F7), fontSize: 14),
              ),
              value: _reduceTransparency,
              onChanged: (v) {
                setState(() => _reduceTransparency = v);
                _notifyPersonalization();
              },
            ),
            const SizedBox(height: 8),
            Text(
              zh
                  ? '字号预览：${(_textScale * 100).round()}%'
                  : 'Text Scale: ${(_textScale * 100).round()}%',
              style: const TextStyle(color: Color(0xFFB0B3C2), fontSize: 13),
            ),
            Slider(
              key: const Key('onboarding_text_scale_slider'),
              min: 0.85,
              max: 1.35,
              divisions: 5,
              value: _textScale,
              onChanged: (v) {
                setState(() => _textScale = v);
                _notifyPersonalization();
              },
            ),
          ],
        ),
      ),
    );
  }
}
