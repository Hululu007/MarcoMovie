// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart'
    show Colors, Material, MaterialType, SelectableText;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'apple_theme.dart';

/// Official author social handles, website, community link, and anti-tamper
/// notice shown on first launch after install and in Settings.
abstract final class OfficialChannelInfo {
  static const String authorSocialName = 'PILIPALA来信';
  static const List<String> socialPlatforms = <String>[
    '小红书',
    'B站',
    '抖音',
    '公众号',
    '视频号',
  ];
  static const String socialPlatformsDisplay = '小红书、B站、抖音、公众号、视频号';
  static const String authorSocialSummary =
      '$authorSocialName（$socialPlatformsDisplay）';
  static const String officialWebsiteDisplay = 'marcotv.wlj9919.top';
  static const String officialWebsiteUrl = 'https://marcotv.wlj9919.top';
  static final Uri officialWebsiteUri = Uri.parse(officialWebsiteUrl);
  static const String officialCommunityUrl = officialWebsiteUrl;
  static final Uri officialCommunityUri = officialWebsiteUri;
  static const String antiTamperWarning =
      '下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。';
}

/// Tri-state result of attempting to open an external official link with
/// clipboard fallback.
enum OfficialLinkOpenStatus {
  /// System browser / handler accepted the URL.
  opened,

  /// External launch failed, and the URL was confirmed written to clipboard.
  copiedFallback,

  /// Both external launch and clipboard write failed.
  failed,
}

int _officialExplicitClipboardEpoch = 0;

/// Monotonic revision incremented on every explicit official-channel clipboard
/// copy so an older in-flight external-link fallback never overwrites a newer
/// user-initiated copy.
int get officialExplicitClipboardEpoch => _officialExplicitClipboardEpoch;

/// Marks the start of a new explicit official-channel clipboard copy and
/// returns the updated epoch.
int beginExplicitOfficialClipboardCopy() => ++_officialExplicitClipboardEpoch;

/// Writes [text] to the system clipboard and returns `true` ONLY when the
/// platform clipboard channel completes without throwing.
Future<bool> copyOfficialChannelText(String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    return true;
  } catch (_) {
    return false;
  }
}

/// Attempts ONLY to open [uri] in the system browser / external handler without
/// writing to the system clipboard.
Future<bool> launchExternalOfficialUrl(
  Uri uri, {
  Future<bool> Function(Uri uri)? urlOpener,
}) async {
  var opened = false;
  try {
    if (urlOpener != null) {
      opened = await urlOpener(uri).timeout(const Duration(seconds: 5));
    } else {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication)
          .timeout(const Duration(seconds: 5));
      if (!opened && !kIsWeb && Platform.isWindows) {
        final res = await Process.run('cmd', <String>[
          '/c',
          'start',
          '',
          uri.toString(),
        ]);
        opened = res.exitCode == 0;
      } else if (!opened && !kIsWeb && Platform.isMacOS) {
        final res = await Process.run('open', <String>[uri.toString()]);
        opened = res.exitCode == 0;
      }
    }
  } catch (_) {
    opened = false;
  }
  return opened;
}

/// Attempts to open [uri] in the system browser; when opening fails, checks
/// [shouldFallbackCopy] (if provided) before writing the URL to the clipboard,
/// and distinguishes all three outcomes:
/// [OfficialLinkOpenStatus.opened], [OfficialLinkOpenStatus.copiedFallback],
/// and [OfficialLinkOpenStatus.failed].
Future<OfficialLinkOpenStatus> openOfficialChannelUrl(
  Uri uri, {
  Future<bool> Function(Uri uri)? urlOpener,
  bool Function()? shouldFallbackCopy,
}) async {
  final opened = await launchExternalOfficialUrl(uri, urlOpener: urlOpener);
  if (opened) {
    return OfficialLinkOpenStatus.opened;
  }
  if (shouldFallbackCopy != null && !shouldFallbackCopy()) {
    return OfficialLinkOpenStatus.failed;
  }
  final copied = await copyOfficialChannelText(uri.toString());
  return copied
      ? OfficialLinkOpenStatus.copiedFallback
      : OfficialLinkOpenStatus.failed;
}

/// Presents a dialog containing manually selectable plain text when external
/// opening and/or clipboard writing fail.
Future<void> showOfficialChannelManualCopyDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String selectableValue,
}) async {
  activeAppleModalSheetCount.value++;
  try {
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        final p = ApplePalette.of(dialogCtx);
        return CupertinoAlertDialog(
          key: const ValueKey('official-channel-manual-copy-dialog'),
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message),
                const SizedBox(height: 10),
                Material(
                  type: MaterialType.transparency,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: p.isDark
                          ? const Color(0xFF2C2C2E)
                          : const Color(0xFFE5E5EA),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: SelectableText(
                        selectableValue,
                        key: const ValueKey(
                          'official-channel-manual-select-text',
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            CupertinoDialogAction(
              key: const ValueKey('official-channel-manual-copy-ok'),
              isDefaultAction: true,
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('好'),
            ),
          ],
        );
      },
    );
  } finally {
    if (activeAppleModalSheetCount.value > 0) {
      activeAppleModalSheetCount.value--;
    }
  }
}

