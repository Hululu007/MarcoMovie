// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ohos_runtime.dart';
import 'apple_theme.dart';

/// Official author social media and website constants for macOS.
abstract final class MacosOfficialInfo {
  static const String authorSocialName = 'PILIPALA来信';
  static const List<String> socialPlatforms = <String>[
    '小红书',
    'B站',
    '抖音',
    '公众号',
    '视频号',
  ];
  static const String socialPlatformsSummary = '小红书、B站、抖音、公众号、视频号';
  static const String officialWebsiteDisplay = 'marcotv.wlj9919.top';
  static const String officialWebsiteUrl = 'https://marcotv.wlj9919.top';
  static const String securityWarning =
      '下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。';
}

/// Device-local preference tracking whether the macOS first-launch official
/// channel & security notice has been acknowledged.
///
/// Intentionally excluded from cross-device sync/backup schemas so every
/// macOS installation (including existing users upgrading from older versions)
/// sees the notice once on first launch.
class MacosOfficialNoticePrefs {
  static const String acknowledgedVersionKey =
      'macos_official_notice_ack_version';
  static const int currentVersion = 1;

  final SharedPreferences _prefs;

  const MacosOfficialNoticePrefs(this._prefs);

  static Future<MacosOfficialNoticePrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return MacosOfficialNoticePrefs(prefs);
  }

  int get acknowledgedVersion => _prefs.getInt(acknowledgedVersionKey) ?? 0;

  bool get isAcknowledged => acknowledgedVersion >= currentVersion;

  static bool isMacosTarget() =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.macOS &&
      !OhosRuntime.isOhos;

  bool shouldShow({bool? isMacosOverride}) {
    final isMacos = isMacosOverride ?? isMacosTarget();
    if (!isMacos) return false;
    return acknowledgedVersion < currentVersion;
  }

  Future<void> markAcknowledged() async {
    await _prefs.setInt(acknowledgedVersionKey, currentVersion);
  }
}

/// Opens [url] in the default macOS browser, falling back to `open` CLI.
/// Returns `true` when launched externally, or `false` if unavailable.
Future<bool> openMacosOfficialUrl(
  String url, {
  Future<bool> Function(Uri uri)? onOpenUrl,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  if (onOpenUrl != null) {
    return onOpenUrl(uri);
  }
  try {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (launched) return true;
  } catch (_) {}
  if (!kIsWeb && Platform.isMacOS) {
    try {
      final result = await Process.run('open', [uri.toString()]);
      return result.exitCode == 0;
    } catch (_) {}
  }
  return false;
}

/// Displays the macOS first-launch official channel & security notice modal.
///
/// Blocks dismissing via backdrop tap or Escape until the user explicitly taps
/// the confirmation button so the official website warning is clearly read
/// before entering onboarding or the main workspace. Returns `true` only when
/// confirmed by the user.
Future<bool?> showMacosFirstLaunchOfficialNoticeDialog(
  BuildContext context, {
  Future<bool> Function(Uri uri)? onOpenUrl,
  Future<void> Function(String text)? onCopyText,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.56),
    builder: (dialogCtx) => PopScope(
      canPop: false,
      child: _MacosOfficialNoticeDialog(
        onOpenUrl: onOpenUrl,
        onCopyText: onCopyText,
      ),
    ),
  );
}

class _MacosOfficialNoticeDialog extends StatefulWidget {
  final Future<bool> Function(Uri uri)? onOpenUrl;
  final Future<void> Function(String text)? onCopyText;

  const _MacosOfficialNoticeDialog({
    this.onOpenUrl,
    this.onCopyText,
  });

  @override
  State<_MacosOfficialNoticeDialog> createState() =>
      _MacosOfficialNoticeDialogState();
}

