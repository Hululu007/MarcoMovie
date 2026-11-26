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
  static const String officialDonateUrl =
      'https://marcotv.wlj9919.top/movie/#donate';
  static final Uri officialDonateUri = Uri.parse(officialDonateUrl);
  static const String officialCommunityUrl = officialWebsiteUrl;
  static final Uri officialCommunityUri = officialWebsiteUri;
  static const String marcoCommunityChannelName = 'Marco交流区';
  static const String marcoCommunityChannelUrl =
      'https://pd.qq.com/s/N45e3aaawv?b=9';
  static final Uri marcoCommunityChannelUri =
      Uri.parse(marcoCommunityChannelUrl);
  static const String antiTamperWarning =
      '下载软件请认准官网地址，以防不明渠道软件添加病毒等不良内容。';
  static const String antiScamWarning =
      'Marco Movie 永久免费、无广告、无会员与付费激活码。任何在闲鱼、电商平台或群聊收费售卖安装包、「内部版」或代配置的均为骗局，切勿付款受骗。';
  static const String soleOfficialChannelNotice =
      '官网 marcotv.wlj9919.top 与应用内「设置 → 关于与更新」为唯一官方更新渠道，请勿安装来路不明的第三方改包。';
  static const String warmSponsorTitle = '深夜打磨 · 感恩同行';
  static const String warmSponsorBody =
      'Marco Movie 由独立开发者利用业余深夜一点点打磨而成，始终坚持纯粹免费、无广告、无商业套路。'
      '如果它曾陪你度过一段松弛惬意的观影时光，欢迎量力前往官网请作者喝杯热茶，让这份热爱走得更远；'
      '当然，你的每一次安心使用与口碑推荐，本身就是最珍贵的支持。';
  static const String postUpdateSponsorBody =
      '独立开发全凭热爱与大家的包容支撑至今。若新版本让你用得顺手舒心，不妨顺路前往官网捐赠区支持一杯热咖啡，全凭自愿，分文不取亦由衷感谢你的陪伴。';
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

/// Warm, non-intrusive developer gratitude & voluntary sponsorship card shown
/// in Settings -> About & Update (`设置 → 关于与更新`) with a one-tap jump to
/// the official website's `#donate` section.
class IosSupportDeveloperCard extends StatefulWidget {
  final Future<bool> Function(Uri uri)? urlOpener;

  const IosSupportDeveloperCard({
    super.key,
    this.urlOpener,
  });

  @override
  State<IosSupportDeveloperCard> createState() =>
      _IosSupportDeveloperCardState();
}

class _IosSupportDeveloperCardState extends State<IosSupportDeveloperCard> {
  bool _opening = false;
  String? _feedback;

