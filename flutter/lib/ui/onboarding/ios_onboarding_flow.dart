// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/ohos_runtime.dart';
import '../ios_liquid_glass.dart';
import 'first_play_gesture_hint.dart' show resolveOnboardingChineseLocale;
import 'onboarding_prefs.dart';

/// Whether the Apple-style iOS / iPadOS feature tour should replace the
/// legacy cross-platform onboarding showcase.
///
/// Windows / macOS / Android / TV / HarmonyOS keep the legacy flow untouched.
bool shouldUseIosOnboardingFlow() =>
    !kIsWeb &&
    !OhosRuntime.isOhos &&
    defaultTargetPlatform == TargetPlatform.iOS;

/// Apple-style "Welcome to Marco" feature tour for iPhone and iPad.
///
/// Five concise pages, each teaching how to use one core feature, with a
/// vector illustration drawn in Flutter, a large bold title, a short subtitle
/// and up to three "What's New"-style feature rows.
///
/// Motion budget (device thermals): only a one-shot entrance animation,
/// spring page transitions and gesture-driven parallax. No repeating
/// animations, periodic timers or shader tickers. Reduce Motion disables the
/// entrance, parallax and animated page transitions.
class IosOnboardingFlow extends StatefulWidget {
  static const int pageCount = 5;

  final OnboardingPrefs prefs;
  final bool? isChinese;
  final bool initialReduceMotion;
  final ValueChanged<String>? onImportConfig;
  final ValueChanged<bool>? onFinished;

  const IosOnboardingFlow({
    super.key,
    required this.prefs,
    this.isChinese,
    this.initialReduceMotion = false,
    this.onImportConfig,
    this.onFinished,
  });

  @override
  State<IosOnboardingFlow> createState() => _IosOnboardingFlowState();
}

