// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'apple_theme.dart';
import 'official_channel_notice.dart';

/// Device-local persistence for the Windows post-update donation & anti-scam
/// notice.
///
/// Stored solely in device-local [SharedPreferences] (never exported into cloud
/// sync or backup payloads) so every Windows machine shows the notice exactly
/// once per installed `version+build`.
class WindowsPostUpdateNoticePrefs {
  static const String versionKey = 'windows_post_update_notice_version';

  final SharedPreferences _prefs;
  String _lastSeenVersion;

  WindowsPostUpdateNoticePrefs._(this._prefs, this._lastSeenVersion);

  static Future<WindowsPostUpdateNoticePrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(versionKey);
    return WindowsPostUpdateNoticePrefs._(prefs, (raw ?? '').trim());
  }

  /// Normalizes `version` and optional `buildNumber` into a canonical tag such
  /// as `0.7.3+80`. Returns `''` when [version] is empty.
  static String normalizeVersionTag(String version, [String buildNumber = '']) {
    final v = version.trim();
    if (v.isEmpty) return '';
    final b = buildNumber.trim();
    if (b.isEmpty) return v;
    return '$v+$b';
  }

  /// Extracts the user-facing semver string (e.g. `0.7.3`) from a tag like
  /// `0.7.3+80`.
  static String displayVersionFromTag(String tag) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return '';
    final plus = trimmed.indexOf('+');
    return plus > 0 ? trimmed.substring(0, plus) : trimmed;
  }

  String get lastSeenVersion => _lastSeenVersion;

  bool shouldShowForVersion(String versionTag) {
    final normalized = versionTag.trim();
    if (normalized.isEmpty) return false;
    return _lastSeenVersion != normalized;
  }

  /// Persists [versionTag] as seen. Returns `true` only when the write succeeds;
  /// on failure reconciles the in-memory cache from [SharedPreferences].
  Future<bool> markVersionSeen(String versionTag) async {
    final normalized = versionTag.trim();
    if (normalized.isEmpty) return false;
    try {
      final saved = await _prefs.setString(versionKey, normalized);
      if (saved) {
        _lastSeenVersion = normalized;
        return true;
      }
      _lastSeenVersion = (_prefs.getString(versionKey) ?? '').trim();
      return false;
    } catch (_) {
      try {
        _lastSeenVersion = (_prefs.getString(versionKey) ?? '').trim();
      } catch (_) {}
      return false;
    }
  }
}