  Future<void> _handleOpenDonate() async {
    if (_opening) return;
    HapticFeedback.selectionClick();
    setState(() {
      _opening = true;
      _feedback = null;
    });
    try {
      final status = await openOfficialChannelUrl(
        OfficialChannelInfo.officialDonateUri,
        urlOpener: widget.urlOpener,
      );
      if (!mounted) return;
      if (status == OfficialLinkOpenStatus.opened) {
        setState(() {
          _feedback = '正在前往官网捐赠支持区…';
        });
      } else if (status == OfficialLinkOpenStatus.copiedFallback) {
        setState(() {
          _feedback =
              '已复制官网捐赠区链接，可在浏览器粘贴打开：${OfficialChannelInfo.officialDonateUrl}';
        });
      } else {
        await showOfficialChannelManualCopyDialog(
          context,
          title: '官网捐赠支持地址',
          message: '请复制下方地址在浏览器打开：',
          selectableValue: OfficialChannelInfo.officialDonateUrl,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final cardBg = p.isDark ? const Color(0xFF1C1C20) : Colors.white;
    final borderCol = p.isDark
        ? const Color(0x26FF6B8B)
        : const Color(0x28FF2D55);
    final accentWarm = p.isDark
        ? const Color(0xFFFF6482)
        : const Color(0xFFE11D48);

    return DecoratedBox(
      key: const ValueKey('ios-about-donate-card'),
      decoration: ShapeDecoration(
        color: cardBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: borderCol, width: 0.8),
        ),
        shadows: [
          if (!p.isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFFF5E7E), Color(0xFFFF8A5B)],
                    ),
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(
                      CupertinoIcons.heart_fill,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        OfficialChannelInfo.warmSponsorTitle,
                        style: TextStyle(
                          color: p.labelPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '全凭自愿 · 免费无广 · 不影响任何功能',
                        style: TextStyle(
                          color: p.labelSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              OfficialChannelInfo.warmSponsorBody,
              style: TextStyle(
                color: p.labelSecondary,
                fontSize: 13.5,
                height: 1.52,
              ),
            ),
            if (_feedback != null) ...[
              const SizedBox(height: 10),
              Text(
                _feedback!,
                key: const ValueKey('ios-about-donate-feedback'),
                style: TextStyle(
                  color: accentWarm,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 14),
            SizedBox(
              height: 42,
              child: CupertinoButton(
                key: const ValueKey('ios-about-donate-jump-btn'),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                color: accentWarm.withValues(alpha: p.isDark ? 0.18 : 0.11),
                borderRadius: BorderRadius.circular(12),
                onPressed: _opening ? null : _handleOpenDonate,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      CupertinoIcons.heart_circle_fill,
                      color: accentWarm,
                      size: 18,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      '前往官网捐赠区支持一杯热茶',
                      style: TextStyle(
                        color: accentWarm,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      CupertinoIcons.arrow_up_right,
                      color: accentWarm,
                      size: 14,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Presents the one-time-per-version post-update notice dialog containing:
/// 1. Anti-scam / never-pay warning (`谨防受骗`)
/// 2. Official website as sole authentic update channel (`官网为唯一更新渠道`)
/// 3. Sincere developer note & optional sponsorship link (`温情致谢与自愿赞助`).
Future<bool> showPostUpdateWelcomeDialog(
  BuildContext context, {
  required String version,
  Future<bool> Function(Uri uri)? urlOpener,
  Future<bool> Function()? onConfirm,
  bool barrierDismissible = false,
}) async {
  activeAppleModalSheetCount.value++;
  try {
    final result = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogCtx) => PostUpdateWelcomeDialog(
        version: version,
        urlOpener: urlOpener,
        barrierDismissible: barrierDismissible,
        onConfirm: () async {
          if (onConfirm != null) {
            try {
              await onConfirm();
            } catch (e) {
              debugPrint('PostUpdateWelcomeDialog persist failed: $e');
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

class PostUpdateWelcomeDialog extends StatefulWidget {
  final String version;
  final Future<bool> Function(Uri uri)? urlOpener;
  final Future<void> Function()? onConfirm;
  final bool barrierDismissible;

  const PostUpdateWelcomeDialog({
    super.key,
    required this.version,
    this.urlOpener,
    this.onConfirm,
    this.barrierDismissible = false,
  });

  @override
  State<PostUpdateWelcomeDialog> createState() =>
      _PostUpdateWelcomeDialogState();
}

class _PostUpdateWelcomeDialogState extends State<PostUpdateWelcomeDialog> {
  String? _feedback;
  bool _busy = false;
  bool _dismissed = false;

  @override
  void dispose() {
    _dismissed = true;
    super.dispose();
  }

  Future<void> _openTarget(Uri uri, String label) async {
    if (_busy || _dismissed) return;
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    try {
      final status = await openOfficialChannelUrl(
        uri,
        urlOpener: widget.urlOpener,
        shouldFallbackCopy: () => mounted && !_dismissed,
      );
      if (!mounted || _dismissed) return;
      setState(() {
        if (status == OfficialLinkOpenStatus.opened) {
          _feedback = '正在打开$label…';
        } else if (status == OfficialLinkOpenStatus.copiedFallback) {
          _feedback = '已复制$label链接：${uri.toString()}';
        } else {
          _feedback = '请访问官网：${OfficialChannelInfo.officialWebsiteDisplay}';
        }
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _copyAuthor() async {
    final ok = await copyOfficialChannelText(
      OfficialChannelInfo.authorSocialName,
    );
    if (!mounted || _dismissed) return;
    setState(() {
      _feedback = ok
          ? '已复制作者全网同名账号：${OfficialChannelInfo.authorSocialName}'
          : '作者账号名：${OfficialChannelInfo.authorSocialName}';
    });
  }

  Future<void> _confirm() async {
    if (_dismissed) return;
    _dismissed = true;
    if (widget.onConfirm != null) {
      await widget.onConfirm!();
    } else if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = ApplePalette.of(context);
    final media = MediaQuery.of(context);
    final isCompact = media.size.width < 360;
    final cardBg = p.isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final sectionBg =
        p.isDark ? const Color(0xFF28282C) : const Color(0xFFF3F4F8);
    final warmBg =
        p.isDark ? const Color(0x24FF6482) : const Color(0x14E11D48);
    final warmAccent =
        p.isDark ? const Color(0xFFFF6482) : const Color(0xFFE11D48);
    final warnBg =
        p.isDark ? const Color(0x28FF9F0A) : const Color(0x16D97706);
    final warnInk =
        p.isDark ? const Color(0xFFFFD60A) : const Color(0xFFB45309);

    return PopScope(
      canPop: widget.barrierDismissible,
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 14 : 22,
            vertical: 20,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 430,
              maxHeight: media.size.height * 0.88,
            ),
            child: Material(
              key: const ValueKey('post-update-welcome-dialog'),
              type: MaterialType.transparency,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: cardBg,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(26),
                    side: BorderSide(
                      color: p.isDark
                          ? const Color(0x28FFFFFF)
                          : const Color(0x16000000),
                      width: 0.75,
                    ),
                  ),
                  shadows: [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: p.isDark ? 0.56 : 0.18),
                      blurRadius: 32,
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
                            const MarcoBrandLogo(
                              iconSize: 38,
                              showWordmark: false,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.version.trim().isEmpty
                                        ? '欢迎使用新版 Marco Movie'
                                        : '欢迎升级至 v${widget.version.trim()}',
                                    style: TextStyle(
                                      color: p.labelPrimary,
                                      fontSize: 18.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '安全防骗提醒 · 官方渠道声明 · 开发者寄语',
                                    style: TextStyle(
                                      color: p.labelSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 15),
                        // 1. 谨防受骗
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: warnBg,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(15),
                              side: BorderSide(
                                color: warnInk.withValues(alpha: 0.35),
                                width: 0.7,
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(13),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 1),
                                  child: Icon(
                                    CupertinoIcons.exclamationmark_shield_fill,
                                    color: warnInk,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '谨防受骗 · 本软件永久免费',
                                        style: TextStyle(
                                          color: warnInk,
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        OfficialChannelInfo.antiScamWarning,
                                        style: TextStyle(
                                          color: warnInk.withValues(alpha: 0.92),
                                          fontSize: 12.8,
                                          height: 1.45,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // 2. 官网为唯一更新渠道
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: sectionBg,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(13),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      CupertinoIcons.checkmark_seal_fill,
                                      color: p.systemBlue,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '认准官网唯一更新渠道',
                                        style: TextStyle(
                                          color: p.labelPrimary,
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    GestureDetector(
                                      key: const ValueKey(
                                        'post-update-copy-author-btn',
                                      ),
                                      onTap: _copyAuthor,
                                      child: Text(
                                        '复制 ${OfficialChannelInfo.authorSocialName}',
                                        style: TextStyle(
                                          color: p.systemBlue,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  OfficialChannelInfo.soleOfficialChannelNotice,
                                  style: TextStyle(
                                    color: p.labelSecondary,
                                    fontSize: 12.8,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // 3. 温情求赞助支持
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: warmBg,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(15),
                              side: BorderSide(
                                color: warmAccent.withValues(alpha: 0.28),
                                width: 0.7,
                              ),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(13),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      CupertinoIcons.heart_fill,
                                      color: warmAccent,
                                      size: 15,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      OfficialChannelInfo.warmSponsorTitle,
                                      style: TextStyle(
                                        color: p.labelPrimary,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  OfficialChannelInfo.postUpdateSponsorBody,
                                  style: TextStyle(
                                    color: p.labelSecondary,
                                    fontSize: 12.8,
                                    height: 1.46,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: CupertinoButton(
                                        key: const ValueKey(
                                          'post-update-donate-btn',
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 7,
                                        ),
                                        minimumSize: const Size(44, 34),
                                        color:
                                            warmAccent.withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(10),
                                        onPressed: () => _openTarget(
                                          OfficialChannelInfo.officialDonateUri,
                                          '官网捐赠区',
                                        ),
                                        child: Text(
                                          '前往官网捐赠支持',
                                          style: TextStyle(
                                            color: warmAccent,
                                            fontSize: 12.8,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    CupertinoButton(
                                      key: const ValueKey(
                                        'post-update-website-btn',
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 7,
                                      ),
                                      minimumSize: const Size(44, 34),
                                      color:
                                          p.systemBlue.withValues(alpha: 0.13),
                                      borderRadius: BorderRadius.circular(10),
                                      onPressed: () => _openTarget(
                                        OfficialChannelInfo.officialWebsiteUri,
                                        'Marco 官网',
                                      ),
                                      child: Text(
                                        '访问官网',
                                        style: TextStyle(
                                          color: p.systemBlue,
                                          fontSize: 12.8,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_feedback != null) ...[
                          const SizedBox(height: 9),
                          Text(
                            _feedback!,
                            key: const ValueKey('post-update-feedback'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: p.labelSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 46,
                          child: CupertinoButton(
                            key: const ValueKey('post-update-confirm-btn'),
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            color: AppleColors.systemBlue,
                            borderRadius: BorderRadius.circular(14),
                            onPressed: _confirm,
                            child: const Text(
                              '知道了，开始观影',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
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