/// Presents the official author / website anti-tamper dialog on first launch
/// (or on demand from Settings). Returns `true` when the user confirms, even
/// if the persistence callback reports failure or throws, so a non-essential
/// notice never traps the user out of the app.
Future<bool> showOfficialChannelNoticeDialog(
  BuildContext context, {
  Future<bool> Function(Uri uri)? urlOpener,
  Future<bool> Function()? onConfirm,
  bool barrierDismissible = false,
}) async {
  activeAppleModalSheetCount.value++;
  try {
    final result = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogCtx) => OfficialChannelNoticeDialog(
        urlOpener: urlOpener,
        barrierDismissible: barrierDismissible,
        onConfirm: () async {
          if (onConfirm != null) {
            try {
              await onConfirm();
            } catch (e) {
              debugPrint('OfficialChannelNotice persist failed (continuing): $e');
            }
          }
          if (dialogCtx.mounted) {
            Navigator.of(dialogCtx).pop(true);
          }
        },
      ),
    );
    return result == true;
  } finally {
    if (activeAppleModalSheetCount.value > 0) {
      activeAppleModalSheetCount.value--;
    }
  }
}

class OfficialChannelNoticeDialog extends StatefulWidget {
  final Future<bool> Function(Uri uri)? urlOpener;
  final Future<void> Function()? onConfirm;
  final bool barrierDismissible;

  const OfficialChannelNoticeDialog({
    super.key,
    this.urlOpener,
    this.onConfirm,
    this.barrierDismissible = false,
  });

  @override
  State<OfficialChannelNoticeDialog> createState() =>
      _OfficialChannelNoticeDialogState();
}

