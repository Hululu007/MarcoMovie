// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cms_client.dart';
import '../../core/models.dart';
import '../../core/ohos_runtime.dart';
import '../../core/storage_service.dart';
import '../apple_theme.dart';
import '../cloud_sync_panel.dart';
import '../player_screen.dart';
import 'tv_detail_screen.dart';
import 'tv_focus_widgets.dart';

/// 10-foot living-room UI shell for HarmonyOS Smart Screen (`deviceType == 'tv'`)
/// and optional manual TV Remote Mode across devices.
class TvLivingRoomShell extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;

  const TvLivingRoomShell({
    super.key,
    required this.storage,
    required this.client,
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
  bool _searching = false;
  bool _searchPerformed = false;
  final List<(CmsSite, CmsVideo)> _searchResults = <(CmsSite, CmsVideo)>[];
  int _searchEpoch = 0;

  // Library state (0: 观看历史, 1: 我的收藏)
  int _librarySegment = 0;

  @override
  void initState() {
    super.initState();
    _homeScrollController.addListener(_onHomeScroll);
    _reloadConfigAndFetch();
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
    final sites = (_config?.publicAvailableSites ?? const <CmsSite>[])
        .where((s) => s.searchable)
        .take(16)
        .toList(growable: false);
    final epoch = ++_searchEpoch;
    setState(() {
      _searching = true;
      _searchPerformed = true;
      _searchResults.clear();
    });
    unawaited(widget.storage.addSearchKeyword(kw));
    const concurrency = 4;
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < sites.length && mounted && epoch == _searchEpoch) {
        final site = sites[cursor++];
        try {
          final res = await widget.client.fetchSearch(site, kw);
          if (!mounted || epoch != _searchEpoch) {
            return;
          }
          if (res.videos.isNotEmpty) {
            setState(() {
              for (final v in res.videos) {
                _searchResults.add((site, v));
              }
            });
          }
        } catch (_) {}
      }
    }

    await Future.wait<void>(
      List<Future<void>>.generate(concurrency, (_) => worker()),
    );
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
    final episodes = <CmsEpisode>[];
    for (final ch in group.channels) {
      final eps = ch.episodes;
      if (eps.isNotEmpty) {
        episodes.add(
          CmsEpisode(
            name: ch.name,
            url: eps.first.url,
            headers: eps.first.headers,
            variants: eps.length > 1 ? eps.sublist(1) : const [],
          ),
        );
      }
    }
    if (episodes.isEmpty) {
      return;
    }
    final liveVideo = CmsVideo(
      id: 'live_group_${group.name}',
      title: group.name,
      lines: [CmsLine(name: source.name, episodes: episodes)],
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          site: source.playbackSite,
          video: liveVideo,
          initialLineIndex: 0,
          initialEpisodeIndex: channelIdx.clamp(0, episodes.length - 1),
          storage: widget.storage,
          isLive: true,
        ),
      ),
    );
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
          backgroundColor: const Color(0xFF181A22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
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
        final picked = await OhosRuntime.pickConfigOrBackupFile();
        content = picked?.content;
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['json', 'txt', 'm3u', 'm3u8'],
          withData: true,
        );
        if (result != null && result.files.isNotEmpty) {
          final f = result.files.first;
          if (f.bytes != null) {
            content = utf8.decode(f.bytes!, allowMalformed: true);
          } else if (f.path != null) {
            content = await File(f.path!).readAsString();
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
    const tabs = <(IconData, String)>[
      (CupertinoIcons.play_rectangle_fill, '主页'),
      (CupertinoIcons.dot_radiowaves_left_right, '直播'),
      (CupertinoIcons.search, '搜索'),
      (CupertinoIcons.square_favorites_alt_fill, '片库'),
      (CupertinoIcons.gear_alt_fill, '设置'),
    ];

    return Focus(
      onKeyEvent: _handleRootKey,
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0C12),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Top 10-foot living-room navigation bar
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 20, 36, 12),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.film_fill,
                      color: AppleColors.systemBlue,
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Marco Movie',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(width: 28),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < tabs.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: TvFocusPill(
                                  autofocus: i == 0 && _activeSite == null,
                                  selected: _tabIndex == i,
                                  onSelect: () => setState(() => _tabIndex = i),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        tabs[i].$1,
                                        size: 16,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 7),
                                      Text(
                                        tabs[i].$2,
                                        style: const TextStyle(fontSize: 15),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TvFocusPill(
                      onSelect: _showSitePickerDialog,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            CupertinoIcons.layers_alt_fill,
                            size: 15,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _activeSite?.name ?? '导入 / 切源',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
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
      ),
    );
  }

  Widget _buildHomeView() {
    if (_activeSite == null) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 640),
          padding: const EdgeInsets.all(36),
          decoration: BoxDecoration(
            color: const Color(0xFF151821),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.tv_fill,
                color: AppleColors.systemBlue,
                size: 52,
              ),
              const SizedBox(height: 18),
              const Text(
                '欢迎使用 Marco Movie 大屏版',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '本应用不内置任何影视内容。请使用同一局域网手机扫码一键推送您自行合法获取的配置，或通过地址/本地文件导入。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppleColors.labelSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 26),
              Wrap(
                spacing: 14,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  TvFocusPill(
                    autofocus: true,
                    selected: true,
                    onSelect: _showQrSyncDialog,
                    child: const Text('📱 手机扫码推送配置'),
                  ),
                  TvFocusPill(
                    onSelect: _showUrlImportDialog,
                    child: const Text('🔗 输入地址 / 剪贴板导入'),
                  ),
                  TvFocusPill(
                    onSelect: () => _importLocalConfigOrBackup(isBackup: false),
                    child: const Text('📂 本地文件导入'),
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

    return CustomScrollView(
      controller: _homeScrollController,
      slivers: [
        if (_categories.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 6, 36, 14),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: TvFocusPill(
                        selected: _selectedCategoryId.isEmpty,
                        onSelect: () => _selectCategory(''),
                        child: const Text('精选推荐'),
                      ),
                    ),
                    for (final cat in _categories)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: TvFocusPill(
                          selected: _selectedCategoryId == cat.id,
                          onSelect: () => _selectCategory(cat.id),
                          child: Text(cat.name),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (showContinue)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 4, 36, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '继续观看',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 220,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: history.take(12).length,
                      separatorBuilder: (_, __) => const SizedBox(width: 16),
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
                        return SizedBox(
                          width: 132,
                          child: TvFocusablePosterCard(
                            video: vid,
                            subtitleBadge: item.episode,
                            progressFraction: item.progressFraction,
                            onSelect: () => _openDetail(site, vid),
                          ),
                        );
                      },
                    ),
                  ),
                ],
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
                    style: const TextStyle(color: AppleColors.systemRed),
                  ),
                  const SizedBox(height: 14),
                  TvFocusPill(
                    onSelect: () => _loadSiteHome(_activeSite!),
                    child: const Text('重试加载'),
                  ),
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(36, 8, 36, 36),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 210,
                mainAxisSpacing: 22,
                crossAxisSpacing: 20,
                childAspectRatio: 0.60,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final video = _homeVideos[index];
                  return TvFocusablePosterCard(
                    autofocus: index == 0,
                    video: video,
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
              padding: EdgeInsets.only(bottom: 28),
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
            const Text(
              '当前配置未包含可用的直播列表',
              style: TextStyle(color: AppleColors.labelSecondary, fontSize: 16),
            ),
            const SizedBox(height: 14),
            TvFocusPill(
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
    final channels = _liveGroups.isEmpty
        ? const <LiveChannel>[]
        : _liveGroups[safeGroupIdx].channels;

    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 8, 36, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (lives.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < lives.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: TvFocusPill(
                          selected: i == _selectedLiveSourceIdx,
                          onSelect: () {
                            setState(() => _selectedLiveSourceIdx = i);
                            unawaited(_loadLiveSource(lives[i]));
                          },
                          child: Text(lives[i].name),
                        ),
                      ),
                  ],
                ),
              ),
            ),
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
                              style: const TextStyle(color: AppleColors.systemRed),
                            ),
                            const SizedBox(height: 12),
                            TvFocusPill(
                              onSelect: () => _loadLiveSource(activeSource),
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : Row(
                        children: [
                          SizedBox(
                            width: 240,
                            child: ListView.separated(
                              itemCount: _liveGroups.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, idx) {
                                final g = _liveGroups[idx];
                                return TvFocusPill(
                                  selected: idx == safeGroupIdx,
                                  borderRadius: 12,
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
                                        ),
                                      ),
                                      Text(
                                        '${g.channels.length}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppleColors.labelSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: GridView.builder(
                              itemCount: channels.length,
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 260,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 3.2,
                                  ),
                              itemBuilder: (_, idx) {
                                final ch = channels[idx];
                                return TvFocusPill(
                                  borderRadius: 14,
                                  onSelect: () => _openLiveGroupPlayer(
                                    activeSource,
                                    _liveGroups[safeGroupIdx],
                                    idx,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        CupertinoIcons.tv,
                                        size: 16,
                                        color: Colors.white70,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          ch.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 8, 36, 28),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: TvRemoteGridKeyboard(
                query: _searchQuery,
                history: widget.storage.getSearchHistory(),
                onQueryChanged: (next) => setState(() => _searchQuery = next),
                onSubmit: _runGlobalSearch,
              ),
            ),
          ),
          const SizedBox(width: 28),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _searchPerformed
                          ? '并发检索结果（${_searchResults.length}）'
                          : '跨站点全局搜索',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_searching) ...[
                      const SizedBox(width: 12),
                      const CupertinoActivityIndicator(radius: 10),
                    ],
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: !_searchPerformed
                      ? const Center(
                          child: Text(
                            '使用左侧遥控网格键盘输入首拼或片名关键词，并发检索全部可用片源',
                            style: TextStyle(color: AppleColors.labelSecondary),
                          ),
                        )
                      : (_searchResults.isEmpty && !_searching)
                          ? const Center(
                              child: Text(
                                '未找到匹配结果，请尝试更换首拼或简短关键词',
                                style: TextStyle(
                                  color: AppleColors.labelSecondary,
                                ),
                              ),
                            )
                          : GridView.builder(
                              itemCount: _searchResults.length,
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 195,
                                    mainAxisSpacing: 18,
                                    crossAxisSpacing: 16,
                                    childAspectRatio: 0.58,
                                  ),
                              itemBuilder: (_, idx) {
                                final (site, video) = _searchResults[idx];
                                return TvFocusablePosterCard(
                                  video: video,
                                  subtitleBadge: site.name,
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

    CmsSite resolveSite(String siteKey) {
      for (final s in availableSites) {
        if (s.key == siteKey) {
          return s;
        }
      }
      return _activeSite ??
          CmsSite(key: siteKey, name: siteKey, type: 1, api: '');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 8, 36, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TvFocusPill(
                selected: _librarySegment == 0,
                onSelect: () => setState(() => _librarySegment = 0),
                child: Text('观看历史 (${history.length})'),
              ),
              const SizedBox(width: 12),
              TvFocusPill(
                selected: _librarySegment == 1,
                onSelect: () => setState(() => _librarySegment = 1),
                child: Text('我的收藏 (${favorites.length})'),
              ),
              const Spacer(),
              if (_librarySegment == 0 && history.isNotEmpty)
                TvFocusPill(
                  onSelect: () async {
                    await widget.storage.clearWatchHistory();
                    if (mounted) {
                      setState(() {});
                    }
                  },
                  child: const Text('清空历史'),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: _librarySegment == 0
                ? (history.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无观看记录',
                          style: TextStyle(color: AppleColors.labelSecondary),
                        ),
                      )
                    : GridView.builder(
                        itemCount: history.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 205,
                              mainAxisSpacing: 20,
                              crossAxisSpacing: 18,
                              childAspectRatio: 0.60,
                            ),
                        itemBuilder: (_, idx) {
                          final h = history[idx];
                          final vid = CmsVideo(
                            id: h.id,
                            title: h.title,
                            poster: h.poster,
                            remarks: h.episode,
                          );
                          return TvFocusablePosterCard(
                            video: vid,
                            subtitleBadge: h.episode,
                            progressFraction: h.progressFraction,
                            onSelect: () =>
                                _openDetail(resolveSite(h.site), vid),
                          );
                        },
                      ))
                : (favorites.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无收藏内容',
                          style: TextStyle(color: AppleColors.labelSecondary),
                        ),
                      )
                    : GridView.builder(
                        itemCount: favorites.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 205,
                              mainAxisSpacing: 20,
                              crossAxisSpacing: 18,
                              childAspectRatio: 0.60,
                            ),
                        itemBuilder: (_, idx) {
                          final fav = favorites[idx];
                          final vid = CmsVideo(
                            id: fav.id,
                            title: fav.title,
                            poster: fav.poster,
                            remarks: fav.remarks,
                          );
                          return TvFocusablePosterCard(
                            video: vid,
                            subtitleBadge: fav.remarks,
                            onSelect: () =>
                                _openDetail(resolveSite(fav.site), vid),
                          );
                        },
                      )),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsView() {
    final uiMode = widget.storage.tvUiMode;
    final speed = widget.storage.playSpeed;
    const speeds = <double>[1.0, 1.25, 1.5, 2.0];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(36, 12, 36, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '配置导入与多端同步',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              TvFocusPill(
                selected: true,
                onSelect: _showQrSyncDialog,
                child: const Text('📱 手机扫码推送配置 / 局域网同步'),
              ),
              TvFocusPill(
                onSelect: _showUrlImportDialog,
                child: const Text('🔗 输入地址 / 剪贴板导入'),
              ),
              TvFocusPill(
                onSelect: () => _importLocalConfigOrBackup(isBackup: false),
                child: const Text('📂 选择本地配置文件'),
              ),
              TvFocusPill(
                onSelect: _showSitePickerDialog,
                child: const Text('🗂️ 管理订阅源与切换仓库'),
              ),
              TvFocusPill(
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
                child: const Text('☁️ WebDAV 云端同步设置'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Text(
            '跨端备份互通（marco-movie-backup）',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              TvFocusPill(
                onSelect: _exportBackup,
                child: const Text('📤 导出备份文件 / 复制 JSON'),
              ),
              TvFocusPill(
                onSelect: () => _importLocalConfigOrBackup(isBackup: true),
                child: const Text('📥 从本地备份文件恢复'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Text(
            '播放与界面模式',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '默认倍速：',
                style: TextStyle(color: AppleColors.labelSecondary),
              ),
              for (final s in speeds)
                TvFocusPill(
                  selected: (speed - s).abs() < 0.01,
                  onSelect: () async {
                    await widget.storage.setPlaySpeed(s);
                    if (mounted) {
                      setState(() {});
                    }
                  },
                  child: Text('${s}x'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '界面形态：',
                style: TextStyle(color: AppleColors.labelSecondary),
              ),
              TvFocusPill(
                selected: uiMode == 'auto',
                onSelect: () => widget.storage.setTvUiMode('auto'),
                child: const Text('自动识别（手机/平板/智慧屏）'),
              ),
              TvFocusPill(
                selected: uiMode == 'tv',
                onSelect: () => widget.storage.setTvUiMode('tv'),
                child: const Text('强制大屏遥控模式'),
              ),
              TvFocusPill(
                selected: uiMode == 'standard',
                onSelect: () => widget.storage.setTvUiMode('standard'),
                child: const Text('标准触控 / 桌面模式'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
