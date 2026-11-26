import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_update.dart';
import 'apple_theme.dart';
import 'release_notes_view.dart';

typedef WindowsUpdateCheckFn = Future<AppUpdate> Function(
  UpdateCancellation cancellation,
  void Function(String stage) onStage,
);

typedef WindowsUpdateDownloadFn = Future<File> Function(
  AppUpdate release,
  WindowsDistributionKind distribution,
  Directory directory,
  UpdateCancellation cancellation,
  void Function(int received, int total) onProgress,
);

/// Windows desktop software update sheet with explicit handling for:
/// - remote newer / same / older version states (never downgrading to an older manifest)
/// - installed (`setup.exe` -> `/DIR=<current install dir>`) vs portable (`portable.zip` -> verified ZIP)
/// - isolated temp staging, cancellation on close/cancel, SHA-256 verification, and offline retry.
class WindowsUpdateSheet extends StatefulWidget {
  final String installedVersion;
  final Future<String> Function()? readVersion;
  final Future<WindowsInstallInfo> Function()? detectInstall;
  final WindowsUpdateCheckFn? check;
  final WindowsUpdateDownloadFn? download;
  final Future<Directory> Function(WindowsDistributionKind distribution)?
      resolveDownloadDirectory;
  final Future<void> Function(File installerFile, String installDirectory)?
      launchInstaller;
  final Future<void> Function(File zipFile)? revealPortableZip;
  final Future<void> Function(Uri url)? openDownloadSite;

  const WindowsUpdateSheet({
    super.key,
    this.installedVersion = '',
    this.readVersion,
    this.detectInstall,
    this.check,
    this.download,
    this.resolveDownloadDirectory,
    this.launchInstaller,
    this.revealPortableZip,
    this.openDownloadSite,
  });

  @override
  State<WindowsUpdateSheet> createState() => _WindowsUpdateSheetState();
}

class _WindowsUpdateSheetState extends State<WindowsUpdateSheet> {
  static final Uri _officialSiteUri =
      Uri.parse('https://marcotv.wlj9919.top/movie/');

  UpdateCancellation? _operation;
  WindowsInstallInfo? _installInfo;
  AppUpdate? _release;
  UpdateVersionRelation? _relation;
  String _version = '';
  String _statusText = '正在连接镜像更新源…';
  bool _checking = true;
  bool _checkFailed = false;
  bool _downloading = false;
  bool _downloadFailed = false;
  double? _progress;
  File? _downloadedFile;

  bool _isActive(UpdateCancellation op) =>
      mounted && identical(_operation, op) && !op.isCancelled;

  static bool _isValidVersion(String raw) =>
      RegExp(r'^[vV]?\d+\.\d+\.\d+').hasMatch(raw.trim());

  @override
  void initState() {
    super.initState();
    final initial = widget.installedVersion.trim();
    _version = _isValidVersion(initial) ? initial : '';
    unawaited(_startCheck());
  }

  @override
  void dispose() {
    _operation?.cancel();
    super.dispose();
  }

  WindowsDistributionKind get _distribution =>
      _installInfo?.distribution ?? WindowsDistributionKind.portable;

  UpdateAsset? get _targetAsset => _release?.windowsAssetFor(_distribution);