/// Presents the Windows post-update sincere donation, anti-scam, and
/// official-sole-channel dialog.
///
/// Returns `true` when the user dismisses via the confirm button (fail-open if
/// [onConfirm] persistence fails so the notice never traps the user).
Future<bool> showWindowsPostUpdateNoticeDialog(
  BuildContext context, {
  bool isUpgrade = true,
  String versionLabel = '',
  Future<bool> Function(Uri uri)? urlOpener,
  Future<bool> Function()? onConfirm,
  bool barrierDismissible = false,
}) async {
  activeAppleModalSheetCount.value++;
  try {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: Colors.black.withValues(alpha: 0.56),
      builder: (dialogCtx) => WindowsPostUpdateNoticeDialog(
        isUpgrade: isUpgrade,
        versionLabel: versionLabel,
        urlOpener: urlOpener,
        barrierDismissible: barrierDismissible,
        onConfirm: () async {
          if (onConfirm != null) {
            try {
              await onConfirm();
            } catch (e) {
              debugPrint(
                'WindowsPostUpdateNotice persist failed (continuing): $e',
              );
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

class WindowsPostUpdateNoticeDialog extends StatefulWidget {
  final bool isUpgrade;
  final String versionLabel;
  final Future<bool> Function(Uri uri)? urlOpener;
  final Future<void> Function()? onConfirm;
  final bool barrierDismissible;

  const WindowsPostUpdateNoticeDialog({
    super.key,
    this.isUpgrade = true,
    this.versionLabel = '',
    this.urlOpener,
    this.onConfirm,
    this.barrierDismissible = false,
  });

  @override
  State<WindowsPostUpdateNoticeDialog> createState() =>
      _WindowsPostUpdateNoticeDialogState();
}

class _WindowsPostUpdateNoticeDialogState
    extends State<WindowsPostUpdateNoticeDialog> {
  String? _statusMessage;
  bool _statusIsError = false;
  bool _confirming = false;
  bool _openingDonate = false;
  bool _openingWebsite = false;
  bool _copyingSocial = false;
  int _donateToken = 0;
  int _websiteToken = 0;
  int _socialToken = 0;

  bool get _isRouteActive {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  void _setStatus(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusIsError = isError;
    });
  }

  Future<void> _copyAuthorSocial() async {
    if (_copyingSocial) return;
    final token = ++_socialToken;
    beginExplicitOfficialClipboardCopy();
    setState(() => _copyingSocial = true);
    try {
      final copied = await copyOfficialChannelText(
        OfficialChannelInfo.authorSocialName,
      );
      if (token != _socialToken || !mounted || !_isRouteActive) return;
      if (copied) {
        _setStatus('已复制作者社媒账号名：${OfficialChannelInfo.authorSocialName}');
      } else {
        _setStatus('剪贴板写入失败，请手动选取账号名', isError: true);
        if (!mounted) return;
        await showOfficialChannelManualCopyDialog(
          context,
          title: '复制失败，请手动选取',
          message:
              '当前无法写入系统剪贴板，请手动选取作者社媒账号名（${OfficialChannelInfo.socialPlatformsDisplay}）：',
          selectableValue: OfficialChannelInfo.authorSocialName,
        );
      }
    } finally {
      if (token == _socialToken && mounted) {
        setState(() => _copyingSocial = false);
      }
    }
  }

  Future<void> _openExternalWithFallback({
    required Uri uri,
    required String label,
    required bool Function() isBusy,
    required void Function(bool) setBusy,
    required int Function() nextToken,
    required int Function() currentToken,
  }) async {
    if (isBusy()) return;
    final token = nextToken();
    final startClipboardEpoch = officialExplicitClipboardEpoch;
    setState(() => setBusy(true));
    try {
      final opened = await launchExternalOfficialUrl(
        uri,
        urlOpener: widget.urlOpener,
      );
      if (token != currentToken() || !_isRouteActive) return;
      if (opened) {
        _setStatus('已在浏览器打开$label');
        return;
      }
      if (officialExplicitClipboardEpoch != startClipboardEpoch) {
        return;
      }
      final copied = await copyOfficialChannelText(uri.toString());
      if (token != currentToken() ||
          officialExplicitClipboardEpoch != startClipboardEpoch ||
          !mounted ||
          !_isRouteActive) {
        return;
      }
      if (copied) {
        _setStatus('未能自动打开浏览器，已复制$label地址：${uri.toString()}');
        return;
      }
      _setStatus('未能自动打开或复制，请手动选取地址', isError: true);
      if (!mounted) return;
      await showOfficialChannelManualCopyDialog(
        context,
        title: '无法自动打开或复制链接',
        message: '请手动选取以下$label地址，并在浏览器中打开：',
        selectableValue: uri.toString(),
      );
    } finally {
      if (token == currentToken() && mounted) {
        setState(() => setBusy(false));
      }
    }
  }

  Future<void> _handleConfirm() async {
    if (_confirming) return;
    setState(() => _confirming = true);
    try {
      if (widget.onConfirm != null) {
        await widget.onConfirm!();
      } else if (mounted) {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = ApplePalette.of(context);
    final bgColor = isDark ? const Color(0xFF151B24) : const Color(0xFFFAFBFD);
    final cardColor =
        isDark ? const Color(0xFF1D2532) : const Color(0xFFF1F4F9);
    final warnBg = isDark ? const Color(0x24F59E0B) : const Color(0x18D97706);
    final warnBorder =
        isDark ? const Color(0x55F59E0B) : const Color(0x44D97706);
    final ink = isDark ? const Color(0xFFF2F5FA) : const Color(0xFF131B26);
    final muted = isDark ? const Color(0xFFA7B4C7) : const Color(0xFF556377);
    final border = isDark ? const Color(0x26FFFFFF) : const Color(0x1A0F172A);
    final accent = isDark ? const Color(0xFF5EA0FF) : const Color(0xFF2563EB);
    final warmDonateBg =
        isDark ? const Color(0xFFE07A3F) : const Color(0xFFD96B2B);

    final ver = widget.versionLabel.trim();
    final headline = widget.isUpgrade
        ? (ver.isNotEmpty ? '已更新至 v$ver · 感谢一路同行' : '感谢一路同行')
        : (ver.isNotEmpty ? '欢迎使用 Marco Movie v$ver' : '欢迎使用 Marco Movie');
    final confirmLabel = widget.barrierDismissible ? '我知道了' : '进入应用';

    return PopScope(
      canPop: widget.barrierDismissible,
      child: Dialog(
        key: const ValueKey('windows-post-update-notice-dialog'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.16),
                  blurRadius: 34,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  widget.isUpgrade ? '版本更新提示' : '官方渠道说明',
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (ver.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cardColor,
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: border),
                                  ),
                                  child: Text(
                                    'Windows v$ver',
                                    style: TextStyle(
                                      color: muted,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            headline,
                            style: TextStyle(
                              color: ink,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Marco Movie 是一款由个人利用业余时间持续打磨的免费开源播放器，无广告、无会员、也从不对任何核心功能设限。\n\n'
                            '如果你喜欢这份克制与纯粹，愿意自愿请作者喝一杯咖啡，这份心意会让项目走得更稳更远；即使暂时不方便也没关系，继续安心看片、给项目点个 Star 或提一条建议，同样是很大的鼓励。',
                            style: TextStyle(
                              color: muted,
                              fontSize: 13.2,
                              height: 1.65,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: warnBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: warnBorder),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      CupertinoIcons.shield_lefthalf_fill,
                                      size: 16,
                                      color: isDark
                                          ? const Color(0xFFFBBF24)
                                          : const Color(0xFFB45309),
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      '免费开源 · 谨防受骗 · 认准唯一官方渠道',
                                      style: TextStyle(
                                        color: ink,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '• 免费软件，谨防受骗：Marco Movie 永久免费开源，从未授权任何个人或第三方售卖安装包、收费版或「激活码」，请勿向任何非官方渠道付费。\n'
                                  '• 官网为唯一更新渠道：下载与更新请认准 Marco 官网 ${OfficialChannelInfo.officialWebsiteDisplay}，切勿安装不明来源修改包，谨防夹带广告或木马病毒。',
                                  style: TextStyle(
                                    color: ink.withValues(alpha: 0.88),
                                    fontSize: 12.4,
                                    height: 1.6,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 11,
                            ),
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: border),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      CupertinoIcons
                                          .person_crop_circle_badge_checkmark,
                                      size: 16,
                                      color: muted,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '作者全平台同名：${OfficialChannelInfo.authorSocialSummary}',
                                        style: TextStyle(
                                          color: ink,
                                          fontSize: 12.2,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TextButton(
                                      key: const ValueKey(
                                        'windows-post-update-copy-social-btn',
                                      ),
                                      onPressed: _copyingSocial
                                          ? null
                                          : _copyAuthorSocial,
                                      style: TextButton.styleFrom(
                                        foregroundColor: accent,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        minimumSize: const Size(0, 30),
                                      ),
                                      child: const Text(
                                        '复制',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                                Divider(height: 14, color: border),
                                Row(
                                  children: [
                                    Icon(
                                      CupertinoIcons.globe,
                                      size: 16,
                                      color: muted,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '唯一官方地址：${OfficialChannelInfo.officialWebsiteUrl}',
                                        style: TextStyle(
                                          color: ink,
                                          fontSize: 12.2,
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    TextButton(
                                      key: const ValueKey(
                                        'windows-post-update-open-site-btn',
                                      ),
                                      onPressed: _openingWebsite
                                          ? null
                                          : () => _openExternalWithFallback(
                                                uri: OfficialChannelInfo
                                                    .officialWebsiteUri,
                                                label: '官方主页',
                                                isBusy: () => _openingWebsite,
                                                setBusy: (v) =>
                                                    _openingWebsite = v,
                                                nextToken: () =>
                                                    ++_websiteToken,
                                                currentToken: () =>
                                                    _websiteToken,
                                              ),
                                      style: TextButton.styleFrom(
                                        foregroundColor: accent,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        minimumSize: const Size(0, 30),
                                      ),
                                      child: const Text(
                                        '打开官网',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (_statusMessage != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              _statusMessage!,
                              key: const ValueKey(
                                'windows-post-update-status-text',
                              ),
                              style: TextStyle(
                                color: _statusIsError
                                    ? AppleColors.systemOrange
                                    : palette.accent,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Divider(height: 1, color: border),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton(
                          key: const ValueKey(
                            'windows-post-update-confirm-btn',
                          ),
                          onPressed: _confirming ? null : _handleConfirm,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: ink,
                            side: BorderSide(color: border),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            confirmLabel,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        FilledButton.icon(
                          key: const ValueKey('windows-post-update-donate-btn'),
                          onPressed: _openingDonate
                              ? null
                              : () => _openExternalWithFallback(
                                    uri: OfficialChannelInfo.officialDonateUri,
                                    label: '官网捐赠区',
                                    isBusy: () => _openingDonate,
                                    setBusy: (v) => _openingDonate = v,
                                    nextToken: () => ++_donateToken,
                                    currentToken: () => _donateToken,
                                  ),
                          style: FilledButton.styleFrom(
                            backgroundColor: warmDonateBg,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(
                            CupertinoIcons.heart_fill,
                            size: 15,
                          ),
                          label: const Text(
                            '前往官网捐赠支持',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
