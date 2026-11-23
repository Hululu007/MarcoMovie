// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/app_update.dart';
import '../../core/cms_client.dart';
import '../../core/models.dart';
import '../../core/ohos_runtime.dart';
import '../../core/storage_service.dart';
import '../apple_theme.dart';
import '../cloud_sync_panel.dart';
import '../netdisk_sheet.dart';
import '../player_screen.dart';
import '../poster_image.dart';
import '../release_notes_view.dart';
import 'tv_ambient_theme.dart';
import 'tv_detail_screen.dart';
import 'tv_focus_widgets.dart';

/// 10-foot living-room UI shell for HarmonyOS Smart Screen (`deviceType == 'tv'`)
/// and optional manual TV Remote Mode across devices.
class TvLivingRoomShell extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;
  final Duration searchSiteTimeout;
  final Route<void> Function(
    CmsSite site,
    CmsVideo video,
    List<LiveGroup> liveGroups,
    LiveChannel initialChannel,
  )? debugLiveRouteBuilder;

  const TvLivingRoomShell({
    super.key,
    required this.storage,
    required this.client,
    this.searchSiteTimeout = const Duration(seconds: 12),
    this.debugLiveRouteBuilder,
  });

  @override
  State<TvLivingRoomShell> createState() => _TvLivingRoomShellState();
}

class _TvLivingRoomShellState extends State<TvLivingRoomShell> {
  int _tabIndex = 0; // 0: 主页, 1: 直播, 2: 搜索, 3: 片库, 4: 设置
  CmsConfig? _config;
  CmsSite? _activeSite;
  List<CmsCategory> _categories = const [];
  String _selectedCategoryId = '';
  List<CmsVideo> _homeVideos = const [];
  int _currentPage = 1;
  int _pageCount = 1;
  bool _homeLoading = false;
  bool _loadingMore = false;
  String? _homeError;
  int _homeEpoch = 0;

  // Triple-Up back-to-top state
  int _upPressCount = 0;
  int _lastUpPressMs = 0;
  final ScrollController _homeScrollController = ScrollController();

  // Live TV state
  int _selectedLiveSourceIdx = 0;
  int _selectedLiveGroupIdx = 0;
  List<LiveGroup> _liveGroups = const [];
  bool _liveLoading = false;
  String? _liveError;
  int _liveEpoch = 0;

  // Search state
  String _searchQuery = '';
  String _searchActiveKeyword = '';
  bool _searching = false;
  bool _searchPerformed = false;
  String _searchSelectedSiteKey = '__all__';
  final List<(CmsSite, CmsVideo)> _searchResults = <(CmsSite, CmsVideo)>[];
  int _searchEpoch = 0;
  int _searchTotalSites = 0;
  int _searchCompletedSites = 0;
  int _searchSucceededSites = 0;
  int _searchFailedCount = 0;
  int _searchTimedOutCount = 0;

  // Library state (0: 观看历史, 1: 我的收藏)
  int _librarySegment = 0;

  // Settings sidebar state (0: 外观与柔光, 1: 订阅与片源, 2: 4K网盘加速, 3: WebDAV云同步, 4: 播放与跳过, 5: 备份与存储, 6: 版本与更新)
  int _settingsSection = 0;

  // HarmonyOS update state
  String _installedVersion = '读取中';
  String _installedBuildNumber = '';
  bool _updateChecking = false;
  bool _updateFailed = false;
  bool _updateHasNewer = false;
  String _updateStatus = '点击检查 HarmonyOS NEXT 独立更新源';
  AppUpdate? _latestUpdate;

  // Dynamic focused-poster ambient tint for `海报色彩氛围联动`
  Color? _focusedPosterTint;
  String _focusedPosterUrl = '';

  void _syncAmbientFromPoster(String posterUrl) {
    final url = posterUrl.trim();
    if (!widget.storage.tvAmbientPosterSync ||
        url.isEmpty ||
        url == _focusedPosterUrl) {
      return;
    }
    _focusedPosterUrl = url;
    final cached = PosterLoader.peekMemory(url);
    if (cached == null || cached.isEmpty) return;
    unawaited(() async {
      final color = await PosterLoader.extractEdgeAmbientColor(cached);
      if (!mounted || _focusedPosterUrl != url) return;
      setState(() => _focusedPosterTint = color);
    }());
  }

  @override
  void initState() {
    super.initState();
    _homeScrollController.addListener(_onHomeScroll);
    unawaited(_loadInstalledVersion());
    _reloadConfigAndFetch();
  }