  Future<Directory> _defaultDownloadDir(
    WindowsDistributionKind distribution,
  ) async {
    if (distribution == WindowsDistributionKind.portable) {
      try {
        final dl = await getDownloadsDirectory();
        if (dl != null) {
          final dir = Directory(
            '${dl.path}${Platform.pathSeparator}Marco Movie Updates',
          );
          await dir.create(recursive: true);
          return dir;
        }
      } catch (_) {}
    }
    final tempDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}MarcoMovieUpdates',
    );
    await tempDir.create(recursive: true);
    return tempDir;
  }

  Future<void> _startCheck() async {
    _operation?.cancel();
    final op = _operation = UpdateCancellation();
    setState(() {
      _checking = true;
      _checkFailed = false;
      _downloading = false;
      _downloadFailed = false;
      _progress = null;
      _downloadedFile = null;
      _release = null;
      _relation = null;
      _statusText = '正在连接镜像更新源…';
    });

    try {
      final infoFuture =
          (widget.detectInstall?.call() ?? WindowsInstallDetector.detect())
              .timeout(const Duration(seconds: 4));
      final versionFuture = () async {
        try {
          final v = await (widget.readVersion?.call() ??
                  PackageInfo.fromPlatform().then((p) => p.version))
              .timeout(const Duration(seconds: 3));
          return v.trim();
        } catch (_) {
          return _version;
        }
      }();

      final results = await op.bind(Future.wait<Object?>([
        infoFuture,
        versionFuture,
      ]));
      if (!_isActive(op)) return;
      final detectedInfo = results[0] as WindowsInstallInfo;
      final resolvedVersion = (results[1] as String).trim();
      if (_isValidVersion(resolvedVersion)) {
        _version = resolvedVersion;
      }
      _installInfo = detectedInfo;

      if (!_isValidVersion(_version)) {
        throw const FormatException('无法读取已安装版本');
      }

      void onStage(String stage) {
        if (_isActive(op)) {
          setState(() => _statusText = stage);
        }
      }

      final release = await op.bind(
        (widget.check?.call(op, onStage) ??
                AppUpdate.check(
                  platform: 'windows',
                  cancellation: op,
                  onStage: onStage,
                ))
            .timeout(const Duration(seconds: 18)),
      );
      if (!_isActive(op)) return;

      final relation =
          AppUpdate.compareVersionRelation(release.version, _version);
      final asset = release.windowsAssetFor(detectedInfo.distribution);
      final String status;
      switch (relation) {
        case UpdateVersionRelation.remoteNewer:
          if (asset == null) {
            status = detectedInfo.isPortable
                ? '发现新版本 v${release.version}，但线上清单暂未包含便携版 ZIP，请前往下载站获取'
                : '发现新版本 v${release.version}，但线上清单暂未包含安装包，请前往下载站获取';
          } else {
            status = '发现新版本 v${release.version}（当前 v$_version）';
          }
          break;
        case UpdateVersionRelation.sameVersion:
          status = '当前已是最新版本（v$_version）';
          break;
        case UpdateVersionRelation.remoteOlder:
          status =
              '当前版本（v$_version）高于线上正式版（v${release.version}），无需更新';
          break;
      }

      setState(() {
        _release = release;
        _relation = relation;
        _checking = false;
        _checkFailed = false;
        _statusText = status;
      });
    } on UpdateCancelled {
      // Cancelled by user or sheet disposal.
    } on FormatException catch (e) {
      if (!_isActive(op)) return;
      setState(() {
        _checking = false;
        _checkFailed = true;
        _statusText = '检查更新失败：${e.message}';
      });
    } catch (_) {
      if (!_isActive(op)) return;
      setState(() {
        _checking = false;
        _checkFailed = true;
        _statusText = '暂时无法检查更新，请检查网络后重试或打开官方下载站';
      });
    }
  }

  void _cancelOperation() {
    _operation?.cancel();
    setState(() {
      _checking = false;
      _downloading = false;
      _progress = null;
      _statusText = '已取消当前操作，可重新检查或下载';
    });
  }

  Future<void> _downloadAndApply() async {
    final release = _release;
    final installInfo = _installInfo;
    final relation = _relation;
    if (release == null ||
        installInfo == null ||
        relation == null ||
        relation == UpdateVersionRelation.remoteOlder ||
        _downloading) {
      return;
    }
    final asset = release.windowsAssetFor(installInfo.distribution);
    if (asset == null) {
      setState(() {
        _statusText = installInfo.isPortable
            ? '线上清单缺少 Windows 便携版更新包，请前往下载站下载'
            : '线上清单缺少 Windows 安装包，请前往下载站下载';
      });
      return;
    }

    _operation?.cancel();
    final op = _operation = UpdateCancellation();
    setState(() {
      _downloading = true;
      _downloadFailed = false;
      _downloadedFile = null;
      _progress = 0.0;
      _statusText = installInfo.isPortable
          ? '正在下载 Windows 便携版更新包（${asset.fileName}）…'
          : '正在下载 Windows 安装更新包（${asset.fileName}）…';
    });

    try {
      op.check();
      final directory = await op.bind(
        widget.resolveDownloadDirectory?.call(installInfo.distribution) ??
            _defaultDownloadDir(installInfo.distribution),
      );
      if (!_isActive(op)) return;

      var lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
      void onProgress(int received, int total) {
        if (!_isActive(op) || total <= 0) return;
        final now = DateTime.now();
        if (received != total &&
            now.difference(lastPaint).inMilliseconds < 120) {
          return;
        }
        lastPaint = now;
        final mbRecv = (received / (1024 * 1024)).toStringAsFixed(1);
        final mbTotal = (total / (1024 * 1024)).toStringAsFixed(1);
        setState(() {
          _progress = (received / total).clamp(0.0, 1.0);
          _statusText = received >= total
              ? '下载完成，正在校验 SHA-256 完整性…'
              : '正在下载 ${asset.fileName} · $mbRecv / $mbTotal MB';
        });
      }

      final savedFile = await (widget.download?.call(
            release,
            installInfo.distribution,
            directory,
            op,
            onProgress,
          ) ??
          release.downloadWindows(
            distribution: installInfo.distribution,
            directory: directory,
            cancellation: op,
            onProgress: onProgress,
          ));
      if (!_isActive(op)) return;

      if (installInfo.isInstaller) {
        setState(() {
          _progress = 1.0;
          _downloadedFile = savedFile;
          _statusText = '校验通过，正在启动安装向导…';
        });
        if (widget.launchInstaller != null) {
          await widget.launchInstaller!(savedFile, installInfo.installDirectory);
        } else {
          await Process.start(
            savedFile.path,
            [
              '/MERGETASKS=!desktopicon',
              '/DIR=${installInfo.installDirectory}',
            ],
            mode: ProcessStartMode.detached,
          );
        }
        if (!_isActive(op)) return;
        setState(() {
          _downloading = false;
          _downloadFailed = false;
          _statusText =
              '安装向导已启动，将沿当前安装目录（${installInfo.installDirectory}）升级，保留收藏与历史';
        });
      } else {
        setState(() {
          _progress = 1.0;
          _downloadedFile = savedFile;
          _statusText = '便携包 SHA-256 校验通过，正在打开所在目录…';
        });
        if (widget.revealPortableZip != null) {
          await widget.revealPortableZip!(savedFile);
        } else if (!kIsWeb && Platform.isWindows) {
          await Process.start(
            'explorer.exe',
            ['/select,', savedFile.path],
            mode: ProcessStartMode.detached,
          );
        }
        if (!_isActive(op)) return;
        setState(() {
          _downloading = false;
          _downloadFailed = false;
          _statusText =
              '便携版更新包 ${asset.fileName} 已下载并校验通过，请退出程序后解压覆盖当前目录（保留本地数据）';
        });
      }
    } on UpdateCancelled {
      // Handled by _cancelOperation or dispose.
    } on FormatException catch (e) {
      if (!_isActive(op)) return;
      setState(() {
        _downloading = false;
        _downloadFailed = true;
        _progress = null;
        _statusText = '更新包校验失败：${e.message}（未保留损坏文件，请重新下载）';
      });
    } on TimeoutException {
      if (!_isActive(op)) return;
      setState(() {
        _downloading = false;
        _downloadFailed = true;
        _progress = null;
        _statusText = '下载超时，请重试或前往官方下载站获取';
      });
    } catch (_) {
      if (!_isActive(op)) return;
      setState(() {
        _downloading = false;
        _downloadFailed = true;
        _progress = null;
        _statusText = '下载中断或网络异常，请检查网络后重试';
      });
    }
  }

  Future<void> _openSite() async {
    if (widget.openDownloadSite != null) {
      await widget.openDownloadSite!(_officialSiteUri);
      return;
    }
    if (!kIsWeb && Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', _officialSiteUri.toString()]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final release = _release;
    final relation = _relation;
    final info = _installInfo;
    final asset = _targetAsset;
    final canDownload = !_checking &&
        !_downloading &&
        release != null &&
        relation != null &&
        relation != UpdateVersionRelation.remoteOlder &&
        asset != null;
    final isNewer = relation == UpdateVersionRelation.remoteNewer;
    final isOlder = relation == UpdateVersionRelation.remoteOlder;

    final String primaryLabel;
    if (_downloadFailed && release != null) {
      primaryLabel = info?.isPortable == true
          ? '重试下载便携包 v${release.version}'
          : '重试下载安装 v${release.version}';
    } else if (isNewer && release != null) {
      primaryLabel = info?.isPortable == true
          ? '下载便携更新包 v${release.version}'
          : '一键下载安装 v${release.version}';
    } else if (release != null) {
      primaryLabel = info?.isPortable == true
          ? '重新下载便携包 v${release.version}'
          : '重新下载安装 v${release.version}';
    } else {
      primaryLabel = '下载更新';
    }

    return Padding(
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
                  _checkFailed || _downloadFailed
                      ? CupertinoIcons.exclamationmark_triangle_fill
                      : isNewer
                          ? CupertinoIcons.arrow_down_circle_fill
                          : CupertinoIcons.checkmark_seal_fill,
                  color: _checkFailed || _downloadFailed
                      ? AppleColors.systemOrange
                      : isNewer
                          ? AppleColors.systemBlue
                          : AppleColors.systemGreen,
                  size: 22,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _statusText,
                  key: const ValueKey('windows-update-status'),
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (info != null) ...[
            const SizedBox(height: 8),
            Text(
              info.isPortable
                  ? '运行形式：便携版（ZIP） · 目录：${info.installDirectory}'
                  : '运行形式：安装版（Setup） · 目录：${info.installDirectory}',
              key: const ValueKey('windows-update-distribution-badge'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.labelSecondary,
                fontSize: 12,
              ),
            ),
          ],
          if (_downloadedFile != null && !_downloading) ...[
            const SizedBox(height: 6),
            Text(
              '文件位置：${_downloadedFile!.path}',
              key: const ValueKey('windows-update-saved-path'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.labelSecondary,
                fontSize: 11.5,
              ),
            ),
          ],
          if (_downloading) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 6,
                backgroundColor: const Color(0x26FFFFFF),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppleColors.systemBlue,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: AppleCapsuleButton(
                key: const ValueKey('windows-update-cancel'),
                label: '取消下载',
                icon: CupertinoIcons.xmark,
                primary: false,
                onPressed: _cancelOperation,
              ),
            ),
          ],
          if (_checking) ...[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: AppleCapsuleButton(
                key: const ValueKey('windows-update-cancel'),
                label: '取消检查',
                icon: CupertinoIcons.xmark,
                primary: false,
                onPressed: _cancelOperation,
              ),
            ),
          ],
          if (!isOlder &&
              release != null &&
              release.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.groupedSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppleColors.glassBorder,
                  width: 0.5,
                ),
              ),
              child: SingleChildScrollView(
                child: ReleaseNotesSummaryView(
                  rawNotes: release.notes,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
          if (!_checking && !_downloading) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                if (canDownload) ...[
                  Expanded(
                    child: AppleCapsuleButton(
                      key: const ValueKey('windows-update-primary-action'),
                      label: primaryLabel,
                      icon: CupertinoIcons.arrow_down_to_line,
                      primary: isNewer || _downloadFailed,
                      onPressed: _downloadAndApply,
                    ),
                  ),
                  const SizedBox(width: 10),
                ] else if (_checkFailed || isOlder || release == null) ...[
                  Expanded(
                    child: AppleCapsuleButton(
                      key: const ValueKey('windows-update-retry-check'),
                      label: _checkFailed ? '重试检查' : '重新检查',
                      icon: CupertinoIcons.refresh,
                      primary: _checkFailed,
                      onPressed: _startCheck,
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: AppleCapsuleButton(
                    key: const ValueKey('windows-update-open-site'),
                    label: '打开官方下载站',
                    icon: CupertinoIcons.globe,
                    primary: !canDownload && !_checkFailed,
                    onPressed: _openSite,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