class _MacosOfficialNoticeDialogState
    extends State<_MacosOfficialNoticeDialog> {
  String? _feedbackMessage;
  Timer? _feedbackTimer;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _showInlineFeedback(String message) {
    _feedbackTimer?.cancel();
    if (!mounted) return;
    setState(() => _feedbackMessage = message);
    _feedbackTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _feedbackMessage = null);
      }
    });
  }

  Future<void> _copyText(String text, String label) async {
    if (widget.onCopyText != null) {
      await widget.onCopyText!(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    _showInlineFeedback('已复制$label：$text');
  }

  Future<void> _openWebsite() async {
    final opened = await openMacosOfficialUrl(
      MacosOfficialInfo.officialWebsiteUrl,
      onOpenUrl: widget.onOpenUrl,
    );
    if (!opened) {
      await _copyText(MacosOfficialInfo.officialWebsiteUrl, '官网地址');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final cardShape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(
        color: isDark
            ? Colors.white.withValues(alpha: 0.16)
            : Colors.black.withValues(alpha: 0.10),
        width: 0.8,
      ),
    );

    return Dialog(
      key: const ValueKey('macos-official-notice-dialog'),
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 468),
        child: Material(
          color: palette.glassSolid,
          shape: cardShape,
          elevation: 24,
          shadowColor: Colors.black.withValues(alpha: isDark ? 0.55 : 0.22),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const MarcoBrandLogo(
                      iconSize: 34,
                      fontSize: 18,
                      showWordmark: false,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '欢迎使用 Marco Movie',
                            style: TextStyle(
                              color: palette.labelPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '作者官方社媒与正版下载渠道说明',
                            style: TextStyle(
                              color: palette.labelSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                MacosOfficialInfoCards(
                  onCopySocialName: () => _copyText(
                    MacosOfficialInfo.authorSocialName,
                    '社媒账号名',
                  ),
                  onOpenWebsite: _openWebsite,
                  onCopyWebsite: () => _copyText(
                    MacosOfficialInfo.officialWebsiteUrl,
                    '官网地址',
                  ),
                  showGroupHint: false,
                ),
                if (_feedbackMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    key: const ValueKey('macos-official-notice-feedback'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppleColors.systemGreen
                          .withValues(alpha: isDark ? 0.18 : 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppleColors.systemGreen.withValues(alpha: 0.35),
                        width: 0.6,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          CupertinoIcons.checkmark_circle_fill,
                          size: 16,
                          color: AppleColors.systemGreen,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _feedbackMessage!,
                            style: TextStyle(
                              color: palette.labelPrimary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: AppleCapsuleButton(
                        key: const ValueKey('macos-official-notice-open-site'),
                        label: '访问官网',
                        icon: CupertinoIcons.globe,
                        onPressed: _openWebsite,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: AppleCapsuleButton(
                        key: const ValueKey('macos-official-notice-confirm'),
                        label: '我知道了',
                        icon: CupertinoIcons.checkmark_alt,
                        primary: true,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reusable macOS contact, social account, official website & safety warning
/// cards shared by the first-launch modal and the Settings contact sheet.
class MacosOfficialInfoCards extends StatelessWidget {
  final VoidCallback onCopySocialName;
  final VoidCallback onOpenWebsite;
  final VoidCallback onCopyWebsite;
  final bool showGroupHint;

  const MacosOfficialInfoCards({
    super.key,
    required this.onCopySocialName,
    required this.onOpenWebsite,
    required this.onCopyWebsite,
    this.showGroupHint = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Card 1: Author social media accounts
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.groupedSecondary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.glassBorder, width: 0.6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    CupertinoIcons.person_crop_circle_fill,
                    size: 17,
                    color: AppleColors.systemPink,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '作者各社媒账号名',
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _InlineActionChip(
                    key: const ValueKey('macos-copy-social-name'),
                    icon: CupertinoIcons.doc_on_doc,
                    label: '复制账号名',
                    onTap: onCopySocialName,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                MacosOfficialInfo.authorSocialName,
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final platform in MacosOfficialInfo.socialPlatforms)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.10)
                              : Colors.black.withValues(alpha: 0.07),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        platform,
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Card 2: Official website & community group link
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.groupedSecondary,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: palette.glassBorder, width: 0.6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    CupertinoIcons.globe,
                    size: 17,
                    color: AppleColors.systemBlue,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      showGroupHint ? 'Marco 官网与交流群' : 'Marco 官网',
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _InlineActionChip(
                    key: const ValueKey('macos-copy-official-website'),
                    icon: CupertinoIcons.doc_on_doc,
                    label: '复制网址',
                    onTap: onCopyWebsite,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              InkWell(
                key: const ValueKey('macos-official-website-link'),
                onTap: onOpenWebsite,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          MacosOfficialInfo.officialWebsiteDisplay,
                          style: const TextStyle(
                            color: AppleColors.systemBlue,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                            decorationColor: AppleColors.systemBlue,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        CupertinoIcons.arrow_up_right_square,
                        size: 15,
                        color: AppleColors.systemBlue,
                      ),
                    ],
                  ),
                ),
              ),
              if (showGroupHint) ...[
                const SizedBox(height: 6),
                Text(
                  '访问官网获取最新交流群入口与官方正版安装包。',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Card 3: Security warning callout
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppleColors.systemOrange
                .withValues(alpha: isDark ? 0.14 : 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppleColors.systemOrange.withValues(alpha: 0.36),
              width: 0.8,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(
                  CupertinoIcons.shield_lefthalf_fill,
                  size: 18,
                  color: AppleColors.systemOrange,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  MacosOfficialInfo.securityWarning,
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Modal sheet opened from macOS Settings -> 联系反馈作者.
class MacosAuthorContactSheet extends StatefulWidget {
  final Future<bool> Function(Uri uri)? onOpenUrl;
  final Future<void> Function(String text)? onCopyText;

  const MacosAuthorContactSheet({
    super.key,
    this.onOpenUrl,
    this.onCopyText,
  });

  @override
  State<MacosAuthorContactSheet> createState() =>
      _MacosAuthorContactSheetState();
}

class _MacosAuthorContactSheetState extends State<MacosAuthorContactSheet> {
  String? _feedbackMessage;
  Timer? _feedbackTimer;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  void _showInlineFeedback(String message) {
    _feedbackTimer?.cancel();
    if (!mounted) return;
    setState(() => _feedbackMessage = message);
    _feedbackTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _feedbackMessage = null);
      }
    });
  }

  Future<void> _copyText(String text, String label) async {
    if (widget.onCopyText != null) {
      await widget.onCopyText!(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    _showInlineFeedback('已复制$label：$text');
  }

  Future<void> _openWebsite() async {
    final opened = await openMacosOfficialUrl(
      MacosOfficialInfo.officialWebsiteUrl,
      onOpenUrl: widget.onOpenUrl,
    );
    if (!opened) {
      await _copyText(MacosOfficialInfo.officialWebsiteUrl, '官网地址');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;

    return SingleChildScrollView(
      key: const ValueKey('macos-author-contact-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '如需使用咨询、功能建议或问题反馈，可在以下平台搜索作者账号私信/留言，或前往官网加入官方交流群：',
            style: TextStyle(
              color: palette.labelSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          MacosOfficialInfoCards(
            onCopySocialName: () => _copyText(
              MacosOfficialInfo.authorSocialName,
              '社媒账号名',
            ),
            onOpenWebsite: _openWebsite,
            onCopyWebsite: () => _copyText(
              MacosOfficialInfo.officialWebsiteUrl,
              '官网地址',
            ),
            showGroupHint: true,
          ),
          if (_feedbackMessage != null) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('macos-contact-sheet-feedback'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppleColors.systemGreen
                    .withValues(alpha: isDark ? 0.18 : 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppleColors.systemGreen.withValues(alpha: 0.35),
                  width: 0.6,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    CupertinoIcons.checkmark_circle_fill,
                    size: 16,
                    color: AppleColors.systemGreen,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _feedbackMessage!,
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: AppleCapsuleButton(
                  key: const ValueKey('macos-contact-sheet-copy-social'),
                  label: '复制社媒账号名',
                  icon: CupertinoIcons.doc_on_doc,
                  onPressed: () => _copyText(
                    MacosOfficialInfo.authorSocialName,
                    '社媒账号名',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: AppleCapsuleButton(
                  key: const ValueKey('macos-contact-sheet-open-group'),
                  label: '打开官网交流群',
                  icon: CupertinoIcons.globe,
                  primary: true,
                  onPressed: _openWebsite,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlineActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _InlineActionChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return Material(
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12.5, color: palette.accent),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: palette.accent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
