// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_update.dart';
import '../core/download_service.dart';
import 'apple_theme.dart';
import 'release_notes_view.dart';

enum MacosVersionRelation {
  remoteNewer,
  sameVersion,
  localNewer,
}

/// macOS in-app update sheet opened from Settings -> 检查版本更新.
///
/// Reuses [AppUpdate.check] / [AppUpdate.downloadMacos] (platform, version,
/// trusted host, exact size and SHA-256 verification), reveals the verified
/// archive in Finder, and keeps the official download site button accessible.
class MacosUpdateSheet extends StatefulWidget {
  static const String officialDownloadSiteUrl =
      'https://marcotv.wlj9919.top/movie/';

  final String installedVersion;
  final Future<String> Function()? readVersion;
  final Future<AppUpdate> Function(
    UpdateCancellation cancellation,
    void Function(String stage) onStage,
  )? check;
  final Future<File> Function(
    AppUpdate release,
    Directory directory,
    UpdateCancellation cancellation,
    void Function(int received, int total) onProgress,
  )? download;
  final Future<Directory> Function()? targetDirectory;
  final Future<bool> Function(File file)? revealInFinder;
  final Future<void> Function(String url)? openWebsite;

  const MacosUpdateSheet({
    super.key,
    this.installedVersion = '',
    this.readVersion,
    this.check,
    this.download,
    this.targetDirectory,
    this.revealInFinder,
    this.openWebsite,
  });

  static MacosVersionRelation compareVersions(String remote, String local) {
    final trimmedLocal = local.trim();
    if (trimmedLocal.isEmpty) return MacosVersionRelation.remoteNewer;
    final r = remote
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final l = trimmedLocal
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final len = r.length > l.length ? r.length : l.length;
    for (var i = 0; i < len; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv > lv) return MacosVersionRelation.remoteNewer;
      if (rv < lv) return MacosVersionRelation.localNewer;
    }
    return MacosVersionRelation.sameVersion;
  }

  static bool isRemoteVersionNewer(String remote, String local) =>
      compareVersions(remote, local) == MacosVersionRelation.remoteNewer;

  @override
  State<MacosUpdateSheet> createState() => _MacosUpdateSheetState();
}

class _MacosUpdateSheetState extends State<MacosUpdateSheet> {
  bool _checking = true;
  bool _downloading = false;
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String _currentVersion = '';
  String _statusText = '正在连接镜像更新源…';
  MacosVersionRelation _versionRelation = MacosVersionRelation.sameVersion;
  bool _checkFailed = false;
  AppUpdate? _release;
  File? _downloadedFile;
  UpdateCancellation? _activeCancellation;

  @override
  void initState() {
    super.initState();
    _currentVersion = widget.installedVersion.trim();
    unawaited(_checkRemote());
  }

  @override
  void dispose() {
    _activeCancellation?.cancel();
    super.dispose();
  }