class _IosOnboardingFlowState extends State<IosOnboardingFlow>
    with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController();
  late final AnimationController _entrance;
  int _page = 0;
  int _targetPage = 0;
  bool _completing = false;
  bool _entranceStarted = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entranceStarted) return;
    _entranceStarted = true;
    if (_reduceMotionOf(context)) {
      _entrance.value = 1.0;
    } else {
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    _pageController.dispose();
    super.dispose();
  }

  bool _reduceMotionOf(BuildContext context) =>
      widget.initialReduceMotion || MediaQuery.disableAnimationsOf(context);

  Future<void> _finish({required bool skipped, bool openImport = false}) async {
    if (_completing) return;
    _completing = true;
    await widget.prefs.markOnboardingCompleted();
    if (!mounted) return;
    widget.onFinished?.call(skipped);
    if (openImport) {
      widget.onImportConfig?.call('');
    }
  }

  void _goTo(int index) {
    if (!_pageController.hasClients) return;
    final target = index.clamp(0, IosOnboardingFlow.pageCount - 1);
    _targetPage = target;
    if (_reduceMotionOf(context)) {
      _pageController.jumpToPage(target);
      if (_page != target) setState(() => _page = target);
      return;
    }
    if (_page != target) setState(() => _page = target);
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 360),
      curve: const _AppleSpringCurve(),
    );
  }

  void _next() {
    final current = _pageController.hasClients ? _targetPage : _page;
    if (current < IosOnboardingFlow.pageCount - 1) {
      _goTo(current + 1);
    } else {
      _finish(skipped: false);
    }
  }

  void _back() {
    final current = _pageController.hasClients ? _targetPage : _page;
    if (current > 0) _goTo(current - 1);
  }

  @override
  Widget build(BuildContext context) {
    final zh = resolveOnboardingChineseLocale(context, widget.isChinese);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sys = _SysColors(dark);
    final reduceMotion = _reduceMotionOf(context);
    final pages = _buildPages(zh: zh, sys: sys);
    final isLast = _page == pages.length - 1;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_page > 0) {
          _back();
        } else {
          _finish(skipped: true);
        }
      },
      child: Scaffold(
        key: const Key('ios_onboarding_flow'),
        backgroundColor: dark ? Colors.black : Colors.white,
        body: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: _AccentBackdrop(
                controller: _pageController,
                accents: [for (final p in pages) p.accent],
                currentPage: _page,
                dark: dark,
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compactHeight = constraints.maxHeight < 460;
                  final hPad = constraints.maxWidth < 360 ? 20.0 : 28.0;
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildTopBar(
                            zh: zh,
                            sys: sys,
                            isLast: isLast,
                            reduceMotion: reduceMotion,
                          ),
                          Expanded(
                            child: PageView.builder(
                              key: const Key('ios_onboarding_pager'),
                              controller: _pageController,
                              itemCount: pages.length,
                              onPageChanged: (i) => setState(() {
                                _page = i;
                                _targetPage = i;
                              }),
                              itemBuilder: (context, i) => _IosOnboardingPage(
                                key: ValueKey<String>('ios_onboarding_page_$i'),
                                index: i,
                                data: pages[i],
                                controller: _pageController,
                                entrance: _entrance,
                                reduceMotion: reduceMotion,
                                dark: dark,
                                horizontalPadding: hPad,
                                trailing: i == 1 && widget.onImportConfig != null
                                    ? _buildImportLink(zh: zh, sys: sys)
                                    : null,
                              ),
                            ),
                          ),
                          _EntranceFade(
                            entrance: _entrance,
                            interval: const Interval(0.35, 1.0),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                hPad,
                                compactHeight ? 4 : 10,
                                hPad,
                                MediaQuery.paddingOf(context).bottom > 0
                                    ? 8
                                    : (compactHeight ? 10 : 20),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _PageDots(
                                    controller: _pageController,
                                    count: pages.length,
                                    currentPage: _page,
                                    reduceMotion: reduceMotion,
                                    activeColor: dark
                                        ? Colors.white
                                        : const Color(0xFF1C1C1E),
                                    semanticsLabel: zh
                                        ? '第 ${_page + 1} 页，共 ${pages.length} 页'
                                        : 'Page ${_page + 1} of ${pages.length}',
                                  ),
                                  SizedBox(height: compactHeight ? 10 : 18),
                                  _buildPrimaryButton(
                                    label: isLast
                                        ? (zh ? '开始使用' : 'Get Started')
                                        : (zh ? '继续' : 'Continue'),
                                    hint: isLast
                                        ? (zh ? '完成新手引导' : 'Finishes the tour')
                                        : (zh ? '前往下一页' : 'Goes to the next page'),
                                    height: compactHeight ? 46 : 52,
                                    color: sys.blue,
                                    reduceMotion: reduceMotion,
                                  ),
                                ],
                              ),
                            ),
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
    );
  }

  Widget _buildTopBar({
    required bool zh,
    required _SysColors sys,
    required bool isLast,
    required bool reduceMotion,
  }) {
    final showBack = _page > 0;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          _FadeVisibility(
            visible: showBack,
            reduceMotion: reduceMotion,
            child: CupertinoButton(
              key: const Key('onboarding_prev_button'),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(44, 44),
              onPressed: showBack ? _back : null,
              child: Semantics(
                label: zh ? '上一页' : 'Back',
                button: true,
                excludeSemantics: true,
                child: Icon(
                  CupertinoIcons.chevron_back,
                  size: 24,
                  color: sys.blue,
                ),
              ),
            ),
          ),
          const Spacer(),
          _FadeVisibility(
            visible: !isLast,
            reduceMotion: reduceMotion,
            child: CupertinoButton(
              key: const Key('onboarding_skip_button'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(44, 44),
              onPressed: isLast ? null : () => _finish(skipped: true),
              child: Text(
                zh ? '跳过' : 'Skip',
                semanticsLabel: zh ? '跳过新手引导' : 'Skip the tour',
                maxLines: 1,
                textScaler:
                    MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.35),
                style: TextStyle(
                  color: sys.blue,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportLink({required bool zh, required _SysColors sys}) {
    return CupertinoButton(
      key: const Key('ios_onboarding_import_link'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(44, 44),
      onPressed: () => _finish(skipped: false, openImport: true),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.plus_circle_fill, size: 19, color: sys.blue),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              zh ? '立即添加资源库' : 'Add a Library Now',
              maxLines: 2,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: sys.blue,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Primary CTA: native iOS 26+ Liquid Glass capsule via
  /// [IosNativeGlassButton]; crisp Flutter filled button on iOS 14–25.
  Widget _buildPrimaryButton({
    required String label,
    required String hint,
    required double height,
    required Color color,
    required bool reduceMotion,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        return IosNativeGlassButton(
          key: const Key('onboarding_next_button'),
          style: 'capsule',
          label: label,
          tintColor: color,
          foregroundColor: Colors.white,
          prominent: true,
          accessibilityLabel: label,
          width: width,
          maxWidth: width,
          height: height,
          onTap: _next,
          fallback: _PrimaryFilledButton(
            label: label,
            hint: hint,
            height: height,
            color: color,
            reduceMotion: reduceMotion,
            onTap: _next,
          ),
        );
      },
    );
  }

  List<_PageData> _buildPages({required bool zh, required _SysColors sys}) {
    return <_PageData>[
      _PageData(
        art: _ArtKind.welcome,
        accent: sys.blue,
        accent2: sys.indigo,
        title: zh ? '欢迎使用 Marco' : 'Welcome to Marco',
        subtitle: zh
            ? '专为 iPhone 与 iPad 打造的纯粹私人播放器。'
            : 'A clean, focused personal media player for iPhone and iPad.',
        artLabel: zh ? 'Marco 应用图标与核心能力徽章' : 'Marco app icon and feature badges',
        bullets: <_Bullet>[
          _Bullet(
            icon: CupertinoIcons.play_rectangle_fill,
            color: sys.blue,
            title: zh ? '纯粹播放体验' : 'Focused Playback',
            body: zh
                ? '支持点播、直播与多源浏览，界面简洁清爽。'
                : 'Enjoy VOD, live channels, and multi-source libraries in a clean interface.',
          ),
          _Bullet(
            icon: CupertinoIcons.checkmark_shield_fill,
            color: sys.green,
            title: zh ? '不含任何内置资源' : 'No Built-In Content',
            body: zh
                ? '官方不提供任何影视内容，请自行导入合法自有来源。'
                : 'Marco ships with zero media content. Import sources you legally own.',
          ),
          _Bullet(
            icon: CupertinoIcons.arrow_2_circlepath,
            color: sys.indigo,
            title: zh ? '本地优先与同步' : 'Local-First & Sync',
            body: zh
                ? '收藏与进度保存在本机，支持 WebDAV 或局域网同步。'
                : 'Favorites and progress stay local, with optional WebDAV or LAN sync.',
          ),
        ],
      ),
      _PageData(
        art: _ArtKind.library,
        accent: sys.orange,
        accent2: sys.blue,
        title: zh ? '添加资源库' : 'Add Your Libraries',
        subtitle: zh
            ? '接入自有订阅、局域网共享或网盘即可观看。'
            : 'Connect subscription URLs, local shares, or cloud drives to start watching.',
        artLabel: zh ? '资源库、共享存储与网盘接入示意图' : 'Subscriptions, shares and cloud drives illustration',
        bullets: <_Bullet>[
          _Bullet(
            icon: CupertinoIcons.slider_horizontal_3,
            color: sys.blue,
            title: zh ? '配置中心' : 'Config Center',
            body: zh
                ? '轻点主页右上角或在「设置」中打开，统一管理所有来源。'
                : 'Open Config Center from Home or Settings to manage all your sources.',
          ),
          _Bullet(
            icon: CupertinoIcons.link,
            color: sys.orange,
            title: zh ? '添加资源库与订阅' : 'Subscriptions & JSON',
            body: zh
                ? '粘贴订阅地址或 JSON 配置；也可长按底部「设置」直达。'
                : 'Paste a subscription URL or JSON config, or hold Settings in the Dock.',
          ),
          _Bullet(
            icon: CupertinoIcons.cloud_fill,
            color: sys.teal,
            title: zh ? 'WebDAV · SMB · 网盘' : 'WebDAV, SMB & Cloud Drives',
            body: zh
                ? '支持接入 WebDAV、SMB 共享目录与主流网盘原画播放。'
                : 'Connect WebDAV and SMB shares, or sign in to cloud drives for original quality.',
          ),
        ],
      ),
      _PageData(
        art: _ArtKind.browse,
        accent: sys.indigo,
        accent2: sys.teal,
        title: zh ? '浏览与搜索' : 'Browse & Search',
        subtitle: zh
            ? '轻点底部 Dock 切换页面，长按呼出快捷气泡。'
            : 'The bottom Dock is home base: tap to switch, or hold for quick actions.',
        artLabel: zh ? '底部 Dock、长按快捷气泡与搜索筛选示意图' : 'Dock, quick menu and search filter illustration',
        bullets: <_Bullet>[
          _Bullet(
            icon: CupertinoIcons.square_grid_2x2_fill,
            color: sys.indigo,
            title: zh ? '底部 Dock 切换' : 'Switch with the Dock',
            body: zh
                ? '在主页、直播、片库与设置之间一键切换。'
                : 'Jump effortlessly between Home, Live, Library, and Settings.',
          ),
          _Bullet(
            icon: CupertinoIcons.hand_draw_fill,
            color: sys.purple,
            title: zh ? '长按快捷气泡' : 'Hold for Quick Menu',
            body: zh
                ? '长按 Dock 图标弹出菜单，直达收藏、历史或添加资源库。'
                : 'Press and hold a Dock tab to reach Favorites, History, or Add Library.',
          ),
          _Bullet(
            icon: CupertinoIcons.search,
            color: sys.teal,
            title: zh ? '全局搜索与片库筛选' : 'Global Search & Filter',
            body: zh
                ? '轻点右下角放大镜跨源搜索；按类型、地区与年份筛选片库。'
                : 'Tap the bottom-right magnifier to search across sources, or filter by genre, region, and year.',
          ),
        ],
      ),
      _PageData(
        art: _ArtKind.gestures,
        accent: sys.purple,
        accent2: sys.blue,
        title: zh ? '播放手势与多屏' : 'Playback & Multi-Screen',
        subtitle: zh
            ? '无需寻找按钮，直接在画面上用手势操控播放。'
            : 'Skip the buttons—control playback right on the picture with intuitive gestures.',
        artLabel: zh ? '播放器手势、画中画与无线投屏示意图' : 'Player gestures, Picture in Picture and casting illustration',
        bullets: <_Bullet>[
          _Bullet(
            icon: CupertinoIcons.goforward_10,
            color: sys.purple,
            title: zh ? '双击与长按倍速' : 'Double-Tap & Hold Speed',
            body: zh
                ? '双击中央暂停或播放，双击两侧快退快进；长按开启倍速。'
                : 'Double-tap center to play or pause, sides to skip; hold for temporary fast playback.',
          ),
          _Bullet(
            icon: CupertinoIcons.arrow_left_right,
            color: sys.blue,
            title: zh ? '横滑进度，竖滑亮度和音量' : 'Swipe to Adjust',
            body: zh
                ? '左右横滑精准调节进度；左侧竖滑调亮度，右侧竖滑调音量。'
                : 'Swipe sideways to seek; swipe vertically on the left for brightness, right for volume.',
          ),
          _Bullet(
            icon: CupertinoIcons.tv_fill,
            color: sys.teal,
            title: zh ? '画中画与投屏' : 'Picture in Picture & Casting',
            body: zh
                ? '退回桌面自动小窗继续观看，或通过 AirPlay / DLNA 投屏。'
                : 'Keep watching in Picture in Picture, or cast to a TV with AirPlay or DLNA.',
          ),
        ],
      ),
      _PageData(
        art: _ArtKind.privacy,
        accent: sys.pink,
        accent2: sys.purple,
        title: zh ? '我的片库与隐私' : 'My Library & Privacy',
        subtitle: zh
            ? '集中管理收藏、历史与下载，兼顾私密保护。'
            : 'Favorites, history, and offline episodes stay organized—with isolated privacy.',
        artLabel: zh ? '海报墙长按管理、剧集收纳离线下载与隐私空间示意图' : 'Poster wall, grouped downloads and private space illustration',
        bullets: <_Bullet>[
          _Bullet(
            icon: CupertinoIcons.heart_fill,
            color: sys.pink,
            title: zh ? '收藏与历史海报墙' : 'Favorites & Poster History',
            body: zh
                ? '观看进度呈现在海报墙上，长按海报即可续播或删除记录。'
                : 'Watch progress appears on a poster wall—press and hold any poster to manage or delete.',
          ),
          _Bullet(
            icon: CupertinoIcons.arrow_down_circle_fill,
            color: sys.green,
            title: zh ? '剧集收纳离线下载' : 'Grouped Offline Downloads',
            body: zh
                ? '在详情页缓存剧集并按剧自动收纳，离线也能流畅观看。'
                : 'Download episodes from details, automatically grouped by series for offline viewing.',
          ),
          _Bullet(
            icon: CupertinoIcons.lock_shield_fill,
            color: sys.indigo,
            title: zh ? '隐私空间隔离' : 'Isolated Private Space',
            body: zh
                ? '解锁后进入独立空间，不留观看历史，与日常片库完全隔离。'
                : 'Unlock an isolated space with no watch history, separate from your main library.',
          ),
        ],
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

enum _ArtKind { welcome, library, browse, gestures, privacy }

class _Bullet {
  final IconData icon;
  final Color color;
  final String title;
  final String body;

  const _Bullet({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });
}

class _PageData {
  final _ArtKind art;
  final Color accent;
  final Color accent2;
  final String title;
  final String subtitle;
  final String artLabel;
  final List<_Bullet> bullets;

  const _PageData({
    required this.art,
    required this.accent,
    required this.accent2,
    required this.title,
    required this.subtitle,
    required this.artLabel,
    required this.bullets,
  });
}

class _IosOnboardingPage extends StatelessWidget {
  final int index;
  final _PageData data;
  final PageController controller;
  final Animation<double> entrance;
  final bool reduceMotion;
  final bool dark;
  final double horizontalPadding;
  final Widget? trailing;

  const _IosOnboardingPage({
    super.key,
    required this.index,
    required this.data,
    required this.controller,
    required this.entrance,
    required this.reduceMotion,
    required this.dark,
    required this.horizontalPadding,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final landscape = c.maxWidth > c.maxHeight * 1.25 && c.maxHeight < 460;
        final art = Semantics(
          image: true,
          label: data.artLabel,
          child: ExcludeSemantics(
            child: RepaintBoundary(
              child: FittedBox(
                child: SizedBox(
                  width: 240,
                  height: 240,
                  child: _OnboardingArt(
                    kind: data.art,
                    accent: data.accent,
                    accent2: data.accent2,
                    dark: dark,
                  ),
                ),
              ),
            ),
          ),
        );

        if (landscape) {
          final artSize = math.min(c.maxHeight * 0.82, c.maxWidth * 0.38);
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: Row(
              children: [
                _MotionLayer(
                  controller: controller,
                  entrance: entrance,
                  index: index,
                  reduceMotion: reduceMotion,
                  width: c.maxWidth,
                  parallax: 0.32,
                  interval: const Interval(0.0, 0.7),
                  child: SizedBox.square(dimension: artSize, child: art),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: _MotionLayer(
                    controller: controller,
                    entrance: entrance,
                    index: index,
                    reduceMotion: reduceMotion,
                    width: c.maxWidth,
                    parallax: 0.12,
                    interval: const Interval(0.18, 0.85),
                    slideY: 14,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: math.max(0, c.maxHeight - 24)),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _textBlock(
                            context,
                            align: TextAlign.start,
                            wide: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        final wide = c.maxWidth >= 500;
        final maxArt = wide ? 220.0 : 188.0;
        final ratio = wide ? 0.30 : 0.285;
        final artSize = math
            .min(c.maxWidth - horizontalPadding * 2, c.maxHeight * ratio)
            .clamp(104.0, maxArt);

        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 8,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: math.max(0, c.maxHeight - 16)),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MotionLayer(
                  controller: controller,
                  entrance: entrance,
                  index: index,
                  reduceMotion: reduceMotion,
                  width: c.maxWidth,
                  parallax: 0.32,
                  interval: const Interval(0.0, 0.7),
                  child: SizedBox.square(dimension: artSize, child: art),
                ),
                SizedBox(height: c.maxHeight < 520 ? 16 : 22),
                _MotionLayer(
                  controller: controller,
                  entrance: entrance,
                  index: index,
                  reduceMotion: reduceMotion,
                  width: c.maxWidth,
                  parallax: 0.12,
                  interval: const Interval(0.18, 0.85),
                  slideY: 16,
                  child: Column(
                    children: _textBlock(
                      context,
                      align: TextAlign.center,
                      wide: wide,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _textBlock(
    BuildContext context, {
    required TextAlign align,
    required bool wide,
  }) {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final label = dark ? Colors.white : const Color(0xFF111114);
    final secondary = dark ? const Color(0xA8EBEBF5) : const Color(0xAD3C3C43);
    final titleSize = wide ? 34.0 : (narrow ? 26.0 : 30.0);
    final start = align == TextAlign.start;
    return [
      Semantics(
        header: true,
        child: Text(
          data.title,
          textAlign: align,
          style: TextStyle(
            color: label,
            fontSize: titleSize,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
            height: 1.14,
          ),
        ),
      ),
      const SizedBox(height: 8),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(
          data.subtitle,
          textAlign: align,
          style: TextStyle(
            color: secondary,
            fontSize: wide ? 17 : 15.5,
            fontWeight: FontWeight.w400,
            letterSpacing: -0.2,
            height: 1.38,
          ),
        ),
      ),
      if (data.bullets.isNotEmpty) ...[
        SizedBox(height: wide ? 28 : 22),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < data.bullets.length; i++) ...[
                if (i > 0) const SizedBox(height: 15),
                _BulletRow(
                  bullet: data.bullets[i],
                  label: label,
                  secondary: secondary,
                  dark: dark,
                ),
              ],
            ],
          ),
        ),
      ],
      if (trailing != null) ...[
        const SizedBox(height: 10),
        Align(
          alignment: start ? Alignment.centerLeft : Alignment.center,
          child: trailing!,
        ),
      ],
    ];
  }
}

class _BulletRow extends StatelessWidget {
  final _Bullet bullet;
  final Color label;
  final Color secondary;
  final bool dark;

  const _BulletRow({
    required this.bullet,
    required this.label,
    required this.secondary,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '${bullet.title}. ${bullet.body}',
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              margin: const EdgeInsets.only(top: 1),
              decoration: ShapeDecoration(
                color: bullet.color.withValues(alpha: dark ? 0.18 : 0.11),
                shape: ContinuousRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              alignment: Alignment.center,
              child: Icon(bullet.icon, size: 20, color: bullet.color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bullet.title,
                    style: TextStyle(
                      color: label,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.25,
                      height: 1.24,
                    ),
                  ),
                  const SizedBox(height: 2.5),
                  Text(
                    bullet.body,
                    style: TextStyle(
                      color: secondary,
                      fontSize: 14,
                      letterSpacing: -0.1,
                      height: 1.36,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Motion helpers (one-shot / gesture-driven only)
// ---------------------------------------------------------------------------

/// Critically damped spring (no overshoot) approximating UIKit's default
/// interactive spring; settles within the animation duration.
class _AppleSpringCurve extends Curve {
  const _AppleSpringCurve();

  @override
  double transformInternal(double t) {
    const omega = 9.0;
    final x = omega * t;
    return 1 - math.exp(-x) * (1 + x);
  }
}

double _pageDelta(PageController controller, int index, int fallbackPage) {
  if (!controller.hasClients) return (fallbackPage - index).toDouble();
  final position = controller.position;
  if (!position.hasContentDimensions || !position.hasPixels) {
    return (fallbackPage - index).toDouble();
  }
  final page = controller.page ?? fallbackPage.toDouble();
  return page - index;
}

/// Gesture-driven parallax + one-shot entrance for a page layer. Rebuilds
/// only while the user swipes / a page transition runs; idle otherwise.
class _MotionLayer extends StatelessWidget {
  final PageController controller;
  final Animation<double> entrance;
  final int index;
  final bool reduceMotion;
  final double width;
  final double parallax;
  final Interval interval;
  final double slideY;
  final Widget child;

  const _MotionLayer({
    required this.controller,
    required this.entrance,
    required this.index,
    required this.reduceMotion,
    required this.width,
    required this.parallax,
    required this.interval,
    this.slideY = 22,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (reduceMotion) return child;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, entrance]),
      child: child,
      builder: (context, child) {
        final delta = _pageDelta(controller, index, index).clamp(-1.0, 1.0);
        final e = Curves.easeOutCubic.transform(interval.transform(entrance.value));
        final opacity = ((1 - delta.abs() * 0.75) * e).clamp(0.0, 1.0);
        final dx = delta * width * parallax;
        final dy = (1 - e) * slideY;
        final scale = 1 - delta.abs() * 0.06 - (1 - e) * 0.04;
        Widget result = Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: scale, child: child),
        );
        if (opacity < 0.999) {
          result = Opacity(opacity: opacity, child: result);
        }
        return result;
      },
    );
  }
}

class _EntranceFade extends StatelessWidget {
  final Animation<double> entrance;
  final Interval interval;
  final Widget child;

  const _EntranceFade({
    required this.entrance,
    required this.interval,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: entrance, curve: interval),
      child: child,
    );
  }
}

/// Fades a chrome control in/out (one-shot) and removes it from hit testing
/// and accessibility while hidden, keeping its layout slot.
class _FadeVisibility extends StatelessWidget {
  final bool visible;
  final bool reduceMotion;
  final Widget child;

  const _FadeVisibility({
    required this.visible,
    this.reduceMotion = false,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final reduce = reduceMotion || MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: reduce
            ? Opacity(opacity: visible ? 1.0 : 0.0, child: child)
            : AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: child,
              ),
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  final PageController controller;
  final int count;
  final int currentPage;
  final bool reduceMotion;
  final Color activeColor;
  final String semanticsLabel;

  const _PageDots({
    required this.controller,
    required this.count,
    required this.currentPage,
    required this.reduceMotion,
    required this.activeColor,
    required this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('ios_onboarding_dots'),
      label: semanticsLabel,
      excludeSemantics: true,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final page = reduceMotion
              ? currentPage.toDouble()
              : currentPage + _pageDelta(controller, currentPage, currentPage);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < count; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4.5),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: activeColor.withValues(
                      alpha: 0.22 +
                          0.78 * (1 - (page - i).abs()).clamp(0.0, 1.0),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Soft per-page accent glow behind the content, interpolated by the page
/// scroll position (gesture-driven, no ticker).
class _AccentBackdrop extends StatelessWidget {
  final PageController controller;
  final List<Color> accents;
  final int currentPage;
  final bool dark;

  const _AccentBackdrop({
    required this.controller,
    required this.accents,
    required this.currentPage,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final page = (currentPage + _pageDelta(controller, currentPage, currentPage))
            .clamp(0.0, accents.length - 1.0);
        final lo = page.floor();
        final hi = math.min(lo + 1, accents.length - 1);
        final accent = Color.lerp(accents[lo], accents[hi], page - lo)!;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: dark
                  ? const [Color(0xFF000000), Color(0xFF0B0B0F)]
                  : const [Color(0xFFFFFFFF), Color(0xFFF4F5F9)],
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.62),
                radius: 0.95,
                colors: [
                  accent.withValues(alpha: dark ? 0.20 : 0.10),
                  accent.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PrimaryFilledButton extends StatefulWidget {
  final String label;
  final String hint;
  final double height;
  final Color color;
  final bool reduceMotion;
  final VoidCallback onTap;

  const _PrimaryFilledButton({
    required this.label,
    required this.hint,
    required this.height,
    required this.color,
    this.reduceMotion = false,
    required this.onTap,
  });

  @override
  State<_PrimaryFilledButton> createState() => _PrimaryFilledButtonState();
}

class _PrimaryFilledButtonState extends State<_PrimaryFilledButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduce =
        widget.reduceMotion || MediaQuery.disableAnimationsOf(context);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.35);
    final buttonBody = Container(
      height: widget.height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(widget.height / 2),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          widget.label,
          maxLines: 1,
          textScaler: scaler,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: widget.label,
      hint: widget.hint,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: reduce ? null : (_) => _setPressed(true),
        onTapCancel: reduce ? null : () => _setPressed(false),
        onTapUp: reduce ? null : (_) => _setPressed(false),
        onTap: widget.onTap,
        child: reduce
            ? buttonBody
            : AnimatedScale(
                scale: _pressed ? 0.97 : 1.0,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                child: AnimatedOpacity(
                  opacity: _pressed ? 0.82 : 1.0,
                  duration: const Duration(milliseconds: 140),
                  child: buttonBody,
                ),
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Illustrations (drawn on a fixed 240×240 canvas, scaled with FittedBox)
// ---------------------------------------------------------------------------

class _SysColors {
  final bool dark;

  const _SysColors(this.dark);

  Color get blue => dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
  Color get green => dark ? const Color(0xFF30D158) : const Color(0xFF34C759);
  Color get orange => dark ? const Color(0xFFFF9F0A) : const Color(0xFFFF9500);
  Color get pink => dark ? const Color(0xFFFF375F) : const Color(0xFFFF2D55);
  Color get purple => dark ? const Color(0xFFBF5AF2) : const Color(0xFFAF52DE);
  Color get indigo => dark ? const Color(0xFF5E5CE6) : const Color(0xFF5856D6);
  Color get teal => dark ? const Color(0xFF40CBE0) : const Color(0xFF30B0C7);
  Color get red => dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);
  Color get yellow => dark ? const Color(0xFFFFD60A) : const Color(0xFFFFCC00);
}

class _Ink {
  final bool dark;

  const _Ink(this.dark);

  Color get card => dark ? const Color(0xFF1C1C1E) : Colors.white;
  Color get card2 => dark ? const Color(0xFF2C2C2E) : const Color(0xFFF2F2F7);
  Color get bar => dark ? const Color(0x2EFFFFFF) : const Color(0x14000000);
  Color get barStrong => dark ? const Color(0x52FFFFFF) : const Color(0x2B000000);
  Color get hairline => dark ? const Color(0x1AFFFFFF) : const Color(0x0F000000);
  Color get muted => dark ? const Color(0x8CFFFFFF) : const Color(0x66000000);

  List<BoxShadow> shadow({double blur = 18, double y = 8, double strength = 1}) =>
      [
        BoxShadow(
          color: dark
              ? Color.fromRGBO(0, 0, 0, 0.55 * strength)
              : Color.fromRGBO(28, 36, 64, 0.12 * strength),
          blurRadius: blur,
          offset: Offset(0, y),
        ),
      ];
}

class _OnboardingArt extends StatelessWidget {
  final _ArtKind kind;
  final Color accent;
  final Color accent2;
  final bool dark;

  const _OnboardingArt({
    required this.kind,
    required this.accent,
    required this.accent2,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    final ink = _Ink(dark);
    final sys = _SysColors(dark);
    return switch (kind) {
      _ArtKind.welcome => _WelcomeArt(ink: ink, sys: sys),
      _ArtKind.library => _LibraryArt(ink: ink, sys: sys),
      _ArtKind.browse => _BrowseArt(ink: ink, sys: sys),
      _ArtKind.gestures => _GestureArt(ink: ink, sys: sys),
      _ArtKind.privacy => _PrivacyArt(ink: ink, sys: sys),
    };
  }
}

/// Soft gradient squircle plate shared by the feature illustrations.
class _Backplate extends StatelessWidget {
  final Color a;
  final Color b;
  final bool dark;

  const _Backplate({required this.a, required this.b, required this.dark});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 224,
        height: 224,
        decoration: ShapeDecoration(
          shape: ContinuousRectangleBorder(
            borderRadius: BorderRadius.circular(128),
            side: BorderSide(
              color: dark ? const Color(0x14FFFFFF) : const Color(0x0A000000),
            ),
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              a.withValues(alpha: dark ? 0.30 : 0.16),
              b.withValues(alpha: dark ? 0.14 : 0.07),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlyphBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final _Ink ink;
  final double ring;

  const _GlyphBadge({
    required this.icon,
    required this.color,
    required this.size,
    required this.ink,
    this.ring = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, Colors.white, 0.18)!, color],
        ),
        border: ring > 0 ? Border.all(color: ink.card, width: ring) : null,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: ink.dark ? 0.45 : 0.32),
            blurRadius: size * 0.4,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: Colors.white),
    );
  }
}

class _Bar extends StatelessWidget {
  final double width;
  final double height;
  final Color color;

  const _Bar(this.width, this.height, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  final double size;
  final Color color;
  final IconData icon;

  const _AppTile({required this.size, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        shape: ContinuousRectangleBorder(
          borderRadius: BorderRadius.circular(size * 0.5),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, Colors.white, 0.15)!, color],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.56, color: Colors.white),
    );
  }
}

// 1. Welcome --------------------------------------------------------------

class _WelcomeArt extends StatelessWidget {
  final _Ink ink;
  final _SysColors sys;

  const _WelcomeArt({required this.ink, required this.sys});

  @override
  Widget build(BuildContext context) {
    const c = Offset(120, 120);
    Widget orbit(double deg, double r, double size, IconData icon, Color color) {
      final rad = deg * math.pi / 180;
      return Positioned(
        left: c.dx + r * math.cos(rad) - size / 2,
        top: c.dy + r * math.sin(rad) - size / 2,
        child: _GlyphBadge(icon: icon, color: color, size: size, ink: ink),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  sys.blue.withValues(alpha: ink.dark ? 0.34 : 0.20),
                  sys.indigo.withValues(alpha: ink.dark ? 0.14 : 0.07),
                  sys.indigo.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _RingsPainter(
              color: ink.dark ? const Color(0xFFFFFFFF) : const Color(0xFF1C2440),
              radii: const [62, 88, 112],
              alphas: ink.dark ? const [0.16, 0.10, 0.06] : const [0.10, 0.07, 0.04],
            ),
          ),
        ),
        Center(
          child: Container(
            width: 108,
            height: 108,
            decoration: ShapeDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF262C40), Color(0xFF111420)],
              ),
              shape: ContinuousRectangleBorder(
                borderRadius: BorderRadius.circular(54),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 1.2,
                ),
              ),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: ink.dark ? 0.45 : 0.14),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Image.asset(
              'assets/logo_mark.png',
              width: 78,
              height: 78,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) =>
                  Icon(CupertinoIcons.film_fill, size: 48, color: sys.blue),
            ),
          ),
        ),
        orbit(-42, 88, 34, CupertinoIcons.play_fill, sys.blue),
        orbit(38, 108, 30, CupertinoIcons.cloud_fill, sys.teal),
        orbit(142, 88, 32, CupertinoIcons.checkmark_shield_fill, sys.green),
        orbit(218, 108, 28, CupertinoIcons.sparkles, sys.indigo),
      ],
    );
  }
}

class _RingsPainter extends CustomPainter {
  final Color color;
  final List<double> radii;
  final List<double> alphas;

  const _RingsPainter({
    required this.color,
    required this.radii,
    required this.alphas,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < radii.length; i++) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: alphas[i]);
      canvas.drawCircle(center, radii[i], paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingsPainter old) =>
      old.color != color || old.radii != radii || old.alphas != alphas;
}

// 2. Library --------------------------------------------------------------

class _LibraryArt extends StatelessWidget {
  final _Ink ink;
  final _SysColors sys;

  const _LibraryArt({required this.ink, required this.sys});

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, Color color, double w1, double w2, bool last) {
      return Container(
        height: 38,
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: ink.hairline, width: 1)),
        ),
        child: Row(
          children: [
            _AppTile(size: 24, color: color, icon: icon),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Bar(w1, 6, ink.barStrong),
                  const SizedBox(height: 5),
                  _Bar(w2, 5, ink.bar),
                ],
              ),
            ),
            Icon(CupertinoIcons.checkmark_circle_fill, size: 15, color: sys.green),
          ],
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        _Backplate(a: sys.orange, b: sys.blue, dark: ink.dark),
        // Subscription URL field.
        Positioned(
          left: 34,
          top: 30,
          width: 172,
          height: 34,
          child: Container(
            padding: const EdgeInsets.only(left: 12, right: 5),
            decoration: BoxDecoration(
              color: ink.card,
              borderRadius: BorderRadius.circular(17),
              boxShadow: ink.shadow(blur: 14, y: 5),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.link, size: 14, color: sys.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _Bar(82, 6, ink.bar),
                  ),
                ),
                Container(
                  width: 40,
                  height: 24,
                  decoration: BoxDecoration(
                    color: sys.blue,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    CupertinoIcons.arrow_down,
                    size: 13,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Library list card.
        Positioned(
          left: 34,
          top: 78,
          width: 172,
          height: 132,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: ShapeDecoration(
              color: ink.card,
              shape: ContinuousRectangleBorder(
                borderRadius: BorderRadius.circular(40),
              ),
              shadows: ink.shadow(),
            ),
            child: Column(
              children: [
                row(CupertinoIcons.film_fill, sys.orange, 66, 42, false),
                row(CupertinoIcons.folder_fill, sys.blue, 78, 50, false),
                row(CupertinoIcons.cloud_fill, sys.teal, 58, 38, true),
              ],
            ),
          ),
        ),
        Positioned(
          left: 184,
          top: 60,
          child: _GlyphBadge(
            icon: CupertinoIcons.plus,
            color: sys.blue,
            size: 40,
            ink: ink,
            ring: 3,
          ),
        ),
        Positioned(
          left: 16,
          top: 180,
          child: _GlyphBadge(
            icon: CupertinoIcons.arrow_2_circlepath,
            color: sys.green,
            size: 38,
            ink: ink,
            ring: 3,
          ),
        ),
      ],
    );
  }
}

// 3. Browse ---------------------------------------------------------------

class _BrowseArt extends StatelessWidget {
  final _Ink ink;
  final _SysColors sys;

  const _BrowseArt({required this.ink, required this.sys});

  static const List<List<Color>> _posters = [
    [Color(0xFF3E5BA9), Color(0xFF1B2547)],
    [Color(0xFFE0844A), Color(0xFF7A2E1E)],
    [Color(0xFF2E8C83), Color(0xFF123A3A)],
    [Color(0xFF8B4FC9), Color(0xFF2E1847)],
    [Color(0xFFD5576B), Color(0xFF5A1A2C)],
    [Color(0xFF4A9BD8), Color(0xFF173954)],
  ];

  @override
  Widget build(BuildContext context) {
    final frame = ink.dark ? const Color(0xFF3A3A3C) : const Color(0xFF1C1C1E);
    final screen = ink.dark ? const Color(0xFF0E0E10) : const Color(0xFFF2F2F7);
    final glass = ink.dark ? const Color(0xFF2C2C2E) : Colors.white;

    Widget poster(int i) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _posters[i % _posters.length],
          ),
        ),
      );
    }

    Widget menuRow(IconData icon, Color color, double w, bool last) {
      return Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: ink.hairline, width: 1)),
        ),
        child: Row(
          children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: _Bar(w, 5, ink.barStrong))),
            Icon(icon, size: 11, color: color),
          ],
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        _Backplate(a: sys.indigo, b: sys.teal, dark: ink.dark),
        // Phone mockup.
        Positioned(
          left: 44,
          top: 10,
          width: 118,
          height: 220,
          child: Container(
            decoration: BoxDecoration(
              color: screen,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: frame, width: 4),
              boxShadow: ink.shadow(blur: 22, y: 10),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: [
                  Positioned(
                    left: 10,
                    top: 14,
                    child: _Bar(44, 7, ink.barStrong),
                  ),
                  Positioned(
                    left: 10,
                    top: 28,
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 10,
                          decoration: BoxDecoration(
                            color: sys.blue,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        const SizedBox(width: 4),
                        _Bar(18, 10, ink.bar),
                        const SizedBox(width: 4),
                        _Bar(22, 10, ink.bar),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    top: 46,
                    height: 150,
                    child: GridView.count(
                      crossAxisCount: 3,
                      mainAxisSpacing: 5,
                      crossAxisSpacing: 5,
                      childAspectRatio: 0.68,
                      padding: EdgeInsets.zero,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [for (var i = 0; i < 9; i++) poster(i)],
                    ),
                  ),
                  // Floating Dock + search.
                  Positioned(
                    left: 8,
                    bottom: 9,
                    child: Container(
                      width: 72,
                      height: 24,
                      decoration: BoxDecoration(
                        color: glass,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: ink.shadow(blur: 8, y: 2, strength: 1.4),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Icon(CupertinoIcons.house_fill, size: 11, color: sys.blue),
                          Icon(CupertinoIcons.tv_fill, size: 11, color: ink.muted),
                          Icon(CupertinoIcons.rectangle_stack_fill, size: 11, color: ink.muted),
                          Icon(CupertinoIcons.gear_alt_fill, size: 11, color: ink.muted),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 9,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: glass,
                        shape: BoxShape.circle,
                        boxShadow: ink.shadow(blur: 8, y: 2, strength: 1.4),
                      ),
                      child: Icon(CupertinoIcons.search, size: 11, color: sys.blue),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Long-press quick menu.
        Positioned(
          left: 118,
          top: 120,
          width: 100,
          child: Container(
            decoration: BoxDecoration(
              color: ink.dark ? const Color(0xFF2C2C2E) : Colors.white,
              borderRadius: BorderRadius.circular(13),
              boxShadow: ink.shadow(blur: 20, y: 8, strength: 1.3),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                menuRow(CupertinoIcons.heart_fill, sys.pink, 42, false),
                menuRow(CupertinoIcons.clock_fill, sys.orange, 52, false),
                menuRow(CupertinoIcons.plus_circle_fill, sys.blue, 36, true),
              ],
            ),
          ),
        ),
        // Touch indicator on the Dock button.
        Positioned(
          left: 112,
          top: 190,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: sys.indigo.withValues(alpha: 0.22),
              border: Border.all(
                color: sys.indigo.withValues(alpha: 0.55),
                width: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// 4. Gestures -------------------------------------------------------------

class _GestureArt extends StatelessWidget {
  final _Ink ink;
  final _SysColors sys;

  const _GestureArt({required this.ink, required this.sys});

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    Widget vSlider(IconData icon, double fill) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: white),
          const SizedBox(height: 4),
          Container(
            width: 5,
            height: 44,
            decoration: BoxDecoration(
              color: white.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: fill,
              child: Container(
                decoration: BoxDecoration(
                  color: white,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      );
    }

    Widget chip(IconData icon, Color color) {
      return Container(
        width: 98,
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: ink.card,
          borderRadius: BorderRadius.circular(19),
          boxShadow: ink.shadow(blur: 14, y: 5),
        ),
        child: Row(
          children: [
            _AppTile(size: 26, color: color, icon: icon),
            const SizedBox(width: 8),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Bar(40, 5, ink.barStrong),
                const SizedBox(height: 4),
                _Bar(26, 4, ink.bar),
              ],
            ),
          ],
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        _Backplate(a: sys.purple, b: sys.blue, dark: ink.dark),
        Positioned(
          left: 12,
          top: 40,
          width: 216,
          height: 126,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: ink.shadow(blur: 24, y: 10, strength: 1.4),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _ScenePainter()),
                  ),
                  // Speed badge (long press).
                  Positioned(
                    top: 9,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.forward_fill, size: 9, color: white),
                            SizedBox(width: 3),
                            Text(
                              '2×',
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                color: white,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Center play / pause.
                  Center(
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: white.withValues(alpha: 0.22),
                        border: Border.all(color: white.withValues(alpha: 0.35)),
                      ),
                      child: const Icon(CupertinoIcons.pause_fill, size: 17, color: white),
                    ),
                  ),
                  Positioned(left: 12, top: 30, child: vSlider(CupertinoIcons.sun_max_fill, 0.7)),
                  Positioned(right: 12, top: 30, child: vSlider(CupertinoIcons.speaker_2_fill, 0.45)),
                  // Double-tap ripple on the right side.
                  Positioned(
                    left: 138,
                    top: 36,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: white.withValues(alpha: 0.35), width: 1.5),
                      ),
                      alignment: Alignment.center,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: white.withValues(alpha: 0.26),
                        ),
                        child: const Icon(CupertinoIcons.goforward_10, size: 15, color: white),
                      ),
                    ),
                  ),
                  // Progress bar.
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 13,
                    height: 12,
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final w = c.maxWidth;
                        return Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Container(
                              height: 3.5,
                              decoration: BoxDecoration(
                                color: white.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Container(
                              width: w * 0.46,
                              height: 3.5,
                              decoration: BoxDecoration(
                                color: white,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Positioned(
                              left: w * 0.46 - 6,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: white,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  // Horizontal swipe hint above the progress bar.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 28,
                    child: Center(
                      child: Icon(
                        CupertinoIcons.arrow_left_right,
                        size: 14,
                        color: white.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 14,
          top: 180,
          child: chip(CupertinoIcons.rectangle_on_rectangle, sys.indigo),
        ),
        Positioned(
          left: 128,
          top: 180,
          child: chip(CupertinoIcons.tv_fill, sys.teal),
        ),
      ],
    );
  }
}

/// Minimal cinematic scene (dusk sky, sun, layered hills) for the player
/// mockup; static painting only.
class _ScenePainter extends CustomPainter {
  const _ScenePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF29335C), Color(0xFF7D4E7A), Color(0xFFF0A26A)],
          stops: [0.0, 0.62, 1.0],
        ).createShader(rect),
    );
    canvas.drawCircle(
      Offset(size.width * 0.34, size.height * 0.58),
      size.height * 0.14,
      Paint()..color = const Color(0xFFFFD9A0).withValues(alpha: 0.85),
    );
    final far = Path()
      ..moveTo(0, size.height * 0.70)
      ..quadraticBezierTo(size.width * 0.22, size.height * 0.52,
          size.width * 0.45, size.height * 0.68)
      ..quadraticBezierTo(size.width * 0.70, size.height * 0.50,
          size.width, size.height * 0.64)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(far, Paint()..color = const Color(0xFF4A3463));
    final near = Path()
      ..moveTo(0, size.height * 0.84)
      ..quadraticBezierTo(size.width * 0.35, size.height * 0.68,
          size.width * 0.62, size.height * 0.82)
      ..quadraticBezierTo(size.width * 0.85, size.height * 0.74,
          size.width, size.height * 0.80)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(near, Paint()..color = const Color(0xFF231A36));
    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFF000000).withValues(alpha: 0.12),
    );
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => false;
}