  Future<String> _resolveInstalledVersion() async {
    if (OhosRuntime.isOhos) {
      final pkg = await OhosRuntime.getPackageInfo();
      if (pkg != null && pkg.version.isNotEmpty) {
        if (mounted) {
          _installedBuildNumber = pkg.buildNumber;
        }
        return pkg.version;
      }
    }
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.trim().isNotEmpty) {
        if (mounted) {
          _installedBuildNumber = info.buildNumber.trim();
        }
        return info.version.trim();
      }
    } catch (_) {}
    return '';
  }

  Future<void> _loadInstalledVersion() async {
    final ver = await _resolveInstalledVersion();
    if (!mounted) return;
    setState(() {
      _installedVersion = ver.isNotEmpty ? ver : '未知';
    });
  }

  Future<void> _checkHarmonyUpdate() async {
    if (_updateChecking) return;
    setState(() {
      _updateChecking = true;
      _updateFailed = false;
      _updateHasNewer = false;
      _latestUpdate = null;
      _updateStatus = '正在检查 HarmonyOS NEXT 独立更新源…';
    });
    try {
      final installed = await _resolveInstalledVersion();
      if (installed.isEmpty) {
        throw const FormatException('无法读取已安装版本');
      }
      if (mounted) {
        _installedVersion = installed;
      }
      final platform = OhosRuntime.isOhos ? 'harmonyos' : AppUpdate.currentPlatform;
      final release = await AppUpdate.check(platform: platform);
      final targetUrl = platform == 'harmonyos'
          ? release.harmonyosUrl
          : release.downloadUrlForPlatform(platform);
      if (platform == 'harmonyos' && targetUrl == null) {
        throw const FormatException('未获取到有效的鸿蒙 HAP 安装包或校验信息');
      }
      final newer = AppUpdate.isRemoteVersionNewer(release.version, installed);
      if (!mounted) return;
      setState(() {
        _latestUpdate = release;
        _updateHasNewer = newer;
        _updateFailed = false;
        _updateChecking = false;
        _updateStatus = newer
            ? '发现新版本 v${release.version}（当前 v$installed）'
            : '当前已是最新版本（v$installed）';
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _latestUpdate = null;
        _updateHasNewer = false;
        _updateFailed = true;
        _updateChecking = false;
        _updateStatus = '检查更新失败：${e.message}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _latestUpdate = null;
        _updateHasNewer = false;
        _updateFailed = true;
        _updateChecking = false;
        _updateStatus = '暂时无法检查更新，请检查网络后重试';
      });
    }
  }

  Future<void> _openOrCopyHarmonyUpdateUrl(String url, String label) async {
    if (OhosRuntime.isOhos) {
      final opened = await OhosRuntime.openExternalUrl(url);
      if (opened) return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    _showToast('已复制$label：$url');
  }

  @override
  void dispose() {
    _homeScrollController.dispose();
    super.dispose();
  }

  void _onHomeScroll() {
    if (_loadingMore || _homeLoading || _selectedCategoryId.isEmpty) {
      return;
    }
    if (_currentPage >= _pageCount) {
      return;
    }
    final pos = _homeScrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 360) {
      unawaited(_loadMoreCategory());
    }
  }

  void _reloadConfigAndFetch() {
    final cfg = widget.storage.loadSavedConfig();
    final available = cfg?.publicAvailableSites ?? const <CmsSite>[];
    CmsSite? chosen;
    if (available.isNotEmpty) {
      final savedKey = widget.storage.selectedSiteKey;
      for (final s in available) {
        if (s.key == savedKey) {
          chosen = s;
          break;
        }
      }
      chosen ??= available.first;
    }
    setState(() {
      _config = cfg;
      _activeSite = chosen;
      _categories = const [];
      _selectedCategoryId = '';
      _homeVideos = const [];
      _homeError = null;
    });
    if (chosen != null) {
      unawaited(_loadSiteHome(chosen));
    }
    final lives = cfg?.publicSupportedLives ?? const <LiveSource>[];
    if (lives.isNotEmpty) {
      _selectedLiveSourceIdx =
          _selectedLiveSourceIdx.clamp(0, lives.length - 1);
      unawaited(_loadLiveSource(lives[_selectedLiveSourceIdx]));
    } else {
      setState(() => _liveGroups = const []);
    }
  }

  Future<void> _loadSiteHome(CmsSite site) async {
    final epoch = ++_homeEpoch;
    setState(() {
      _homeLoading = true;
      _homeError = null;
      _selectedCategoryId = '';
      _currentPage = 1;
      _pageCount = 1;
    });
    try {
      final (cats, listing) = await widget.client.fetchHome(site);
      if (!mounted || epoch != _homeEpoch) {
        return;
      }
      setState(() {
        _categories = cats.where((c) => c.isTopLevel).toList(growable: false);
        _homeVideos = listing.videos;
        _currentPage = listing.page;
        _pageCount = listing.pageCount;
        _homeLoading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _homeEpoch) {
        return;
      }
      setState(() {
        _homeLoading = false;
        _homeError = e.toString();
      });
    }
  }

  Future<void> _selectCategory(String categoryId) async {
    final site = _activeSite;
    if (site == null) {
      return;
    }
    if (categoryId.isEmpty) {
      await _loadSiteHome(site);
      return;
    }
    final epoch = ++_homeEpoch;
    setState(() {
      _selectedCategoryId = categoryId;
      _homeLoading = true;
      _homeError = null;
      _currentPage = 1;
    });
    try {
      final listing = await widget.client.fetchCategory(site, categoryId, 1);
      if (!mounted || epoch != _homeEpoch) {
        return;
      }
      setState(() {
        _homeVideos = listing.videos;
        _currentPage = listing.page;
        _pageCount = listing.pageCount;
        _homeLoading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _homeEpoch) {
        return;
      }
      setState(() {
        _homeLoading = false;
        _homeError = e.toString();
      });
    }
  }

  Future<void> _loadMoreCategory() async {
    final site = _activeSite;
    if (site == null ||
        _selectedCategoryId.isEmpty ||
        _loadingMore ||
        _currentPage >= _pageCount) {
      return;
    }
    final epoch = _homeEpoch;
    final nextPage = _currentPage + 1;
    setState(() => _loadingMore = true);
    try {
      final listing = await widget.client.fetchCategory(
        site,
        _selectedCategoryId,
        nextPage,
      );
      if (!mounted || epoch != _homeEpoch) {
        return;
      }
      setState(() {
        _homeVideos = <CmsVideo>[..._homeVideos, ...listing.videos];
        _currentPage = nextPage;
        _pageCount = listing.pageCount;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted && epoch == _homeEpoch) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _loadLiveSource(LiveSource source) async {
    final epoch = ++_liveEpoch;
    setState(() {
      _liveLoading = true;
      _liveError = null;
      _selectedLiveGroupIdx = 0;
    });
    try {
      final groups = await widget.client.fetchLiveGroups(source);
      if (!mounted || epoch != _liveEpoch) {
        return;
      }
      setState(() {
        _liveGroups = groups;
        _liveLoading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _liveEpoch) {
        return;
      }
      setState(() {
        _liveLoading = false;
        _liveError = e.toString();
      });
    }
  }

  Future<void> _runGlobalSearch() async {
    final kw = _searchQuery.trim();
    if (kw.isEmpty) {
      return;
    }
    final allSites = (_config?.publicAvailableSites ?? const <CmsSite>[])
        .where((s) => s.searchable)
        .toList(growable: false);
    final epoch = ++_searchEpoch;
    setState(() {
      _searching = allSites.isNotEmpty;
      _searchPerformed = true;
      _searchActiveKeyword = kw;
      _searchSelectedSiteKey = '__all__';
      _searchResults.clear();
      _searchTotalSites = allSites.length;
      _searchCompletedSites = 0;
      _searchSucceededSites = 0;
      _searchFailedCount = 0;
      _searchTimedOutCount = 0;
    });
    if (allSites.isEmpty) {
      return;
    }
    unawaited(widget.storage.addSearchKeyword(kw));
    const batchSize = 16;
    const concurrency = 4;

    for (var batchStart = 0;
        batchStart < allSites.length;
        batchStart += batchSize) {
      if (!mounted || epoch != _searchEpoch) {
        return;
      }
      final batchEnd = math.min(batchStart + batchSize, allSites.length);
      final batch = allSites.sublist(batchStart, batchEnd);
      var cursor = 0;

      Future<void> worker() async {
        while (cursor < batch.length && mounted && epoch == _searchEpoch) {
          final site = batch[cursor++];
          try {
            final res = await widget.client
                .fetchSearch(site, kw)
                .timeout(widget.searchSiteTimeout);
            if (!mounted || epoch != _searchEpoch) {
              return;
            }
            setState(() {
              _searchCompletedSites++;
              _searchSucceededSites++;
              if (res.videos.isNotEmpty) {
                for (final v in res.videos) {
                  _searchResults.add((site, v));
                }
              }
            });
          } on TimeoutException {
            if (!mounted || epoch != _searchEpoch) {
              return;
            }
            setState(() {
              _searchCompletedSites++;
              _searchFailedCount++;
              _searchTimedOutCount++;
            });
          } catch (_) {
            if (!mounted || epoch != _searchEpoch) {
              return;
            }
            setState(() {
              _searchCompletedSites++;
              _searchFailedCount++;
            });
          }
        }
      }

      final workerCount = math.min(concurrency, batch.length);
      await Future.wait<void>(
        List<Future<void>>.generate(workerCount, (_) => worker()),
      );
    }

    if (mounted && epoch == _searchEpoch) {
      setState(() => _searching = false);
    }
  }

  Future<void> _openDetail(CmsSite site, CmsVideo video) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TvDetailScreen(
          site: site,
          initialVideo: video,
          storage: widget.storage,
          client: widget.client,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openLiveGroupPlayer(LiveSource source, LiveGroup group, int channelIdx) async {
    if (group.channels.isEmpty) {
      return;
    }
    final safeChannelIdx = channelIdx.clamp(0, group.channels.length - 1);
    final channel = group.channels[safeChannelIdx];
    final channelEpisodes = channel.episodes;
    if (channelEpisodes.isEmpty) {
      return;
    }
    final catalogGroups = _liveGroups.any((g) => g.channels.isNotEmpty)
        ? _liveGroups
        : <LiveGroup>[group];
    final liveVideo = CmsVideo(
      id: channel.name,
      title: channel.name,
      lines: [
        CmsLine(
          name: channel.group.isNotEmpty ? channel.group : group.name,
          episodes: channelEpisodes,
        ),
      ],
    );
    final route = widget.debugLiveRouteBuilder?.call(
          source.playbackSite,
          liveVideo,
          catalogGroups,
          channel,
        ) ??
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            site: source.playbackSite,
            video: liveVideo,
            initialLineIndex: 0,
            initialEpisodeIndex: 0,
            storage: widget.storage,
            isLive: true,
            liveGroups: catalogGroups,
            initialLiveChannel: channel,
          ),
        );
    await Navigator.of(context).push<void>(route);
  }

  Future<void> _showQrSyncDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => TvQrSyncDialog(
        storage: widget.storage,
        onConfigChanged: _reloadConfigAndFetch,
      ),
    );
  }

  Future<void> _showSitePickerDialog() async {
    final allSites = _config?.publicSupportedSites ?? const <CmsSite>[];
    final availableCount =
        (_config?.publicAvailableSites ?? const <CmsSite>[]).length;
    final subs = widget.storage
        .getSubscriptions()
        .where((s) => !s.isEffectivelyPrivate)
        .toList(growable: false);

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return Dialog(
          backgroundColor: const Color(0xEB101928),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
            side: const BorderSide(
              color: TvAmbientColors.glassStroke,
              width: 1.2,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '切换片源（可用 $availableCount / 共 ${allSites.length}）',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TvFocusPill(
                        onSelect: () => Navigator.of(dialogCtx).pop(),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                  if (subs.any((s) => s.depots.isNotEmpty)) ...[
                    const SizedBox(height: 14),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final sub in subs)
                            for (final depot in sub.depots)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: TvFocusPill(
                                  selected: sub.activeDepotName == depot.name,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  onSelect: () async {
                                    Navigator.of(dialogCtx).pop();
                                    await _switchDepot(sub, depot);
                                  },
                                  child: Text(
                                    '仓库: ${depot.name}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: allSites.isEmpty
                        ? const Center(
                            child: Text(
                              '尚未导入任何订阅源，请先扫码或输入地址导入配置',
                              style: TextStyle(color: AppleColors.labelSecondary),
                            ),
                          )
                        : ListView.separated(
                            itemCount: allSites.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, idx) {
                              final site = allSites[idx];
                              final ok = site.supported;
                              final isCurrent = _activeSite?.key == site.key;
                              return Opacity(
                                opacity: ok ? 1.0 : 0.48,
                                child: TvFocusPill(
                                  autofocus: isCurrent,
                                  selected: isCurrent,
                                  borderRadius: 14,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 12,
                                  ),
                                  onSelect: ok
                                      ? () async {
                                          Navigator.of(dialogCtx).pop();
                                          await widget.storage
                                              .setSelectedSiteKey(site.key);
                                          setState(() => _activeSite = site);
                                          await _loadSiteHome(site);
                                        }
                                      : null,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              site.name,
                                              style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            if (!ok)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  top: 3,
                                                ),
                                                child: Text(
                                                  CmsSite.capabilityReason(
                                                    site.capabilityStatus,
                                                  ),
                                                  style: const TextStyle(
                                                    color: AppleColors
                                                        .labelSecondary,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      Text(
                                        isCurrent
                                            ? '当前使用'
                                            : (ok ? '可用' : '受限'),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: ok
                                              ? AppleColors.systemGreen
                                              : AppleColors.labelTertiary,
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
          ),
        );
      },
    );
  }

  Future<void> _switchDepot(SubscriptionEntry sub, CmsDepot depot) async {
    setState(() => _homeLoading = true);
    try {
      final updated = await widget.client.switchSubscriptionDepot(sub, depot);
      final all = widget.storage.getSubscriptions().map((item) {
        return item.id == updated.id ? updated : item;
      }).toList();
      await widget.storage.saveSubscriptions(all);
      _reloadConfigAndFetch();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _homeLoading = false);
      _showToast('切换子仓库失败：$e');
    }
  }

  Future<void> _showUrlImportDialog() async {
    final controller = TextEditingController(text: widget.storage.configOrigin);
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        var submitting = false;
        String? errorMsg;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            Future<void> submit([String? rawOverride]) async {
              if (submitting) {
                return;
              }
              setDialogState(() {
                submitting = true;
                errorMsg = null;
              });
              try {
                final input = rawOverride ?? controller.text;
                final resolved = await widget.client.resolveConfigInput(
                  urlInput: input,
                );
                await widget.storage.saveConfig(
                  resolved.rawConfig,
                  origin: resolved.origin,
                  depots: resolved.depots,
                  activeDepotName: resolved.activeDepotName,
                );
                if (dialogCtx.mounted) {
                  Navigator.of(dialogCtx).pop();
                }
                _reloadConfigAndFetch();
                _showToast('配置导入成功');
              } catch (e) {
                setDialogState(() {
                  submitting = false;
                  errorMsg = e.toString();
                });
              }
            }

            return Dialog(
              backgroundColor: const Color(0xFF181A22),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Padding(
                  padding: const EdgeInsets.all(26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '输入配置地址或读取剪贴板',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: controller,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: '输入用户合法拥有的 JSON / 多仓 / M3U 配置地址',
                          hintStyle: const TextStyle(
                            color: AppleColors.labelTertiary,
                          ),
                          filled: true,
                          fillColor: const Color(0xFF0E1016),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onSubmitted: (_) => submit(),
                      ),
                      if (errorMsg != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          errorMsg!,
                          style: const TextStyle(
                            color: AppleColors.systemRed,
                            fontSize: 13,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TvFocusPill(
                            onSelect: () async {
                              final clip = await Clipboard.getData(
                                Clipboard.kTextPlain,
                              );
                              final text = clip?.text?.trim() ?? '';
                              if (text.isNotEmpty) {
                                controller.text = text;
                                await submit(text);
                              }
                            },
                            child: const Text('📋 粘贴并导入'),
                          ),
                          const SizedBox(width: 12),
                          TvFocusPill(
                            onSelect: () => Navigator.of(dialogCtx).pop(),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 12),
                          TvFocusPill(
                            selected: true,
                            onSelect: submitting ? null : () => submit(),
                            child: Text(submitting ? '导入中…' : '确认导入'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _importLocalConfigOrBackup({required bool isBackup}) async {
    try {
      String? content;
      if (OhosRuntime.isOhos) {
        final picked = await OhosRuntime.pickDocumentFile(
          purpose: isBackup
              ? OhosDocumentPurpose.backup
              : OhosDocumentPurpose.subscription,
          maxBytes: isBackup
              ? StorageService.maxSyncPayloadBytes
              : CmsClient.maxResponseBytes,
        );
        if (picked == null) {
          return;
        }
        content = isBackup
            ? picked.decodeUtf8(allowMalformed: false)
            : CmsClient.readSubscriptionFile(picked.bytes, picked.name);
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: isBackup
              ? const ['json']
              : const ['json', 'zip', 'txt', 'm3u', 'm3u8'],
          withData: true,
        );
        if (result != null && result.files.isNotEmpty) {
          final f = result.files.first;
          final Uint8List rawBytes;
          if (f.bytes != null) {
            rawBytes = f.bytes!;
          } else if (f.path != null) {
            rawBytes = await File(f.path!).readAsBytes();
          } else {
            return;
          }
          if (isBackup) {
            if (rawBytes.length > StorageService.maxSyncPayloadBytes) {
              throw const FormatException('备份文件超过 8 MB 限制');
            }
            content = utf8.decode(rawBytes, allowMalformed: false);
          } else {
            content = CmsClient.readSubscriptionFile(rawBytes, f.name);
          }
        }
      }
      if (content == null || content.trim().isEmpty) {
        return;
      }
      if (isBackup) {
        await widget.storage.importBackupJson(content);
        _reloadConfigAndFetch();
        _showToast('跨端备份已恢复');
      } else {
        final resolved = await widget.client.resolveConfigInput(
          rawTextInput: content,
        );
        await widget.storage.saveConfig(
          resolved.rawConfig,
          origin: resolved.origin,
          depots: resolved.depots,
          activeDepotName: resolved.activeDepotName,
        );
        _reloadConfigAndFetch();
        _showToast('本地配置导入成功');
      }
    } on FormatException catch (e) {
      _showToast('文件导入失败：${e.message}');
    } catch (e) {
      _showToast('文件导入失败：$e');
    }
  }

  Future<void> _exportBackup() async {
    try {
      final jsonText = widget.storage.exportBackupJson();
      const fileName = 'marco-movie-backup.json';
      if (OhosRuntime.isOhos) {
        final saved = await OhosRuntime.saveTextFile(
          fileName: fileName,
          content: jsonText,
        );
        if (saved != null) {
          _showToast('已导出备份文件');
        }
        return;
      }
      await Clipboard.setData(ClipboardData(text: jsonText));
      _showToast('跨端备份 JSON 已复制到剪贴板');
    } catch (e) {
      _showToast('备份导出失败：$e');
    }
  }

  void _showToast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _stepLiveGroup(int delta) {
    if (_liveGroups.length <= 1) {
      return;
    }
    setState(() {
      final len = _liveGroups.length;
      _selectedLiveGroupIdx = ((_selectedLiveGroupIdx + delta) % len + len) % len;
    });
  }

  KeyEventResult _handleRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    // Menu / F1 opens Site Picker anywhere on main shell
    if (event.logicalKey == LogicalKeyboardKey.contextMenu ||
        event.logicalKey == LogicalKeyboardKey.f1) {
      unawaited(_showSitePickerDialog());
      return KeyEventResult.handled;
    }
    if (_tabIndex == 1 && _liveGroups.length > 1) {
      if (event.logicalKey == LogicalKeyboardKey.bracketLeft ||
          event.logicalKey == LogicalKeyboardKey.pageUp) {
        _stepLiveGroup(-1);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.bracketRight ||
          event.logicalKey == LogicalKeyboardKey.pageDown) {
        _stepLiveGroup(1);
        return KeyEventResult.handled;
      }
    }
    // Triple-Up on Home scrolls smoothly back to top
    if (_tabIndex == 0 && event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastUpPressMs <= 900) {
        _upPressCount++;
      } else {
        _upPressCount = 1;
      }
      _lastUpPressMs = now;
      if (_upPressCount >= 3) {
        _upPressCount = 0;
        if (_homeScrollController.hasClients) {
          unawaited(
            _homeScrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final themeId = widget.storage.tvAmbientTheme;
    final intensity = widget.storage.tvAmbientIntensity;
    final posterSync = widget.storage.tvAmbientPosterSync;

    return Focus(
      onKeyEvent: _handleRootKey,
      child: Scaffold(
        backgroundColor: TvAmbientColors.background,
        body: Stack(
          fit: StackFit.expand,
          children: [
            TvAmbientSoftGlowBackground(
              themeId: themeId,
              intensity: intensity,
              posterAmbientColor: _focusedPosterTint,
              posterSync: posterSync,
            ),
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildFloatingTopBar(),
                  Expanded(
                    child: switch (_tabIndex) {
                      1 => _buildLiveView(),
                      2 => _buildSearchView(),
                      3 => _buildLibraryView(),
                      4 => _buildSettingsView(),
                      _ => _buildHomeView(),
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingTopBar() {
    const tabs = <(IconData, String)>[
      (CupertinoIcons.tv, '发现'),
      (CupertinoIcons.dot_radiowaves_left_right, '直播'),
      (CupertinoIcons.search, '搜索'),
      (CupertinoIcons.collections, '片库'),
      (CupertinoIcons.gear_alt, '设置'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 28, 56, 18),
      child: SizedBox(
        height: 62,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: MarcoBrandLogo(iconSize: 42, fontSize: 23),
            ),
            // Centered Apple TV-parity floating frosted-glass capsule tab bar
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: const Color(0x880B1320),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 1.1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.34),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Padding(
                      padding: EdgeInsets.only(right: i == tabs.length - 1 ? 0 : 4),
                      child: _TvFloatingNavTab(
                        icon: tabs[i].$1,
                        label: tabs[i].$2,
                        selected: _tabIndex == i,
                        autofocus: i == 0 && _activeSite == null,
                        onSelect: () => setState(() => _tabIndex = i),
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

  Widget _buildHomeView() {
    if (_activeSite == null) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 720),
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.085),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: TvAmbientColors.glassStroke, width: 1.2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MarcoBrandLogo(iconSize: 76, fontSize: 36, stacked: true),
              const SizedBox(height: 18),
              const Text(
                '本软件仅提供通用媒体目录解析与本地播放能力，不内置、不提供、不托管任何影视或直播内容。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: TvAmbientColors.secondaryText,
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  TvFocusPill(
                    autofocus: true,
                    prominent: true,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                    onSelect: _showQrSyncDialog,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.qrcode_viewfinder, size: 18),
                        SizedBox(width: 8),
                        Text('手机扫码推送配置', style: TextStyle(fontSize: 16)),
                      ],
                    ),
                  ),
                  TvFocusPill(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                    onSelect: _showUrlImportDialog,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.link, size: 17),
                        SizedBox(width: 8),
                        Text('输入地址 / 剪贴板导入', style: TextStyle(fontSize: 16)),
                      ],
                    ),
                  ),
                  TvFocusPill(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                    onSelect: () => _importLocalConfigOrBackup(isBackup: false),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.folder_fill, size: 17),
                        SizedBox(width: 8),
                        Text('本地文件导入', style: TextStyle(fontSize: 16)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final history = widget.storage.getWatchHistory();
    final showContinue =
        widget.storage.showContinueWatching &&
        _selectedCategoryId.isEmpty &&
        history.isNotEmpty;
    final screenW = MediaQuery.sizeOf(context).width;
    final gridCols = screenW >= 1500 ? 6 : (screenW >= 1100 ? 5 : 4);

    return CustomScrollView(
      controller: _homeScrollController,
      slivers: [
        // Sub-toolbar: left glass category pills, right site switcher + LAN QR push
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(56, 8, 56, 22),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: TvFocusPill(
                            selected: _selectedCategoryId.isEmpty,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 22,
                              vertical: 11,
                            ),
                            onSelect: () => _selectCategory(''),
                            child: const Text(
                              '精选推荐',
                              style: TextStyle(fontSize: 17),
                            ),
                          ),
                        ),
                        for (final cat in _categories)
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: TvFocusPill(
                              selected: _selectedCategoryId == cat.id,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 11,
                              ),
                              onSelect: () => _selectCategory(cat.id),
                              child: Text(
                                cat.name,
                                style: const TextStyle(fontSize: 17),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                TvFocusPill(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 11,
                  ),
                  onSelect: _showSitePickerDialog,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(CupertinoIcons.layers_alt_fill, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        _activeSite?.name ?? '切换片源',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                TvFocusPill(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 11,
                  ),
                  onSelect: _showQrSyncDialog,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.qrcode, size: 16),
                      SizedBox(width: 8),
                      Text('扫码快传', style: TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showContinue)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 56, 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '继续观看',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 214,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: history.take(12).length,
                      separatorBuilder: (_, __) => const SizedBox(width: 24),
                      itemBuilder: (context, idx) {
                        final item = history[idx];
                        final site = (_config?.publicAvailableSites ?? const [])
                            .where((s) => s.key == item.site)
                            .firstOrNull ??
                            _activeSite!;
                        final vid = CmsVideo(
                          id: item.id,
                          title: item.title,
                          poster: item.poster,
                          remarks: item.episode,
                        );
                        return TvWideContinueCard(
                          autofocus: idx == 0,
                          entry: item,
                          onFocusGained: () => _syncAmbientFromPoster(item.poster),
                          onSelect: () => _openDetail(site, vid),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (showContinue && !_homeLoading && _homeVideos.isNotEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(56, 0, 56, 16),
              child: Text(
                '精选片库',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        if (_homeLoading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CupertinoActivityIndicator(radius: 18)),
          )
        else if (_homeError != null && _homeVideos.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '加载内容失败：$_homeError',
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TvFocusPill(
                        prominent: true,
                        onSelect: () => _loadSiteHome(_activeSite!),
                        child: const Text('重试加载'),
                      ),
                      const SizedBox(width: 14),
                      TvFocusPill(
                        onSelect: _showSitePickerDialog,
                        child: const Text('切换其他片源'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(56, 4, 56, 44),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: gridCols,
                mainAxisSpacing: 28,
                crossAxisSpacing: 24,
                childAspectRatio: 0.56,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final video = _homeVideos[index];
                  return TvFocusablePosterCard(
                    autofocus: index == 0 && !showContinue,
                    video: video,
                    onFocusGained: () => _syncAmbientFromPoster(video.poster),
                    onSelect: () => _openDetail(_activeSite!, video),
                  );
                },
                childCount: _homeVideos.length,
              ),
            ),
          ),
        if (_loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(bottom: 32),
              child: Center(child: CupertinoActivityIndicator(radius: 14)),
            ),
          ),
      ],
    );
  }

  Widget _buildLiveView() {
    final lives = _config?.publicSupportedLives ?? const <LiveSource>[];
    if (lives.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.tv,
              size: 48,
              color: TvAmbientColors.mutedText,
            ),
            const SizedBox(height: 14),
            const Text(
              '当前配置未包含可用的直播列表',
              style: TextStyle(
                color: TvAmbientColors.secondaryText,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 18),
            TvFocusPill(
              prominent: true,
              onSelect: _showQrSyncDialog,
              child: const Text('扫码导入直播源'),
            ),
          ],
        ),
      );
    }

    final activeSource = lives[_selectedLiveSourceIdx.clamp(0, lives.length - 1)];
    final safeGroupIdx = _liveGroups.isEmpty
        ? 0
        : _selectedLiveGroupIdx.clamp(0, _liveGroups.length - 1);
    final activeGroup = _liveGroups.isEmpty ? null : _liveGroups[safeGroupIdx];
    final channels = activeGroup?.channels ?? const <LiveChannel>[];
    final totalChannels = _liveGroups.fold<int>(
      0,
      (sum, g) => sum + g.channels.length,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 8, 56, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent && _liveGroups.length > 1) {
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                  _stepLiveGroup(-1);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  _stepLiveGroup(1);
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: Row(
              children: [
                const Text(
                  '电视直播',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (lives.length > 1) ...[
                  const SizedBox(width: 18),
                  for (var i = 0; i < lives.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: TvFocusPill(
                        selected: i == _selectedLiveSourceIdx,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
                        onSelect: () {
                          setState(() => _selectedLiveSourceIdx = i);
                          unawaited(_loadLiveSource(lives[i]));
                        },
                        child: Text(
                          lives[i].name,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ),
                ],
                if (!_liveLoading && _liveError == null && activeGroup != null) ...[
                  const SizedBox(width: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: TvAmbientColors.glassStroke,
                        width: 0.9,
                      ),
                    ),
                    child: Text(
                      '${activeSource.name} · ${_liveGroups.length} 组 / 共 $totalChannels 频道',
                      style: const TextStyle(
                        color: TvAmbientColors.secondaryText,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: TvAmbientColors.accent.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: TvAmbientColors.accent.withValues(alpha: 0.55),
                        width: 0.9,
                      ),
                    ),
                    child: Text(
                      '当前分组：${activeGroup.name} (${channels.length} 台)',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                const Text(
                  '全屏播放时按遥控器上 / 下方向键即可快速换台',
                  style: TextStyle(
                    color: TvAmbientColors.mutedText,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Expanded(
            child: _liveLoading
                ? const Center(child: CupertinoActivityIndicator(radius: 16))
                : _liveError != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '直播列表读取失败：$_liveError',
                              style: const TextStyle(color: Colors.orangeAccent),
                            ),
                            const SizedBox(height: 14),
                            TvFocusPill(
                              prominent: true,
                              onSelect: () => _loadLiveSource(activeSource),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 268,
                            child: ListView.separated(
                              itemCount: _liveGroups.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (_, idx) {
                                final g = _liveGroups[idx];
                                return TvFocusPill(
                                  autofocus: idx == safeGroupIdx,
                                  selected: idx == safeGroupIdx,
                                  borderRadius: 14,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 14,
                                  ),
                                  onSelect: () => setState(
                                    () => _selectedLiveGroupIdx = idx,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          g.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 17),
                                        ),
                                      ),
                                      Text(
                                        '${g.channels.length}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: TvAmbientColors.secondaryText,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 28),
                          Expanded(
                            child: GridView.builder(
                              itemCount: channels.length,
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    mainAxisSpacing: 16,
                                    crossAxisSpacing: 16,
                                    childAspectRatio: 4.5,
                                  ),
                              itemBuilder: (_, idx) {
                                final ch = channels[idx];
                                return TvFocusPill(
                                  borderRadius: 16,
                                  preserveColorsOnFocus: true,
                                  padding: const EdgeInsets.all(14),
                                  onSelect: () => _openLiveGroupPlayer(
                                    activeSource,
                                    _liveGroups[safeGroupIdx],
                                    idx,
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: TvAmbientColors.accent
                                              .withValues(alpha: 0.22),
                                          borderRadius:
                                              BorderRadius.circular(11),
                                        ),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          CupertinoIcons.tv_fill,
                                          size: 20,
                                          color: TvAmbientColors.accent,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              ch.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 17,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              '可用线路 ${ch.episodes.length} 条',
                                              style: const TextStyle(
                                                color: TvAmbientColors
                                                    .secondaryText,
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchView() {
    final siteCounts = <String, (CmsSite, int)>{};
    for (final (site, _) in _searchResults) {
      final prev = siteCounts[site.key];
      siteCounts[site.key] = (site, (prev?.$2 ?? 0) + 1);
    }
    final filteredResults = _searchSelectedSiteKey == '__all__'
        ? _searchResults
        : _searchResults
            .where((entry) => entry.$1.key == _searchSelectedSiteKey)
            .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 8, 56, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 444,
            child: SingleChildScrollView(
              child: TvRemoteGridKeyboard(
                query: _searchQuery,
                history: widget.storage.getSearchHistory(),
                onQueryChanged: (next) => setState(() => _searchQuery = next),
                onSubmit: _runGlobalSearch,
                onClearHistory: () async {
                  await widget.storage.clearSearchHistory();
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
          const SizedBox(width: 34),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_searching)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        const CupertinoActivityIndicator(radius: 11),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '正在多站并发搜索「$_searchActiveKeyword」（已完成 $_searchCompletedSites/$_searchTotalSites 站'
                            '${_searchFailedCount > 0 ? " · 异常 $_searchFailedCount" : ""}）…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: TvAmbientColors.secondaryText,
                              fontSize: 15.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (_searchResults.isNotEmpty && _searchFailedCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '已搜索全部 $_searchTotalSites 站，另有 $_searchFailedCount 个站点异常'
                      '${_searchTimedOutCount > 0 ? "（含 $_searchTimedOutCount 站超时）" : ""}',
                      style: const TextStyle(
                        color: Color(0xFFFFCA58),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (_searchResults.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: TvFocusPill(
                              selected: _searchSelectedSiteKey == '__all__',
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              onSelect: () => setState(
                                () => _searchSelectedSiteKey = '__all__',
                              ),
                              child: Text(
                                '全部结果 (${_searchResults.length})',
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                          ),
                          for (final entry in siteCounts.values)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: TvFocusPill(
                                selected:
                                    _searchSelectedSiteKey == entry.$1.key,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                                onSelect: () => setState(
                                  () => _searchSelectedSiteKey = entry.$1.key,
                                ),
                                child: Text(
                                  '${entry.$1.name} (${entry.$2})',
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: !_searchPerformed
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.search,
                                size: 48,
                                color: TvAmbientColors.mutedText,
                              ),
                              SizedBox(height: 14),
                              Text(
                                '在左侧输入关键词或拼音首字母，即可跨全部可用片源并发检索',
                                style: TextStyle(
                                  color: TvAmbientColors.secondaryText,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        )
                      : (filteredResults.isEmpty && !_searching)
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _searchTotalSites > 0 &&
                                            _searchSucceededSites == 0 &&
                                            _searchFailedCount > 0
                                        ? CupertinoIcons.exclamationmark_triangle_fill
                                        : CupertinoIcons.search,
                                    size: 42,
                                    color: _searchTotalSites > 0 &&
                                            _searchSucceededSites == 0 &&
                                            _searchFailedCount > 0
                                        ? AppleColors.systemOrange
                                        : TvAmbientColors.mutedText,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    _searchTotalSites > 0 &&
                                            _searchSucceededSites == 0 &&
                                            _searchFailedCount > 0
                                        ? '搜索失败：全部 $_searchTotalSites 个站点均连接失败或超时'
                                            '${_searchTimedOutCount > 0 ? "（超时 $_searchTimedOutCount 站）" : ""}'
                                        : '未找到匹配的影视内容，可尝试缩短关键词',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: TvAmbientColors.secondaryText,
                                      fontSize: 16,
                                    ),
                                  ),
                                  if (_searchSucceededSites > 0 &&
                                      _searchFailedCount > 0) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      '另有 $_searchFailedCount 个站点异常'
                                      '${_searchTimedOutCount > 0 ? "（含 $_searchTimedOutCount 站超时）" : ""}',
                                      style: const TextStyle(
                                        color: Color(0xFFFFCA58),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                  if (_searchFailedCount > 0) ...[
                                    const SizedBox(height: 18),
                                    TvFocusPill(
                                      key: const ValueKey('tv-search-retry-btn'),
                                      prominent: true,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 22,
                                        vertical: 11,
                                      ),
                                      onSelect: _runGlobalSearch,
                                      child: const Text(
                                        '重新搜索',
                                        style: TextStyle(fontSize: 15.5),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            )
                          : GridView.builder(
                              itemCount: filteredResults.length,
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 5,
                                    mainAxisSpacing: 24,
                                    crossAxisSpacing: 22,
                                    childAspectRatio: 0.54,
                                  ),
                              itemBuilder: (_, idx) {
                                final (site, video) = filteredResults[idx];
                                return TvFocusablePosterCard(
                                  video: video,
                                  sourceSubtitle: site.name,
                                  onFocusGained: () =>
                                      _syncAmbientFromPoster(video.poster),
                                  onSelect: () => _openDetail(site, video),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryView() {
    final history = widget.storage.getWatchHistory();
    final favorites = widget.storage.getFavorites();
    final availableSites = _config?.publicAvailableSites ?? const <CmsSite>[];
    final screenW = MediaQuery.sizeOf(context).width;
    final gridCols = screenW >= 1500 ? 6 : 4;

    CmsSite resolveSite(String siteKey) {
      for (final s in availableSites) {
        if (s.key == siteKey) return s;
      }
      return _activeSite ??
          CmsSite(key: siteKey, name: siteKey, type: 1, api: '');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 8, 56, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TvFocusPill(
                selected: _librarySegment == 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
                onSelect: () => setState(() => _librarySegment = 0),
                child: const Text('观看历史', style: TextStyle(fontSize: 17)),
              ),
              const SizedBox(width: 12),
              TvFocusPill(
                selected: _librarySegment == 1,
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
                onSelect: () => setState(() => _librarySegment = 1),
                child: const Text('我的收藏', style: TextStyle(fontSize: 17)),
              ),
              const Spacer(),
              if (_librarySegment == 0 && history.isNotEmpty)
                TvFocusPill(
                  destructive: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                  onSelect: () async {
                    await widget.storage.clearWatchHistory();
                    if (mounted) setState(() {});
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.trash, size: 15),
                      SizedBox(width: 6),
                      Text('清空观看历史', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: _librarySegment == 0
                ? (history.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无观看记录',
                          style: TextStyle(
                            color: TvAmbientColors.secondaryText,
                            fontSize: 17,
                          ),
                        ),
                      )
                    : GridView.builder(
                        itemCount: history.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: gridCols,
                          mainAxisSpacing: 26,
                          crossAxisSpacing: 24,
                          childAspectRatio: 0.50,
                        ),
                        itemBuilder: (_, idx) {
                          final h = history[idx];
                          final pct =
                              (h.progressFraction * 100).round().clamp(0, 100);
                          final badge = h.episode.isEmpty
                              ? '$pct%'
                              : '${h.episode} · $pct%';
                          final vid = CmsVideo(
                            id: h.id,
                            title: h.title,
                            poster: h.poster,
                            remarks: badge,
                          );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TvFocusablePosterCard(
                                  video: vid,
                                  subtitleBadge: badge,
                                  onFocusGained: () =>
                                      _syncAmbientFromPoster(h.poster),
                                  onSelect: () =>
                                      _openDetail(resolveSite(h.site), vid),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TvFocusPill(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 6,
                                ),
                                onSelect: () async {
                                  await widget.storage
                                      .removeWatchHistoryItem(h.site, h.id);
                                  if (mounted) setState(() {});
                                },
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(CupertinoIcons.xmark_circle, size: 14),
                                    SizedBox(width: 5),
                                    Text(
                                      '移除记录',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ))
                : (favorites.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无收藏影片',
                          style: TextStyle(
                            color: TvAmbientColors.secondaryText,
                            fontSize: 17,
                          ),
                        ),
                      )
                    : GridView.builder(
                        itemCount: favorites.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: gridCols,
                          mainAxisSpacing: 26,
                          crossAxisSpacing: 24,
                          childAspectRatio: 0.50,
                        ),
                        itemBuilder: (_, idx) {
                          final fav = favorites[idx];
                          final site = resolveSite(fav.site);
                          final vid = CmsVideo(
                            id: fav.id,
                            title: fav.title,
                            poster: fav.poster,
                            remarks: fav.remarks,
                          );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TvFocusablePosterCard(
                                  video: vid,
                                  subtitleBadge: fav.remarks,
                                  onFocusGained: () =>
                                      _syncAmbientFromPoster(fav.poster),
                                  onSelect: () => _openDetail(site, vid),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TvFocusPill(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 6,
                                ),
                                onSelect: () async {
                                  await widget.storage
                                      .toggleFavorite(site, vid);
                                  if (mounted) setState(() {});
                                },
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(CupertinoIcons.heart_slash, size: 14),
                                    SizedBox(width: 5),
                                    Text(
                                      '取消收藏',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      )),
          ),
        ],
      ),
    );
  }

  Widget _settingsGlassCard({required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.085),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TvAmbientColors.glassStroke, width: 1.1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildSettingsView() {
    const sections = <(IconData, String)>[
      (CupertinoIcons.paintbrush_fill, '外观与柔光'),
      (CupertinoIcons.layers_alt_fill, '订阅与片源'),
      (CupertinoIcons.cloud_download_fill, '4K 网盘加速'),
      (CupertinoIcons.cloud_upload_fill, 'WebDAV 云同步'),
      (CupertinoIcons.slider_horizontal_3, '播放与跳过'),
      (CupertinoIcons.archivebox_fill, '备份与存储'),
      (CupertinoIcons.arrow_down_circle_fill, '版本与更新'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 8, 56, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 328,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 0, 10, 14),
                  child: Text(
                    '系统设置',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                for (var i = 0; i < sections.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TvFocusPill(
                      selected: _settingsSection == i,
                      borderRadius: 14,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      onSelect: () => setState(() => _settingsSection = i),
                      child: Row(
                        children: [
                          Icon(sections[i].$1, size: 17),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              sections[i].$2,
                              style: const TextStyle(fontSize: 17),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const MarcoBrandLogo(iconSize: 28, fontSize: 17),
                      const SizedBox(height: 6),
                      Text(
                        'v$_installedVersion · HarmonyOS NEXT 客厅端',
                        style: const TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: switch (_settingsSection) {
                0 => _buildSettingsAppearanceSection(),
                1 => _buildSettingsSourcesSection(),
                2 => _buildSettingsNetdiskSection(),
                3 => _buildSettingsWebdavSection(),
                4 => _buildSettingsPlaybackSection(),
                5 => _buildSettingsBackupSection(),
                _ => _buildSettingsUpdateSection(),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsAppearanceSection() {
    final currentTheme = widget.storage.tvAmbientTheme;
    final currentPreset = TvAmbientPreset.forId(currentTheme);
    final intensity = widget.storage.tvAmbientIntensity;
    final posterSync = widget.storage.tvAmbientPosterSync;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsGlassCard(
          children: [
            const Text(
              '客厅全局渐变柔光主题',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              '自由定制大屏背景柔光色彩，切换即时生效并持久化保存（当前：${currentPreset.name}）',
              style: const TextStyle(
                color: TvAmbientColors.secondaryText,
                fontSize: 14.5,
              ),
            ),
            const SizedBox(height: 18),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: TvAmbientPreset.allPresets.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 2.05,
              ),
              itemBuilder: (_, idx) {
                final preset = TvAmbientPreset.allPresets[idx];
                final selected = currentTheme == preset.id;
                return TvFocusPill(
                  selected: false,
                  preserveColorsOnFocus: true,
                  borderRadius: 18,
                  backgroundColor: selected
                      ? preset.accent.withValues(alpha: 0.24)
                      : Colors.white.withValues(alpha: 0.08),
                  padding: const EdgeInsets.all(14),
                  onSelect: () async {
                    await widget.storage.setTvAmbientTheme(preset.id);
                    if (mounted) setState(() {});
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TvAmbientPresetSwatch(
                        preset: preset,
                        selected: selected,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: preset.orbPrimary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: preset.orbSecondary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              preset.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preset.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        _settingsGlassCard(
          children: [
            const Text(
              '柔光氛围浓度与动态联动',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 96,
                  child: Text(
                    '柔光浓度',
                    style: TextStyle(
                      color: TvAmbientColors.secondaryText,
                      fontSize: 16,
                    ),
                  ),
                ),
                for (final item in const [
                  ('soft', '柔和微光'),
                  ('standard', '标准柔光'),
                  ('vivid', '浓郁流光'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: TvFocusPill(
                      selected: intensity == item.$1,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 11,
                      ),
                      onSelect: () async {
                        await widget.storage.setTvAmbientIntensity(item.$1);
                        if (mounted) setState(() {});
                      },
                      child: Text(item.$2, style: const TextStyle(fontSize: 16)),
                    ),
                  ),
                const Spacer(),
                TvFocusPill(
                  selected: posterSync,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 11,
                  ),
                  onSelect: () async {
                    await widget.storage.setTvAmbientPosterSync(!posterSync);
                    if (mounted) {
                      setState(() {
                        if (posterSync) _focusedPosterTint = null;
                      });
                    }
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        posterSync
                            ? CupertinoIcons.checkmark_alt_circle_fill
                            : CupertinoIcons.circle,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '海报色彩氛围联动',
                        style: TextStyle(fontSize: 15.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingsSourcesSection() {
    final availableCount =
        (_config?.publicAvailableSites ?? const <CmsSite>[]).length;
    final totalCount = (_config?.publicSupportedSites ?? const <CmsSite>[]).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsGlassCard(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '订阅配置导入（推荐手机扫码快传）',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        '支持一键推送多仓、TVBox JSON、M3U/TXT 直播列表及 marco-movie-backup.json',
                        style: TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 14.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                TvFocusPill(
                  prominent: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  onSelect: _showQrSyncDialog,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.qrcode_viewfinder, size: 17),
                      SizedBox(width: 8),
                      Text('手机扫码推送配置', style: TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 14,
              runSpacing: 12,
              children: [
                TvFocusPill(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  onSelect: _showUrlImportDialog,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.link, size: 16),
                      SizedBox(width: 8),
                      Text('输入地址 / 剪贴板导入', style: TextStyle(fontSize: 15.5)),
                    ],
                  ),
                ),
                TvFocusPill(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  onSelect: () => _importLocalConfigOrBackup(isBackup: false),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.folder_fill, size: 16),
                      SizedBox(width: 8),
                      Text('选择本地配置文件', style: TextStyle(fontSize: 15.5)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        _settingsGlassCard(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '多仓管理与活动片源',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '当前片源：${_activeSite?.name ?? "未配置"} · 可用 $availableCount / 共 $totalCount 个站点',
                        style: const TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 14.5,
                        ),
                      ),
                    ],
                  ),
                ),
                TvFocusPill(
                  selected: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  onSelect: _showSitePickerDialog,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.layers_alt_fill, size: 16),
                      SizedBox(width: 8),
                      Text('管理订阅源与切换仓库', style: TextStyle(fontSize: 15.5)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingsNetdiskSection() {
    const drives = <(String, String, String, String)>[
      ('quark', '我的夸父', '夸克网盘', '夸父 4K'),
      ('uc', '我的优汐', 'UC 网盘', '优汐 4K'),
      ('baidu', '我的嘟嘟', '百度网盘', '嘟嘟 4K'),
      ('ali', '我的阿狸', '阿里云盘', '阿狸 4K'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsGlassCard(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '4K 网盘扫码授权与 6 线程分片加速',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 5),
                      Text(
                        '会话凭据仅保存在本机鸿蒙 HUKS 安全存储，绝不写入公开备份文件',
                        style: TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 14.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                TvFocusPill(
                  prominent: true,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  onSelect: () => showNetdiskAccountSheet(
                    context,
                    widget.storage,
                    onChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.qrcode, size: 17),
                      SizedBox(width: 8),
                      Text('打开 4K 扫码授权', style: TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: drives.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 4.1,
              ),
              itemBuilder: (_, idx) {
                final (key, alias, realName, badge) = drives[idx];
                final loggedIn = widget.storage.isNetdiskLoggedIn(key);
                return TvFocusPill(
                  borderRadius: 16,
                  preserveColorsOnFocus: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  onSelect: () => showNetdiskAccountSheet(
                    context,
                    widget.storage,
                    initialDriveKey: key,
                    onChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              alias,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '$realName · $badge',
                              style: const TextStyle(
                                color: TvAmbientColors.secondaryText,
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: loggedIn
                              ? const Color(0x3834C759)
                              : Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          loggedIn ? '已授权' : '未登录',
                          style: TextStyle(
                            color: loggedIn
                                ? const Color(0xFF6EE798)
                                : TvAmbientColors.secondaryText,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 20),
        _settingsGlassCard(
          children: [
            const Text(
              '云盘线路优选策略',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                TvFocusPill(
                  selected: widget.storage.preferredQuality == '4k_netdisk',
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  onSelect: () async {
                    await widget.storage.setPreferredQuality('4k_netdisk');
                    if (mounted) setState(() {});
                  },
                  child: const Text('4K 原画网盘优先', style: TextStyle(fontSize: 15.5)),
                ),
                TvFocusPill(
                  selected: widget.storage.preferredQuality == 'auto',
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  onSelect: () async {
                    await widget.storage.setPreferredQuality('auto');
                    if (mounted) setState(() {});
                  },
                  child: const Text('默认直链顺序', style: TextStyle(fontSize: 15.5)),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingsWebdavSection() {
    return _settingsGlassCard(
      children: [
        const Text(
          'WebDAV 云端双向同步（marco-movie-sync v2）',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '与手机、平板、macOS、Windows 及 Apple TV 无缝同步观看进度、收藏与订阅列表',
          style: TextStyle(
            color: TvAmbientColors.secondaryText,
            fontSize: 14.5,
          ),
        ),
        const SizedBox(height: 20),
        TvFocusPill(
          prominent: true,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
          onSelect: () => showCloudSyncSheet(
            context,
            widget.storage,
            onSynced: ({required bool subscriptionsChanged}) {
              if (subscriptionsChanged) {
                _reloadConfigAndFetch();
              } else if (mounted) {
                setState(() {});
              }
            },
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.cloud_upload_fill, size: 17),
              SizedBox(width: 8),
              Text('配置 WebDAV 并立即同步', style: TextStyle(fontSize: 16)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsPlaybackSection() {
    final uiMode = widget.storage.tvUiMode;
    final speed = widget.storage.playSpeed;
    const speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsGlassCard(
          children: [
            const Text(
              '默认播放倍速与硬件解码',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final s in speeds)
                  TvFocusPill(
                    selected: (speed - s).abs() < 0.01,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 11,
                    ),
                    onSelect: () async {
                      await widget.storage.setPlaySpeed(s);
                      if (mounted) setState(() {});
                    },
                    child: Text('${s}x', style: const TextStyle(fontSize: 16)),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        _settingsGlassCard(
          children: [
            const Text(
              '多形态界面切换（HarmonyOS 通用包）',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '默认根据设备类型自动切换手机/平板触控界面与智慧屏 10 英尺遥控界面',
              style: TextStyle(
                color: TvAmbientColors.secondaryText,
                fontSize: 14.5,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                TvFocusPill(
                  selected: uiMode == 'auto',
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  onSelect: () => widget.storage.setTvUiMode('auto'),
                  child: const Text(
                    '自动识别（手机/平板/智慧屏）',
                    style: TextStyle(fontSize: 15.5),
                  ),
                ),
                TvFocusPill(
                  selected: uiMode == 'tv',
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  onSelect: () => widget.storage.setTvUiMode('tv'),
                  child: const Text('强制大屏遥控模式', style: TextStyle(fontSize: 15.5)),
                ),
                TvFocusPill(
                  selected: uiMode == 'standard',
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                  onSelect: () => widget.storage.setTvUiMode('standard'),
                  child: const Text(
                    '标准触控 / 桌面模式',
                    style: TextStyle(fontSize: 15.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingsBackupSection() {
    return _settingsGlassCard(
      children: [
        const Text(
          '跨端备份互通（marco-movie-backup）与缓存',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '当前海报内存缓存：${PosterLoader.memoryCacheSizeLabel}',
          style: const TextStyle(
            color: TvAmbientColors.secondaryText,
            fontSize: 14.5,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            TvFocusPill(
              prominent: true,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              onSelect: _exportBackup,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.share_up, size: 16),
                  SizedBox(width: 8),
                  Text('导出备份文件 / 复制 JSON', style: TextStyle(fontSize: 15.5)),
                ],
              ),
            ),
            TvFocusPill(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              onSelect: () => _importLocalConfigOrBackup(isBackup: true),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.arrow_down_doc_fill, size: 16),
                  SizedBox(width: 8),
                  Text('从本地备份文件恢复', style: TextStyle(fontSize: 15.5)),
                ],
              ),
            ),
            TvFocusPill(
              destructive: true,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              onSelect: () async {
                await PosterLoader.clearCache();
                if (mounted) {
                  setState(() {});
                  _showToast('已清理本地海报缓存');
                }
              },
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.trash, size: 16),
                  SizedBox(width: 8),
                  Text('清理海报缓存', style: TextStyle(fontSize: 15.5)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingsUpdateSection() {
    final release = _latestUpdate;
    final hapUrl = release?.harmonyosUrl?.toString() ?? '';
    final releasePageUrl =
        release?.releaseUrl?.toString() ?? 'https://marcotv.wlj9919.top/movie/';
    final sizeText = release?.size != null
        ? '${(release!.size! / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '';
    final buildSuffix =
        _installedBuildNumber.isNotEmpty ? ' (Build $_installedBuildNumber)' : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsGlassCard(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'HarmonyOS NEXT 独立版本更新',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '当前已装版本：v$_installedVersion$buildSuffix · 支持架构：arm64-v8a',
                        style: const TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 14.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                TvFocusPill(
                  key: const ValueKey('tv-check-update-btn'),
                  prominent: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 12,
                  ),
                  onSelect: _updateChecking ? null : _checkHarmonyUpdate,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_updateChecking)
                        const CupertinoActivityIndicator(radius: 8)
                      else
                        const Icon(CupertinoIcons.arrow_clockwise, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        _updateChecking ? '正在检查…' : '检查版本更新',
                        style: const TextStyle(fontSize: 15.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _updateFailed
                      ? CupertinoIcons.exclamationmark_triangle_fill
                      : _updateHasNewer
                          ? CupertinoIcons.arrow_down_circle_fill
                          : CupertinoIcons.checkmark_seal_fill,
                  size: 20,
                  color: _updateFailed
                      ? AppleColors.systemOrange
                      : _updateHasNewer
                          ? AppleColors.systemBlue
                          : AppleColors.systemGreen,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _updateStatus,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (release != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: TvAmbientColors.glassStroke),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '安装包：${release.packageFileName ?? "MarcoMovie-${release.version}-harmonyos-universal.hap"}'
                      '${sizeText.isNotEmpty ? "（$sizeText）" : ""}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((release.checksum ?? '').isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'SHA-256：${release.checksum}',
                        style: const TextStyle(
                          color: TvAmbientColors.secondaryText,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    if (release.notes.trim().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ReleaseNotesSummaryView(
                        rawNotes: release.notes,
                        fontSize: 13.5,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0x260A84FF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0x660A84FF),
                  ),
                ),
                child: const Text(
                  AppUpdate.harmonyosUnsignedInstallGuide,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (hapUrl.isNotEmpty)
                    TvFocusPill(
                      key: const ValueKey('tv-download-hap-btn'),
                      prominent: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 11,
                      ),
                      onSelect: () => _openOrCopyHarmonyUpdateUrl(
                        hapUrl,
                        '未签名 HAP 下载链接',
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(CupertinoIcons.arrow_down_to_line, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            _updateHasNewer
                                ? '下载未签名 HAP v${release.version}'
                                : '重新下载 HAP v${release.version}',
                            style: const TextStyle(fontSize: 15),
                          ),
                        ],
                      ),
                    ),
                  if (hapUrl.isNotEmpty)
                    TvFocusPill(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 11,
                      ),
                      onSelect: () async {
                        await Clipboard.setData(ClipboardData(text: hapUrl));
                        _showToast('已复制 HAP 下载链接');
                      },
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(CupertinoIcons.doc_on_clipboard, size: 16),
                          SizedBox(width: 8),
                          Text('复制 HAP 链接', style: TextStyle(fontSize: 15)),
                        ],
                      ),
                    ),
                  TvFocusPill(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 11,
                    ),
                    onSelect: () => _openOrCopyHarmonyUpdateUrl(
                      releasePageUrl,
                      '鸿蒙发布页地址',
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(CupertinoIcons.globe, size: 16),
                        SizedBox(width: 8),
                        Text('打开鸿蒙发布页', style: TextStyle(fontSize: 15)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Apple TV-parity floating capsule navigation tab inside the centered frosted dock.
class _TvFloatingNavTab extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool autofocus;
  final VoidCallback onSelect;

  const _TvFloatingNavTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.autofocus,
    required this.onSelect,
  });

  @override
  State<_TvFloatingNavTab> createState() => _TvFloatingNavTabState();
}

class _TvFloatingNavTabState extends State<_TvFloatingNavTab> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _focused || _hovered;
    final fg = active ? TvAmbientColors.darkInk : Colors.white.withValues(alpha: 0.86);
    final bg = widget.selected
        ? const Color(0xECEAECEF)
        : (_focused || _hovered
            ? Colors.white.withValues(alpha: 0.88)
            : Colors.transparent);

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent && isTvActivationKey(event.logicalKey)) {
          widget.onSelect();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 11),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              boxShadow: widget.selected || _focused
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 18,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
