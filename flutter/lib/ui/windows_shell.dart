part of 'adaptive_shell.dart';

extension _WindowsShell on _AdaptiveShellState {
  void _windowsNavigate(String page) {
    _updateWindowsState(() => _windowsPage = page);
    if (page == 'live' &&
        _liveGroups.isEmpty &&
        !_liveLoading &&
        _visibleLives.isNotEmpty) {
      _loadLivePlaylist(_selectedLiveSource.clamp(0, _visibleLives.length - 1));
    }
  }

  Widget _buildWindowsShell(BuildContext context) {
    final appearance = WindowsAppearanceScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final pad = width > 1100 ? 32.0 : 22.0;
    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _showGlobalSearchSheet,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _showGlobalSearchSheet,
        },
        child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: WindowsBackdrop(
                  child: SafeArea(
                      bottom: false,
                      child: Column(children: [
                        Padding(
                            padding: EdgeInsets.fromLTRB(pad, 10, pad, 14),
                            child: Row(children: [
                              GestureDetector(
                                  key: const ValueKey('home-brand-logo'),
                                  onTap: _handleHomeLogoTap,
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Image.asset('assets/logo_mark.png',
                                            width: 36, height: 36),
                                        if (width > 870) ...[
                                          const SizedBox(width: 9),
                                          Text('MarcoMovie',
                                              style: TextStyle(
                                                  color: winInk(context),
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.w600))
                                        ]
                                      ])),
                              const Spacer(),
                              WinPanel(
                                  radius: 32,
                                  padding: const EdgeInsets.all(5),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        for (final item in [
                                          ('home', '首页'),
                                          ('discover', '发现'),
                                          ('live', '直播'),
                                          ('library', '我的')
                                        ])
                                          WinButton(item.$2,
                                              selected: _windowsPage == item.$1,
                                              onPressed: () =>
                                                  _windowsNavigate(item.$1)),
                                      ])),
                              const Spacer(),
                              IconButton(
                                  tooltip: '搜索影片 · Ctrl+K',
                                  icon: Icon(CupertinoIcons.search,
                                      color: winInk(context), size: 21),
                                  onPressed: _showGlobalSearchSheet),
                              const SizedBox(width: 7),
                              IconButton(
                                  tooltip: '背景与外观 · ${appearance.label}',
                                  icon: Icon(CupertinoIcons.paintbrush,
                                      color: winInk(context), size: 20),
                                  onPressed: () => _updateWindowsState(() {
                                        _windowsSettings = '背景与外观';
                                        _windowsPage = 'settings';
                                      })),
                              IconButton(
                                  tooltip: '设置',
                                  icon: Icon(CupertinoIcons.gear_alt,
                                      color: winInk(context), size: 21),
                                  onPressed: () =>
                                      _windowsNavigate('settings')),
                            ])),
                        if (_privateSessionUnlocked)
                          Padding(
                              padding: EdgeInsets.symmetric(horizontal: pad),
                              child: Row(children: [
                                Icon(CupertinoIcons.lock_shield,
                                    color: winMuted(context), size: 17),
                                const SizedBox(width: 8),
                                Text('隐私空间',
                                    style: TextStyle(color: winMuted(context))),
                                const Spacer(),
                                WinButton('退出隐私空间',
                                    onPressed: _exitPrivacySpace)
                              ])),
                        Expanded(
                            child: switch (_windowsPage) {
                          'discover' => _windowsDiscover(pad),
                          'live' => _windowsLive(pad),
                          'search' => _windowsSearch(pad),
                          'library' => _windowsLibrary(pad),
                          'settings' => _windowsSettingsPage(pad),
                          _ => _windowsHome(pad),
                        }),
                      ]))),
            )));
  }

  Widget _windowsHeading(String title, {List<Widget> actions = const []}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: LayoutBuilder(
            builder: (context, constraints) => Row(children: [
                  Expanded(
                      child: Text(title,
                          style: TextStyle(
                              color: winInk(context),
                              fontSize: 30,
                              fontWeight: FontWeight.w600))),
                  ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: constraints.maxWidth * .58),
                      child:
                          Wrap(alignment: WrapAlignment.end, children: actions))
                ])),
      );

  Widget _windowsEmpty(String title, String explanation,
          {VoidCallback? action, String button = '添加内容来源'}) =>
      Center(
          child: SingleChildScrollView(
              child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 630),
            child: WinPanel(
                padding: const EdgeInsets.all(36),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              color: winInk(context),
                              fontSize: 29,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 18),
                      Text(explanation,
                          style:
                              TextStyle(color: winMuted(context), height: 1.8)),
                      if (action != null) ...[
                        const SizedBox(height: 25),
                        WinButton(button, selected: true, onPressed: action)
                      ],
                    ]))),
      )));

  Widget _windowsHome(double pad) {
    if (_homeError != null && _windowsRecommendedVideos.isEmpty)
      return _windowsHomeError();
    if (_config == null && !_privateSessionUnlocked) return _windowsWelcome();
    if (_homeLoading && _windowsRecommendedVideos.isEmpty)
      return const Center(child: CircularProgressIndicator());
    if (_windowsRecommendedVideos.isEmpty)
      return _windowsEmpty(
        _homeError == null ? '从一部影片开始' : '暂时无法加载影片',
        _homeError ?? '选择内容来源，或搜索想看的影片。',
        action: _homeError == null
            ? _showSitePickerDialog
            : _refreshCurrentHomeView,
        button: _homeError == null ? '选择片源' : '重新加载',
      );
    final history =
        _privateSessionUnlocked || !widget.storage.showContinueWatching
            ? <WatchHistoryEntry>[]
            : _cachedWatchHistory.take(3).toList();
    final showHero = widget.storage.showHeroBanner;
    return LayoutBuilder(builder: (context, box) {
      final sideHistory =
          box.maxWidth >= 1100 && showHero && history.isNotEmpty;
      return ListView(padding: EdgeInsets.fromLTRB(pad, 0, pad, 24), children: [
        if (showHero)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                flex: 7, child: _windowsHero(_windowsRecommendedVideos.first)),
            if (sideHistory) ...[
              const SizedBox(width: 20),
              Expanded(flex: 3, child: _windowsContinueWatching(history)),
            ],
          ]),
        if (history.isNotEmpty && !sideHistory) ...[
          if (showHero) const SizedBox(height: 18),
          _windowsContinueWatching(history),
        ],
        if (showHero || history.isNotEmpty) const SizedBox(height: 20),
        Row(children: [
          Expanded(
              child: Text('为你呈现',
                  style: TextStyle(
                      color: winInk(context),
                      fontSize: 21,
                      fontWeight: FontWeight.w600))),
          WinButton('浏览全部',
              icon: CupertinoIcons.chevron_right,
              onPressed: () => _windowsNavigate('discover')),
        ]),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, grid) {
          final targetWidth = switch (widget.storage.gridDensity) {
            'comfortable' => 210.0,
            'compact' => 135.0,
            _ => 170.0,
          };
          final columns = (grid.maxWidth / targetWidth).floor().clamp(3, 12);
          return Wrap(spacing: 18, runSpacing: 20, children: [
            for (final video in _windowsRecommendedVideos)
              SizedBox(
                  width: (grid.maxWidth - (columns - 1) * 18) / columns,
                  child: _windowsVideoCard(video, _activeSite!)),
          ]);
        }),
      ]);
    });
  }

  Widget _windowsContinueWatching(List<WatchHistoryEntry> history) => WinPanel(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        radius: 24,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('最近在看',
                    style: TextStyle(
                        color: winInk(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w600))),
            WinButton('记录',
                onPressed: () => _updateWindowsState(() {
                      _windowsPage = 'library';
                      _librarySegment = 1;
                    })),
          ]),
          for (final entry in history)
            Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _openSyncedMediaEntry(
                      siteKey: entry.site,
                      videoId: entry.id,
                      title: entry.title,
                      poster: _resolveHistoryPoster(entry)),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(children: [
                        ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                                width: 70,
                                height: 48,
                                child: PosterImage(
                                    url: _resolveHistoryPoster(entry),
                                    title: entry.title,
                                    placeholder: ColoredBox(
                                        color: winMuted(context)
                                            .withValues(alpha: .1))))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: winInk(context),
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                              const SizedBox(height: 4),
                              Text(entry.episode,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: winMuted(context), fontSize: 11)),
                            ])),
                        const SizedBox(width: 8),
                        Icon(CupertinoIcons.play_circle,
                            size: 24, color: winMuted(context)),
                      ])),
                )),
        ]),
      );

  Widget _windowsHomeError() => Center(
          child: WinPanel(
              child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_homeError ?? '加载失败', style: TextStyle(color: winInk(context))),
          const SizedBox(height: 16),
          Wrap(spacing: 10, children: [
            WinButton('重试', onPressed: _retryHomeError ?? _loadSiteHome),
            if (_activeSite != null &&
                CmsClient.needsSourceVerification(
                    _activeSite!, _homeErrorCause))
              SourceVerificationButton(
                  client: widget.client,
                  site: _activeSite!,
                  onVerified: _retryHomeError ?? _loadSiteHome),
            WinButton('切换片源', onPressed: _showSitePickerDialog),
          ]),
        ],
      )));

  Widget _windowsHero(CmsVideo video) {
    final compact = MediaQuery.sizeOf(context).width < 900;
    return SizedBox(
        height: compact ? 254 : 280,
        child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Stack(fit: StackFit.expand, children: [
              PosterImage(
                  url: video.poster,
                  title: _privateSessionUnlocked ? '' : video.title,
                  year: video.year,
                  highRes: true,
                  forBackdrop: true,
                  placeholder: const ColoredBox(color: Color(0xFF29485C))),
              const DecoratedBox(
                  decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                Color(0xDF10263D),
                Color(0x80203C52),
                Color(0x10203C52)
              ], stops: [
                0,
                .47,
                1
              ]))),
              Padding(
                  padding: EdgeInsets.all(compact ? 24 : 28),
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                          width: compact ? 410 : 560,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(_activeSite?.name ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12)),
                                const SizedBox(height: 10),
                                Text(video.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: compact ? 28 : 32,
                                        height: 1.25,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 10),
                                Text(
                                    [video.year, video.area, video.remarks]
                                        .where((s) => s.isNotEmpty)
                                        .join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 13)),
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: Colors.white,
                                        foregroundColor:
                                            const Color(0xFF253B51),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 20, vertical: 12)),
                                    onPressed: () =>
                                        _openVideoDetail(_activeSite!, video),
                                    icon: const Icon(CupertinoIcons.play_fill,
                                        size: 16),
                                    label: const Text('影片详情')),
                              ])))),
            ])));
  }

  Widget _windowsVideoCard(CmsVideo video, CmsSite site,
          {bool landscape = false}) =>
      InkWell(
        onTap: () => _openVideoDetail(site, video),
        borderRadius: BorderRadius.circular(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
              aspectRatio: landscape ? 16 / 9 : 2 / 3,
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: PosterImage(
                      url: video.poster,
                      title: _privateSessionUnlocked ? '' : video.title,
                      year: video.year,
                      placeholder: ColoredBox(
                          color: Colors.white.withValues(alpha: .13),
                          child: Center(
                              child: Icon(CupertinoIcons.film,
                                  color: winMuted(context), size: 35)))))),
          const SizedBox(height: 13),
          Text(video.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: winInk(context),
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
          const SizedBox(height: 5),
          if (widget.storage.cardSubtitleMode != 'none')
            Text(
                switch (widget.storage.cardSubtitleMode) {
                  'site' => site.name,
                  'year_area' => [video.year, video.area, video.tag]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  _ => video.remarks.isEmpty ? site.name : video.remarks,
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: winMuted(context), fontSize: 11)),
        ]),
      );

  Widget _windowsHistoryCard(WatchHistoryEntry entry) => InkWell(
      onTap: () => _openSyncedMediaEntry(
          siteKey: entry.site,
          videoId: entry.id,
          title: entry.title,
          poster: _resolveHistoryPoster(entry)),
      borderRadius: BorderRadius.circular(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(fit: StackFit.expand, children: [
                  PosterImage(
                      url: _resolveHistoryPoster(entry),
                      title: entry.title,
                      placeholder: ColoredBox(
                          color: Colors.white.withValues(alpha: .12))),
                  const Positioned(
                      right: 14,
                      bottom: 14,
                      child: CircleAvatar(
                          radius: 16,
                          backgroundColor: Color(0xDDEDF3FA),
                          child: Icon(CupertinoIcons.play_fill,
                              size: 13, color: Color(0xFF2B455F))))
                ]))),
        const SizedBox(height: 12),
        Text(entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(color: winInk(context), fontWeight: FontWeight.w600)),
        const SizedBox(height: 5),
        Text(
            '${entry.episode} · 已看 ${Duration(milliseconds: entry.position).inMinutes} 分钟',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: winMuted(context), fontSize: 11)),
        const SizedBox(height: 10),
        ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
                value: entry.progressFraction,
                minHeight: 3,
                color: const Color(0xFF6484AC),
                backgroundColor: Colors.white24)),
      ]));

  Widget _windowsDiscover(double pad) =>
      ListView(padding: EdgeInsets.fromLTRB(pad, 8, pad, 30), children: [
        _windowsHeading('发现', actions: [
          Tooltip(
              message: _activeSite?.name ?? '选择片源',
              child: WinButton(_activeSite?.name ?? '选择片源',
                  onPressed: _showSitePickerDialog,
                  icon: CupertinoIcons.chevron_down)),
          if ((_config?.depots ?? []).isNotEmpty)
            WinButton('切换仓库', onPressed: _showDepotPickerDialog)
        ]),
        Wrap(spacing: 7, runSpacing: 8, children: [
          for (final item in [
            ('recommend', '全部'),
            ('movie', '电影'),
            ('series', '剧集'),
            ('variety', '综艺'),
            ('anime', '动漫')
          ])
            WinButton(item.$2,
                selected: _primaryTab == item.$1,
                onPressed: () => _selectPrimaryTab(item.$1)),
          WinButton('筛选',
              icon: CupertinoIcons.slider_horizontal_3,
              onPressed: () => _updateWindowsState(
                  () => _filterExpanded = !_filterExpanded)),
          WinButton('刷新',
              icon: CupertinoIcons.refresh, onPressed: _refreshCurrentHomeView)
        ]),
        if (_filterExpanded)
          Padding(
              padding: const EdgeInsets.only(top: 18),
              child: WinPanel(dark: true, child: _buildHomeFilterDrawer())),
        const SizedBox(height: 28),
        if (_homeLoading)
          const Padding(
              padding: EdgeInsets.all(35),
              child: Center(child: CircularProgressIndicator())),
        if (_homeError != null) _windowsHomeError(),
        if (_activeSite != null)
          LayoutBuilder(builder: (_, box) {
            final extent = switch (widget.storage.gridDensity) {
              'compact' => 150.0,
              'comfortable' => 245.0,
              _ => 195.0
            };
            final count = (box.maxWidth / extent).floor().clamp(2, 9);
            return Wrap(spacing: 23, runSpacing: 28, children: [
              for (final video in _homeVideos)
                SizedBox(
                    width: (box.maxWidth - (count - 1) * 23) / count,
                    child: _windowsVideoCard(video, _activeSite!))
            ]);
          }),
        if (!_homeLoading &&
            _homeError == null &&
            _homeVideos.isEmpty &&
            _config != null)
          _windowsEmpty('没有符合筛选条件的影片', '试试其他分类或清除筛选。', button: '清除筛选',
              action: () {
            _updateWindowsState(() {
              _primaryTab = 'recommend';
              _filterSubCategoryId = '';
              _filterGenreLabel = '';
              _filterArea = '';
              _filterYear = '';
              _filterExpanded = false;
            });
            _reloadFilteredListing(page: 1);
          }),
        if (_currentPage < _pageCount)
          Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(
                  child: WinButton(_loadingMore ? '正在加载…' : '加载更多',
                      selected: true,
                      onPressed: _loadingMore
                          ? null
                          : () =>
                              _reloadFilteredListing(page: _currentPage + 1)))),
        if (_loadMoreError != null)
          Text(_loadMoreError!, style: TextStyle(color: winMuted(context))),
        if (_config == null) _windowsWelcome(),
      ]);

  Widget _windowsLibrary(double pad) {
    final segment =
        _privateSessionUnlocked && _librarySegment == 2 ? 0 : _librarySegment;
    final history =
        _privateSessionUnlocked ? <WatchHistoryEntry>[] : _cachedWatchHistory;
    final favorites =
        widget.storage.getFavorites(forPrivate: _privateSessionUnlocked);
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _windowsHeading('我的', actions: [
            if (!_privateSessionUnlocked)
              WinButton('多端同步',
                  icon: CupertinoIcons.cloud, onPressed: _openCloudSyncCenter)
          ]),
          Wrap(spacing: 7, children: [
            for (final entry in [
              (1, '继续观看'),
              (0, '收藏'),
              if (!_privateSessionUnlocked) (2, '下载')
            ])
              WinButton(entry.$2,
                  selected: segment == entry.$1,
                  onPressed: () =>
                      _updateWindowsState(() => _librarySegment = entry.$1)),
            if (segment == 1 && history.isNotEmpty)
              WinButton('管理记录', onPressed: _showWatchHistorySheet),
            if (segment == 2 && DownloadService.instance.canOpenFolder)
              WinButton('打开文件夹',
                  onPressed: DownloadService.instance.openFolder),
          ]),
          const SizedBox(height: 26),
          Expanded(
              child: segment == 2
                  ? _windowsDownloads()
                  : LayoutBuilder(builder: (_, box) {
                      final count = (box.maxWidth / 330).floor().clamp(2, 5);
                      final cards = segment == 1
                          ? [
                              for (final item in history)
                                _windowsHistoryCard(item)
                            ]
                          : [
                              for (final f in favorites)
                                InkWell(
                                    onTap: () => _openSyncedMediaEntry(
                                        siteKey: f.site,
                                        videoId: f.id,
                                        title: f.title,
                                        poster: f.poster),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          AspectRatio(
                                              aspectRatio: 16 / 9,
                                              child: ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                  child: PosterImage(
                                                      url: f.poster,
                                                      title:
                                                          _privateSessionUnlocked
                                                              ? ''
                                                              : f.title,
                                                      placeholder:
                                                          const SizedBox
                                                              .shrink()))),
                                          const SizedBox(height: 13),
                                          Text(f.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                  color: winInk(context),
                                                  fontWeight: FontWeight.w600)),
                                          Align(
                                              alignment: Alignment.centerRight,
                                              child: IconButton(
                                                  tooltip: '取消收藏',
                                                  icon: Icon(
                                                      CupertinoIcons.heart_fill,
                                                      color: winMuted(context),
                                                      size: 17),
                                                  onPressed: () async {
                                                    await widget.storage
                                                        .toggleFavorite(
                                                            CmsSite(
                                                                key: f.site,
                                                                name: '',
                                                                type: 0,
                                                                api: '',
                                                                isPrivate:
                                                                    _privateSessionUnlocked),
                                                            CmsVideo(
                                                                id: f.id,
                                                                title: f.title,
                                                                poster:
                                                                    f.poster));
                                                    if (mounted)
                                                      _updateWindowsState(
                                                          () {});
                                                  }))
                                        ]))
                            ];
                      if (cards.isEmpty)
                        return _windowsEmpty(
                            segment == 1 ? '还没有观看记录' : '收藏喜欢的影片',
                            '找到一部喜欢的影片，开始观看或加入收藏。',
                            action: () => _windowsNavigate('discover'),
                            button: '去发现');
                      return SingleChildScrollView(
                          child: Wrap(spacing: 24, runSpacing: 25, children: [
                        for (final card in cards)
                          SizedBox(
                              width: (box.maxWidth - (count - 1) * 24) / count,
                              child: card)
                      ]));
                    })),
        ]));
  }

  Widget _windowsDownloads() => AnimatedBuilder(
      animation: DownloadService.instance,
      builder: (context, _) {
        final service = DownloadService.instance;
        if (!service.isReady)
          return _windowsEmpty('下载暂时不可用', '无法打开下载目录，请检查磁盘权限后重新启动应用。');
        if (service.tasks.isEmpty)
          return _windowsEmpty('还没有下载任务', '在影片详情中选择下载，完成后就可以离线观看。');
        final active = service.activeCount;
        final hasPaused =
            service.tasks.any((t) => t.status == DownloadStatus.paused);
        return Column(children: [
          if (active > 0 || hasPaused)
            Row(children: [
              Expanded(
                  child: Text(active > 0 ? '$active 个任务进行中' : '下载已暂停',
                      style: TextStyle(color: winMuted(context)))),
              WinButton(active > 0 ? '全部暂停' : '全部继续',
                  onPressed: active > 0 ? service.pauseAll : service.resumeAll),
            ]),
          Expanded(
              child: ListView.separated(
                  itemCount: service.tasks.length,
                  separatorBuilder: (_, __) => Divider(
                      color: winMuted(context).withValues(alpha: .13),
                      height: 32),
                  itemBuilder: (context, i) {
                    final t = service.tasks[i];
                    final done = t.status == DownloadStatus.completed;
                    final resume = t.status == DownloadStatus.paused ||
                        t.status == DownloadStatus.failed;
                    return Row(children: [
                      ClipRRect(
                          borderRadius: BorderRadius.circular(15),
                          child: SizedBox(
                              width: 140,
                              height: 85,
                              child: PosterImage(
                                  url: t.poster,
                                  title: t.title,
                                  placeholder: const SizedBox.shrink()))),
                      const SizedBox(width: 24),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: winInk(context),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 7),
                            Text(
                                '${t.episodeName} · ${DownloadService.statusLabel(t)}',
                                style: TextStyle(
                                    color: winMuted(context), fontSize: 12)),
                            const SizedBox(height: 16),
                            LinearProgressIndicator(
                                value: t.progress.clamp(0, 1), minHeight: 3)
                          ])),
                      const SizedBox(width: 20),
                      WinButton(
                          done
                              ? '播放'
                              : resume
                                  ? '继续'
                                  : '暂停',
                          onPressed: done
                              ? () => _playDownloaded(t)
                              : resume
                                  ? () => service.resume(t.id)
                                  : () => service.pause(t.id)),
                      IconButton(
                          tooltip: '删除下载',
                          onPressed: () => _confirmDeleteDownload(t),
                          icon: Icon(CupertinoIcons.trash,
                              size: 18, color: winMuted(context)))
                    ]);
                  })),
          if (service.rootPath.isNotEmpty)
            Text('保存位置：${service.rootPath}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: winMuted(context))),
        ]);
      });

  void _windowsPlayChannel(LiveChannel channel, [int line = 0]) {
    if (channel.urls.isEmpty) return;
    _updateWindowsState(() {
      _windowsLiveChannel = channel;
      _windowsLiveLine = line;
      _windowsLiveRevision++;
    });
  }

  Widget _windowsLive(double pad) {
    final sources = _visibleLives;
    if (sources.isEmpty)
      return _windowsEmpty('添加你的直播频道', '导入直播来源后，可以在这里浏览频道、切换线路。',
          action: _showImportConfigDialog);
    final query = _liveSearchQuery.trim().toLowerCase();
    final channels = <LiveChannel>[
      for (var i = 0; i < _liveGroups.length; i++)
        if (query.isNotEmpty ||
            _selectedLiveGroup < 0 ||
            i == _selectedLiveGroup)
          for (final channel in _liveGroups[i].channels)
            if (query.isEmpty ||
                channel.name.toLowerCase().contains(query) ||
                _liveGroups[i].name.toLowerCase().contains(query))
              channel,
    ];
    final selected = _windowsLiveChannel;
    final player = ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: ColoredBox(
            color: const Color(0xFF172638),
            child: selected == null
                ? const Center(
                    child: Text('选择右侧频道，开始观看',
                        style: TextStyle(color: Colors.white70)))
                : LayoutBuilder(
                    builder: (context, box) => MediaQuery(
                        data: MediaQuery.of(context).copyWith(
                            size: box.biggest, padding: EdgeInsets.zero),
                        child: PlayerScreen(
                            key: ValueKey('live-$_windowsLiveRevision'),
                            site: sources[_selectedLiveSource.clamp(
                                    0, sources.length - 1)]
                                .playbackSite,
                            video: CmsVideo(
                                id: selected.name,
                                title: selected.name,
                                lines: [
                                  CmsLine(
                                      name: selected.group,
                                      episodes: selected.episodes)
                                ]),
                            initialLineIndex: 0,
                            initialEpisodeIndex: _windowsLiveLine,
                            storage: widget.storage,
                            isLive: true,
                            embedded: true,
                            onEmbeddedClose: () => _updateWindowsState(
                                () => _windowsLiveChannel = null),
                            onEmbeddedExpand: () {
                              _updateWindowsState(
                                  () => _windowsLiveChannel = null);
                              _openLiveChannelStream(
                                  sources, selected, _windowsLiveLine);
                            })))));
    final list = WinPanel(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          TextField(
              controller: _liveSearchController,
              style: TextStyle(color: winInk(context)),
              decoration: const InputDecoration(
                  hintText: '搜索全部频道', prefixIcon: Icon(CupertinoIcons.search)),
              onChanged: (v) {
                if (_liveSearchController.value.isComposingRangeValid) return;
                _updateWindowsState(() => _liveSearchQuery = v);
              },
              onSubmitted: (v) =>
                  _updateWindowsState(() => _liveSearchQuery = v)),
          const SizedBox(height: 12),
          if (_liveLoading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
              child: channels.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_liveError ?? (_liveLoading ? '正在加载频道…' : '没有匹配频道'),
                          style: TextStyle(color: winMuted(context))),
                      WinButton(_liveError == null ? '清除搜索' : '重新加载',
                          onPressed: () {
                        if (_liveError != null) {
                          _loadLivePlaylist(_selectedLiveSource);
                        } else {
                          _updateWindowsState(() {
                            _liveSearchController.clear();
                            _liveSearchQuery = '';
                            _selectedLiveGroup = -1;
                          });
                        }
                      }),
                    ]))
                  : ListView.builder(
                      key: const PageStorageKey('windows-live-channels'),
                      itemCount: channels.length,
                      itemBuilder: (_, i) {
                        final ch = channels[i];
                        return ListTile(
                            selected: ch == selected,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                            title: Text(ch.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: winInk(context))),
                            subtitle: Text(
                                '${ch.group} · ${ch.urls.length} 条线路',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: winMuted(context))),
                            onTap: () => _windowsPlayChannel(ch),
                            trailing: ch.urls.length <= 1
                                ? null
                                : PopupMenuButton<int>(
                                    tooltip: '选择线路',
                                    onSelected: (line) =>
                                        _windowsPlayChannel(ch, line),
                                    itemBuilder: (_) => [
                                          for (var line = 0;
                                              line < ch.urls.length;
                                              line++)
                                            PopupMenuItem(
                                                value: line,
                                                child: Text('线路 ${line + 1}'))
                                        ]));
                      })),
        ]));
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 20),
        child: Column(children: [
          _windowsHeading('直播', actions: [
            WinButton('管理来源', onPressed: _showSubscriptionManagerSheet)
          ]),
          SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (int i = 0; i < sources.length; i++)
                  SizedBox(
                      width: 180,
                      child: WinButton(sources[i].name,
                          selected: i == _selectedLiveSource,
                          onPressed: () => _loadLivePlaylist(i))),
              ])),
          SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                WinButton('全部',
                    selected: _selectedLiveGroup < 0,
                    onPressed: () =>
                        _updateWindowsState(() => _selectedLiveGroup = -1)),
                for (int i = 0; i < _liveGroups.length; i++)
                  WinButton(_liveGroups[i].name,
                      selected: _selectedLiveGroup == i,
                      onPressed: () =>
                          _updateWindowsState(() => _selectedLiveGroup = i)),
              ])),
          const SizedBox(height: 14),
          Expanded(
              child: LayoutBuilder(
                  builder: (_, box) => box.maxWidth >= 900
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                              Expanded(child: player),
                              const SizedBox(width: 22),
                              SizedBox(width: 300, child: list)
                            ])
                      : SingleChildScrollView(
                          child: Column(children: [
                          SizedBox(
                              height: (box.maxWidth * 9 / 16).clamp(180, 340),
                              child: player),
                          const SizedBox(height: 12),
                          SizedBox(height: 360, child: list)
                        ])))),
        ]));
  }

  Widget _windowsSettingsPage(double pad) {
    const tabs = ['背景与外观', '首页与排版', '播放', '内容来源', '账号', '同步与备份', '更多设置'];
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _windowsHeading('设置', actions: [
            WinButton('检查更新',
                icon: CupertinoIcons.arrow_down_circle,
                onPressed: _showUpdateCheckSheet)
          ]),
          Expanded(
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 160,
                child: ListView(children: [
                  for (final label in tabs)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: WinButton(label,
                            selected: label == _windowsSettings,
                            onPressed: () => _updateWindowsState(
                                () => _windowsSettings = label)))
                ])),
            const SizedBox(width: 30),
            Expanded(
                child: SingleChildScrollView(child: WindowsSettingsRegion(child: _windowsSettingsContent()))),
          ])),
        ]));
  }

  Widget _windowsSettingsContent() {
    if (_windowsSettings == '背景与外观') return const WindowsAppearanceSettings();
    if (_windowsSettings == '首页与排版')
      return _buildLayoutSettingsSection(
          context, () => _updateWindowsState(() {}));
    if (_windowsSettings == '播放')
      return _buildPlaybackSettingsSection(
          context, () => _updateWindowsState(() {}));
    if (_windowsSettings == '更多设置')
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildAppearanceSettingsSection(
            context, () => _updateWindowsState(() {})),
        const SizedBox(height: 22),
        _buildCloudAndDataSettingsSection(
            context, () => _updateWindowsState(() {})),
        const SizedBox(height: 22),
        WinSettingsGroup(header: '版本与诊断', children: [
          WinSettingsRow(
              title: '软件更新与版本',
              value: 'v$_currentAppVersion',
              icon: CupertinoIcons.arrow_down_circle,
              onTap: _showUpdateCheckSheet),
          WinSettingsRow(
              title: '导出诊断日志包',
              subtitle: '导出脱敏环境信息与最近的运行日志',
              icon: CupertinoIcons.doc_plaintext,
              onTap: () => _exportDiagnosticsBundle(context)),
          if (!OhosRuntime.isOhos)
            WinSettingsRow(
                title: '重新查看新手引导',
                subtitle: '回顾配置导入、多端同步与桌面快捷键指南',
                icon: CupertinoIcons.sparkles,
                onTap: () => _openOnboardingRoute(isReplay: true)),
        ]),
      ]);
    if (_windowsSettings == '内容来源')
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _windowsHeading('内容来源'),
        _windowsSettingRow(
            '订阅管理', '导入、切换、排序与移除订阅', _showSubscriptionManagerSheet),
        _windowsSettingRow('片源管理', '管理各个来源的启用状态与显示顺序', _showSitePickerDialog),
        _windowsSettingRow('仓库管理', '切换多仓配置', _showDepotPickerDialog),
        _windowsSettingRow('添加来源', '粘贴地址或导入配置文件', _showImportConfigDialog),
      ]);
    if (_windowsSettings == '账号')
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _windowsHeading('账号'),
        for (final drive in NetdiskService.drives)
          _windowsSettingRow(
              drive.providerName,
              widget.storage.isNetdiskLoggedIn(drive.key) ? '已连接' : '尚未连接',
              () => showNetdiskAccountSheet(context, widget.storage,
                      initialDriveKey: drive.key, onChanged: () {
                    if (mounted) _updateWindowsState(() {});
                  })),
      ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _windowsHeading('同步与备份'),
      _windowsSettingRow('多端网络同步', '同步收藏、观看进度与内容来源', _openCloudSyncCenter),
      _windowsSettingRow('导出与恢复备份', '保存或恢复应用配置', _showBackupRestoreDialog),
      _windowsSettingRow('隐私空间', '访问独立的私密收藏和内容来源', _openPrivateSpaceWithAuth),
    ]);
  }

  Widget _windowsSettingRow(
          String title, String description, VoidCallback action) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 15),
          child: WinPanel(
              child: Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: TextStyle(
                          color: winInk(context),
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 7),
                  Text(description,
                      style: TextStyle(color: winMuted(context), fontSize: 12))
                ])),
            WinButton('打开',
                icon: CupertinoIcons.chevron_right, onPressed: action)
          ])));

  Widget _windowsWelcome() =>
      _windowsEmpty('从一部影片开始。', '添加内容来源，搜索想看的影片。你的收藏与观看记录会保存在这里。',
          action: _showImportConfigDialog);
  Widget _windowsSearch(double pad) {
    final entries = <String, CmsSite>{
      for (final site in _visibleSupportedSites)
        '${site.subscriptionId}:${site.key}': site,
      for (final row in _searchResults)
        '${row.$1.subscriptionId}:${row.$1.key}': row.$1,
    };
    final results = _searchResults
        .where((r) =>
            _searchSiteFilterKey.isEmpty ||
            '${r.$1.subscriptionId}:${r.$1.key}' == _searchSiteFilterKey)
        .toList();
    final history =
        widget.storage.getSearchHistory(forPrivate: _privateSessionUnlocked);
    return Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 20),
        child: Column(children: [
          _windowsHeading(_privateSessionUnlocked ? '隐私空间搜索' : '搜索', actions: [
            WinButton('清空历史', onPressed: () async {
              await widget.storage
                  .clearSearchHistory(forPrivate: _privateSessionUnlocked);
              if (mounted) _updateWindowsState(() {});
            }),
          ]),
          WinPanel(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(children: [
                Expanded(
                    child: TextField(
                        key: const ValueKey('windows-search-input'),
                        controller: _searchController,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        style: TextStyle(color: winInk(context)),
                        decoration: const InputDecoration(
                            hintText: '搜索影片、剧集',
                            prefixIcon: Icon(CupertinoIcons.search),
                            border: InputBorder.none),
                        onSubmitted: (kw) {
                          if (_searchController.value.isComposingRangeValid) {
                            return;
                          }
                          _runGlobalSearch(kw);
                        })),
                WinButton('搜索',
                    selected: true,
                    onPressed: () => _runGlobalSearch(_searchController.text)),
              ])),
          const SizedBox(height: 14),
          if (!_searchPerformed && history.isNotEmpty)
            Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, children: [
                  for (final word in history)
                    WinButton(word, onPressed: () {
                      _searchController.text = word;
                      _runGlobalSearch(word);
                    })
                ])),
          SizedBox(
              height: 48,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                WinButton('全部片源',
                    selected: _searchSiteFilterKey.isEmpty,
                    onPressed: () =>
                        _updateWindowsState(() => _searchSiteFilterKey = '')),
                for (final entry in entries.entries)
                  SizedBox(
                      width: 170,
                      child: Tooltip(
                          message: entry.value.name,
                          child: WinButton(entry.value.name,
                              selected: entry.key == _searchSiteFilterKey,
                              onPressed: () => _updateWindowsState(
                                  () => _searchSiteFilterKey = entry.key)))),
              ])),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          if (_searchNotices.isNotEmpty)
            ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      for (final entry in _searchNotices.entries)
                        Row(children: [
                          Expanded(
                              child: Text(entry.value,
                                  style: TextStyle(color: winMuted(context)))),
                          if (_searchVerificationSites[entry.key]
                              case final site?)
                            SourceVerificationButton(
                                client: widget.client,
                                site: site,
                                onVerified: () => _retryVerifiedSearch(site)),
                        ]),
                    ]))),
          const SizedBox(height: 16),
          Expanded(
              child: results.isEmpty
                  ? Center(
                      child: Text(
                          _searching
                              ? '正在搜索已启用的片源…'
                              : !_searchPerformed
                                  ? '输入片名，开始查找想看的内容。'
                                  : '没有匹配影片，试试其他关键词或片源。',
                          style: TextStyle(color: winMuted(context))))
                  : ListView.separated(
                      key: const PageStorageKey('windows-search-results'),
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 14),
                      itemBuilder: (context, i) {
                        final (site, video) = results[i];
                        return WinPanel(
                            padding: EdgeInsets.zero,
                            child: InkWell(
                                key: ValueKey(
                                    'windows-search-${site.subscriptionId}-${site.key}-${video.id}'),
                                onTap: () => _openVideoDetail(site, video),
                                borderRadius: BorderRadius.circular(24),
                                child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Row(children: [
                                      SizedBox(
                                          width: 180,
                                          height: 105,
                                          child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(15),
                                              child: PosterImage(
                                                  url: video.poster,
                                                  title:
                                                      site.isEffectivelyPrivate
                                                          ? ''
                                                          : video.title,
                                                  placeholder: const ColoredBox(
                                                      color:
                                                          Color(0x30273548))))),
                                      const SizedBox(width: 22),
                                      Expanded(
                                          child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                            Text(video.title,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    color: winInk(context),
                                                    fontSize: 19,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                            const SizedBox(height: 10),
                                            Text(
                                                [
                                                  video.year,
                                                  video.remarks,
                                                  site.name
                                                ]
                                                    .where((v) => v.isNotEmpty)
                                                    .join(' · '),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    color: winMuted(context))),
                                          ])),
                                      Icon(CupertinoIcons.chevron_right,
                                          color: winMuted(context), size: 18),
                                    ]))));
                      })),
        ]));
  }
}