  Future<String> _resolveInstalledVersion() async {
    if (widget.readVersion != null) {
      return (await widget.readVersion!()).trim();
    }
    try {
      final info = await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 3));
      if (info.version.trim().isNotEmpty) return info.version.trim();
    } catch (_) {}
    return _currentVersion;
  }

  Future<void> _checkRemote() async {
    _activeCancellation?.cancel();
    final cancellation = UpdateCancellation();
    _activeCancellation = cancellation;
    if (mounted) {
      setState(() {
        _checking = true;
        _checkFailed = false;
        _statusText = '正在连接镜像更新源…';
      });
    }
    try {
      final version = await _resolveInstalledVersion();
      if (version.isNotEmpty) _currentVersion = version;
      cancellation.check();
      final release = widget.check != null
          ? await widget.check!(cancellation, _onStage)
          : await AppUpdate.check(
              platform: 'macos',
              cancellation: cancellation,
              onStage: _onStage,
            );
      if (!mounted || cancellation.isCancelled) return;
      final relation = MacosUpdateSheet.compareVersions(
        release.version,
        _currentVersion,
      );
      setState(() {
        _release = release;
        _versionRelation = relation;
        _checking = false;
        _checkFailed = false;
        _statusText = switch (relation) {
          MacosVersionRelation.remoteNewer => _currentVersion.isEmpty
              ? '可用版本 v${release.version}'
              : '发现新版本 v${release.version}（当前 v$_currentVersion）',
          MacosVersionRelation.sameVersion => '当前已是最新版本（v$_currentVersion）',
          MacosVersionRelation.localNewer =>
            '本机版本 v$_currentVersion 高于当前正式通道（v${release.version}），无需更新',
        };
      });
    } on UpdateCancelled {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _statusText = '已取消检查更新';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkFailed = true;
        _statusText = '检查更新失败：${e.message}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _checkFailed = true;
        _statusText = '暂时无法检查更新，请稍后重试或打开官方下载站';
      });
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
    }
  }

  void _onStage(String stage) {
    if (!mounted || !_checking) return;
    setState(() => _statusText = stage);
  }

  Future<Directory> _resolveDownloadDirectory() async {
    if (widget.targetDirectory != null) {
      return widget.targetDirectory!();
    }
    if (!kIsWeb && Platform.isMacOS) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) return downloads;
      } catch (_) {}
    }
    return getApplicationSupportDirectory();
  }

  Future<void> _downloadMacosPackage() async {
    final release = _release;
    if (release == null || release.macosUrl == null || _downloading) return;
    _activeCancellation?.cancel();
    final cancellation = UpdateCancellation();
    _activeCancellation = cancellation;
    setState(() {
      _downloading = true;
      _downloadedFile = null;
      _progress = 0.0;
      _receivedBytes = 0;
      _totalBytes = release.size ?? 0;
      _statusText = '正在下载并校验 macOS 更新包…';
    });
    try {
      final dir = await _resolveDownloadDirectory();
      cancellation.check();
      void onProgress(int received, int total) {
        if (!mounted || cancellation.isCancelled) return;
        setState(() {
          _receivedBytes = received;
          _totalBytes = total;
          _progress = total > 0 ? (received / total).clamp(0.0, 0.99) : 0.0;
        });
      }

      final file = widget.download != null
          ? await widget.download!(release, dir, cancellation, onProgress)
          : await release.downloadMacos(
              directory: dir,
              cancellation: cancellation,
              onProgress: onProgress,
            );
      if (!mounted || cancellation.isCancelled) return;
      final revealed = widget.revealInFinder != null
          ? await widget.revealInFinder!(file)
          : await AppUpdate.revealMacosPackageInFinder(file);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = 1.0;
        _downloadedFile = file;
        _statusText = revealed
            ? '更新包校验通过，已在 Finder 中显示（解压后拖入“应用程序”即可覆盖升级）'
            : '更新包校验通过，已保存至：${file.path}';
      });
    } on UpdateCancelled {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = 0.0;
        _statusText = '已取消下载';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = 0.0;
        _statusText = '更新包校验失败：${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = 0.0;
        _statusText = '下载更新包失败：$e';
      });
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
    }
  }

  void _cancelActiveOperation() {
    _activeCancellation?.cancel();
  }

  Future<void> _openOfficialSite() async {
    const url = MacosUpdateSheet.officialDownloadSiteUrl;
    if (widget.openWebsite != null) {
      await widget.openWebsite!(url);
      return;
    }
    if (!kIsWeb && Platform.isMacOS) {
      await Process.run('open', [url]);
    }
  }

  Future<void> _revealDownloaded() async {
    final file = _downloadedFile;
    if (file == null) return;
    if (widget.revealInFinder != null) {
      await widget.revealInFinder!(file);
    } else {
      await AppUpdate.revealMacosPackageInFinder(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final release = _release;
    final hasRemoteNewer = _versionRelation == MacosVersionRelation.remoteNewer;
    final isLocalNewer = _versionRelation == MacosVersionRelation.localNewer;
    final canDownload =
        release != null && release.macosUrl != null && !isLocalNewer;
    final notesRaw = isLocalNewer ? '' : (release?.notes.trim() ?? '');

    return Padding(
      key: const ValueKey('macos-update-sheet'),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_checking || _downloading) ...[
                const CupertinoActivityIndicator(radius: 10),
                const SizedBox(width: 10),
              ] else ...[
                Icon(
                  _checkFailed
                      ? CupertinoIcons.exclamationmark_triangle_fill
                      : (_downloadedFile != null
                          ? CupertinoIcons.checkmark_seal_fill
                          : (hasRemoteNewer
                              ? CupertinoIcons.arrow_down_circle_fill
                              : CupertinoIcons.checkmark_seal_fill)),
                  color: _checkFailed
                      ? AppleColors.systemOrange
                      : (_downloadedFile != null
                          ? AppleColors.systemGreen
                          : (hasRemoteNewer
                              ? AppleColors.systemBlue
                              : AppleColors.systemGreen)),
                  size: 22,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _statusText,
                  key: const ValueKey('macos-update-status'),
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (_downloading) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                key: const ValueKey('macos-update-progress'),
                value: _progress > 0 ? _progress : null,
                minHeight: 6,
                backgroundColor: palette.fill,
                valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
              ),
            ),
            if (_totalBytes > 0) ...[
              const SizedBox(height: 6),
              Text(
                '${DownloadService.formatBytes(_receivedBytes)} / ${DownloadService.formatBytes(_totalBytes)}',
                style: TextStyle(
                  color: palette.labelSecondary,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
          if (notesRaw.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.groupedSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: palette.glassBorder,
                  width: 0.5,
                ),
              ),
              child: SingleChildScrollView(
                child: ReleaseNotesSummaryView(
                  rawNotes: notesRaw,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          if (_checking || _downloading)
            Row(
              children: [
                Expanded(
                  child: AppleCapsuleButton(
                    key: const ValueKey('macos-update-cancel-button'),
                    label: _downloading ? '取消下载' : '取消检查',
                    icon: CupertinoIcons.xmark,
                    onPressed: _cancelActiveOperation,
                  ),
                ),
              ],
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (_downloadedFile != null)
                  AppleCapsuleButton(
                    key: const ValueKey('macos-update-reveal-button'),
                    label: '在 Finder 中显示',
                    icon: CupertinoIcons.folder_open,
                    primary: true,
                    onPressed: _revealDownloaded,
                  )
                else if (canDownload)
                  AppleCapsuleButton(
                    key: const ValueKey('macos-update-download-button'),
                    label: hasRemoteNewer
                        ? '下载更新包 v${release.version}'
                        : '重新下载当前版本 v${release.version}',
                    icon: CupertinoIcons.arrow_down_to_line,
                    primary: hasRemoteNewer,
                    onPressed: _downloadMacosPackage,
                  )
                else if (_checkFailed)
                  AppleCapsuleButton(
                    key: const ValueKey('macos-update-retry-button'),
                    label: '重新检查',
                    icon: CupertinoIcons.refresh,
                    primary: true,
                    onPressed: _checkRemote,
                  ),
                AppleCapsuleButton(
                  key: const ValueKey('macos-update-website-button'),
                  label: '打开官方下载站',
                  icon: CupertinoIcons.globe,
                  primary: !canDownload && !_checkFailed && _downloadedFile == null,
                  onPressed: _openOfficialSite,
                ),
              ],
            ),
        ],
      ),
    );
  }
}