class _OfficialChannelNoticeDialogState
    extends State<OfficialChannelNoticeDialog> {
  String? _inlineFeedback;
  String? _manualSelectText;
  bool _confirming = false;
  bool _dismissed = false;
  int _actionEpoch = 0;
  bool _copyingSocialName = false;
  bool _openingWebsite = false;

  void _invalidatePendingActions() {
    _dismissed = true;
    _actionEpoch++;
  }

  bool _isDialogActive(ModalRoute<dynamic>? originRoute) {
    if (!mounted || _dismissed) return false;
    if (originRoute != null &&
        (!originRoute.isActive || !originRoute.isCurrent)) {
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    _invalidatePendingActions();
    super.dispose();
  }

  Future<void> _copySocialName() async {
    if (_copyingSocialName || _dismissed) return;
    _copyingSocialName = true;
    final originRoute = ModalRoute.of(context);
    final actionToken = _actionEpoch;
    final copyEpoch = beginExplicitOfficialClipboardCopy();
    try {
      final copied = await copyOfficialChannelText(
        OfficialChannelInfo.authorSocialName,
      );
      if (!_isDialogActive(originRoute) ||
          actionToken != _actionEpoch ||
          officialExplicitClipboardEpoch != copyEpoch) {
        return;
      }
      setState(() {
        if (copied) {
          _inlineFeedback =
              '已复制作者社媒账号名：${OfficialChannelInfo.authorSocialName}';
          _manualSelectText = null;
        } else {
          _inlineFeedback = '复制失败，请手动选取下方作者社媒账号名：';
          _manualSelectText = OfficialChannelInfo.authorSocialName;
        }
      });
    } finally {
      _copyingSocialName = false;
    }
  }

  Future<void> _openOfficialWebsite() async {
    if (_openingWebsite || _dismissed) return;
    _openingWebsite = true;
    final originRoute = ModalRoute.of(context);
    final actionToken = ++_actionEpoch;
    final startClipboardEpoch = officialExplicitClipboardEpoch;
    try {
      final opened = await launchExternalOfficialUrl(
        OfficialChannelInfo.officialWebsiteUri,
        urlOpener: widget.urlOpener,
      );
      if (!_isDialogActive(originRoute) || actionToken != _actionEpoch) {
        return;
      }
      if (opened) {
        if (officialExplicitClipboardEpoch != startClipboardEpoch) return;
        setState(() {
          _inlineFeedback =
              '正在打开官网：${OfficialChannelInfo.officialWebsiteUrl}';
          _manualSelectText = null;
        });
        return;
      }
      if (officialExplicitClipboardEpoch != startClipboardEpoch) {
        return;
      }
      final copied = await copyOfficialChannelText(
        OfficialChannelInfo.officialWebsiteUrl,
      );
      if (!_isDialogActive(originRoute) ||
          actionToken != _actionEpoch ||
          officialExplicitClipboardEpoch != startClipboardEpoch) {
        return;
      }
      setState(() {
        if (copied) {
          _inlineFeedback =
              '已复制官网地址，请在浏览器中打开：${OfficialChannelInfo.officialWebsiteUrl}';
          _manualSelectText = null;
        } else {
          _inlineFeedback = '无法自动打开或复制官网地址，请手动选取并在浏览器访问：';
          _manualSelectText = OfficialChannelInfo.officialWebsiteUrl;
        }
      });
    } finally {
      _openingWebsite = false;
    }
  }

  Future<void> _handleConfirm() async {
    if (_confirming || _dismissed) return;
    _invalidatePendingActions();
    setState(() => _confirming = true);
    try {
      if (widget.onConfirm != null) {
        await widget.onConfirm!();
      } else if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      debugPrint('OfficialChannelNotice confirm error (continuing): $e');
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) {
        setState(() => _confirming = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final media = MediaQuery.of(context);
    final isCompact = media.size.width < 360;
    final cardSurface = p.isDark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFFFFFFF);
    final groupSurface = p.isDark
        ? const Color(0xFF2C2C2E)
        : const Color(0xFFF2F2F7);
    final pillSurface = p.isDark
        ? const Color(0xFF3A3A3C)
        : const Color(0xFFE5E5EA);
    final warningBg = p.isDark
        ? const Color(0x2EFF9F0A)
        : const Color(0x1AFF9500);
    final warningBorder = p.isDark
        ? const Color(0x66FF9F0A)
        : const Color(0x55FF9500);
    final warningText = p.isDark
        ? const Color(0xFFFFD60A)
        : const Color(0xFF9A4E00);

    return PopScope(
      canPop: widget.barrierDismissible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _invalidatePendingActions();
        }
      },
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 14 : 22,
            vertical: 20,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: media.size.height * 0.86,
            ),
            child: Material(
              key: const ValueKey('official-channel-notice-dialog'),
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: cardSurface,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(26),
                    side: BorderSide(
                      color: p.isDark
                          ? const Color(0x28FFFFFF)
                          : const Color(0x18000000),
                      width: 0.75,
                    ),
                  ),
                  shadows: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: p.isDark ? 0.55 : 0.2),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      isCompact ? 16 : 22,
                      22,
                      isCompact ? 16 : 22,
                      18,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            DecoratedBox(
                              decoration: ShapeDecoration(
                                color: AppleColors.systemBlue,
                                shape: RoundedSuperellipseBorder(
                                  borderRadius: BorderRadius.circular(11),
                                ),
                              ),
                              child: const SizedBox(
                                width: 38,
                                height: 38,
                                child: Icon(
                                  CupertinoIcons.shield_lefthalf_fill,
                                  color: Colors.white,
                                  size: 21,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '官方渠道与作者声明',
                                    style: TextStyle(
                                      color: p.labelPrimary,
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Marco Movie 首次启动安全提醒',
                                    style: TextStyle(
                                      color: p.labelSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: groupSurface,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '作者各社媒账号名',
                                            style: TextStyle(
                                              color: p.labelSecondary,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            OfficialChannelInfo
                                                .authorSocialName,
                                            style: TextStyle(
                                              color: p.labelPrimary,
                                              fontSize: 17.5,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    CupertinoButton(
                                      key: const ValueKey(
                                        'official-channel-copy-social',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      minimumSize: const Size(44, 34),
                                      color:
                                          p.systemBlue.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(18),
                                      onPressed: _copySocialName,
                                      child: Text(
                                        '复制',
                                        style: TextStyle(
                                          color: p.systemBlue,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final platform
                                        in OfficialChannelInfo.socialPlatforms)
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: pillSurface,
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                          child: Text(
                                            platform,
                                            style: TextStyle(
                                              color: p.labelPrimary,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: groupSurface,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Marco 官网',
                                        style: TextStyle(
                                          color: p.labelSecondary,
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        OfficialChannelInfo
                                            .officialWebsiteDisplay,
                                        style: TextStyle(
                                          color: p.systemBlue,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                CupertinoButton(
                                  key: const ValueKey(
                                    'official-channel-open-site',
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  minimumSize: const Size(44, 34),
                                  color: p.systemBlue.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(18),
                                  onPressed: _openOfficialWebsite,
                                  child: Text(
                                    '打开官网',
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
                        ),
                        const SizedBox(height: 12),
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: warningBg,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: warningBorder, width: 0.8),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 11,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Icon(
                                    CupertinoIcons.exclamationmark_shield_fill,
                                    color: warningText,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    OfficialChannelInfo.antiTamperWarning,
                                    style: TextStyle(
                                      color: warningText,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      height: 1.45,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_inlineFeedback != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _inlineFeedback!,
                            key: const ValueKey('official-channel-feedback'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.labelSecondary,
                              fontSize: 12.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                        if (_manualSelectText != null) ...[
                          const SizedBox(height: 6),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: groupSurface,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: SelectableText(
                                _manualSelectText!,
                                key: const ValueKey(
                                  'official-channel-manual-select-text',
                                ),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: p.labelPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        SizedBox(
                          height: 48,
                          child: CupertinoButton(
                            key: const ValueKey(
                              'official-channel-notice-confirm',
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            color: AppleColors.systemBlue,
                            borderRadius: BorderRadius.circular(14),
                            onPressed: _confirming ? null : _handleConfirm,
                            child: const Text(
                              '我知道了',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