// 5. Library & privacy ----------------------------------------------------

class _PrivacyArt extends StatelessWidget {
  final _Ink ink;
  final _SysColors sys;

  const _PrivacyArt({required this.ink, required this.sys});

  @override
  Widget build(BuildContext context) {
    Widget poster({
      required List<Color> colors,
      required double w,
      required double h,
      double progress = 0,
    }) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: colors,
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: ink.dark ? 0.12 : 0.5),
            width: 1,
          ),
          boxShadow: ink.shadow(blur: 16, y: 8, strength: 1.3),
        ),
        padding: const EdgeInsets.fromLTRB(9, 9, 9, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: w * 0.34,
              height: w * 0.34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.18),
              ),
            ),
            const Spacer(),
            _Bar(w * 0.62, 6, Colors.white.withValues(alpha: 0.85)),
            const SizedBox(height: 5),
            _Bar(w * 0.40, 5, Colors.white.withValues(alpha: 0.5)),
            if (progress > 0) ...[
              const SizedBox(height: 8),
              Container(
                height: 3.5,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress,
                  child: Container(
                    decoration: BoxDecoration(
                      color: sys.pink,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        _Backplate(a: sys.pink, b: sys.purple, dark: ink.dark),
        Positioned(
          left: 22,
          top: 50,
          child: Transform.rotate(
            angle: -0.19,
            child: poster(
              colors: const [Color(0xFF3F7FD9), Color(0xFF1A2E5C)],
              w: 80,
              h: 118,
            ),
          ),
        ),
        Positioned(
          left: 138,
          top: 50,
          child: Transform.rotate(
            angle: 0.19,
            child: poster(
              colors: const [Color(0xFF2FA58A), Color(0xFF103B37)],
              w: 80,
              h: 118,
            ),
          ),
        ),
        Positioned(
          left: 74,
          top: 30,
          child: poster(
            colors: const [Color(0xFFF07A5A), Color(0xFF6E1F3B)],
            w: 92,
            h: 136,
            progress: 0.62,
          ),
        ),
        // Remove (long press) hint on the left poster.
        Positioned(
          left: 18,
          top: 40,
          child: Container(
            decoration: BoxDecoration(shape: BoxShape.circle, color: ink.card),
            padding: const EdgeInsets.all(1.5),
            child: Icon(CupertinoIcons.xmark_circle_fill, size: 22, color: sys.red),
          ),
        ),
        Positioned(
          left: 150,
          top: 18,
          child: _GlyphBadge(
            icon: CupertinoIcons.heart_fill,
            color: sys.pink,
            size: 34,
            ink: ink,
            ring: 3,
          ),
        ),
        Positioned(
          left: 34,
          top: 176,
          child: _GlyphBadge(
            icon: CupertinoIcons.arrow_down,
            color: sys.green,
            size: 40,
            ink: ink,
            ring: 3,
          ),
        ),
        Positioned(
          left: 150,
          top: 166,
          child: Container(
            width: 56,
            height: 56,
            decoration: ShapeDecoration(
              shape: ContinuousRectangleBorder(
                borderRadius: BorderRadius.circular(30),
                side: BorderSide(color: ink.card, width: 3),
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [sys.indigo, sys.purple],
              ),
              shadows: [
                BoxShadow(
                  color: sys.indigo.withValues(alpha: ink.dark ? 0.5 : 0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: const Icon(
              CupertinoIcons.lock_shield_fill,
              size: 28,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
