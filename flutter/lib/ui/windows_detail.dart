part of 'detail_screen.dart';

extension _WindowsDetail on _DetailScreenState {
  Widget _buildWindowsDetail(BuildContext context) {
    final saved = _findBookmark();
    final bookmark = _video.lines.isNotEmpty &&
            saved?.line ==
                _video
                    .lines[_selectedLine.clamp(0, _video.lines.length - 1)].name
        ? saved
        : null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: WindowsBackdrop(
          child: SafeArea(child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 1180 && box.maxHeight >= 600;
        final pad = box.maxWidth >= 1000 ? 32.0 : 22.0;
        return Column(children: [
          Padding(
              padding: EdgeInsets.fromLTRB(pad, 12, pad, 14),
              child: Row(children: [
                WinButton('返回',
                    icon: CupertinoIcons.back,
                    onPressed: () => Navigator.of(context).pop()),
                const Spacer(),
                ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth * .45),
                    child: Tooltip(
                        message: _activeSite.name,
                        child: WinButton(_activeSite.name,
                            icon: CupertinoIcons.layers_alt,
                            onPressed: _showSourcePickerSheet))),
              ])),
          Expanded(
              child: wide
                  ? Padding(
                      padding: EdgeInsets.fromLTRB(pad, 0, pad, 24),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                                width: 350,
                                child: SingleChildScrollView(
                                    child: _windowsDetailSummary(bookmark,
                                        stacked: true))),
                            const SizedBox(width: 24),
                            Expanded(
                                child: SingleChildScrollView(
                                    child: _windowsEpisodePanel(bookmark))),
                          ]))
                  : ListView(
                      padding: EdgeInsets.fromLTRB(pad, 0, pad, 24),
                      children: [
                          _windowsDetailSummary(bookmark),
                          const SizedBox(height: 18),
                          _windowsEpisodePanel(bookmark),
                        ])),
        ]);
      }))),
    );
  }

  Widget _windowsDetailSummary(WatchHistoryEntry? bookmark,
      {bool stacked = false}) {
    final hasLines = _video.lines.isNotEmpty;
    final compact = MediaQuery.sizeOf(context).width < 900;
    final posterWidth = stacked
        ? 134.0
        : compact
            ? 112.0
            : 144.0;
    final poster = SizedBox(
        key: const ValueKey('windows-detail-poster'),
        width: posterWidth,
        height: posterWidth * 1.5,
        child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: PosterImage(
                url: _video.poster,
                title: _publicLookupTitle,
                year: _video.year,
                highRes: true,
                placeholder: ColoredBox(
                    color: winMuted(context).withValues(alpha: .1),
                    child: Icon(CupertinoIcons.film,
                        color: winMuted(context), size: 40)))));
    final douban = _effectiveDoubanScore();
    final rt = _effectiveRtScore();
    final metadata =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_video.title,
          maxLines: stacked ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: winInk(context),
              fontSize: compact || stacked ? 25 : 30,
              height: 1.2,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Text(
          [_video.year, _video.area, _video.remarks]
              .where((s) => s.isNotEmpty)
              .join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style:
              TextStyle(color: winMuted(context), fontSize: 12, height: 1.5)),
      if (douban != null && douban >= 2 && douban <= 10 ||
          rt != null && rt >= 1 && rt <= 100) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 6, children: [
          if (douban != null && douban >= 2 && douban <= 10)
            Text('豆瓣 ★ ${douban.toStringAsFixed(1)}',
                key: const ValueKey('detail-douban-badge'),
                style: TextStyle(
                    color: winInk(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          if (rt != null && rt >= 1 && rt <= 100)
            Text('烂番茄 $rt%',
                key: const ValueKey('detail-rt-badge'),
                style: TextStyle(
                    color: winInk(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
        ]),
      ],
      if (!OhosRuntime.isOhos) ...[
        Builder(builder: (_) {
          final activeLine = _video.lines.isEmpty
              ? null
              : _video.lines[_selectedLine.clamp(0, _video.lines.length - 1)];
          final specBadges = _specBadgesForLine(activeLine);
          if (specBadges.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: MediaBadgeRow(
              badges: specBadges,
              maxBadges: 5,
              windowsSolid: true,
            ),
          );
        }),
      ],
      if (!stacked) ...[
        const SizedBox(height: 12),
        Text(_effectiveSeriesSynopsis().replaceAll(RegExp('<[^>]+>'), ''),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(color: winMuted(context), height: 1.6, fontSize: 12)),
      ],
    ]);
    final actions = Wrap(spacing: 8, runSpacing: 8, children: [
      WinButton(
          hasLines
              ? bookmark != null && bookmark.resumePosition > 0
                  ? '继续观看'
                  : '立即播放'
              : _loading
                  ? '加载片源中…'
                  : '搜索其他片源',
          selected: true,
          icon: CupertinoIcons.play_fill,
          onPressed: hasLines
              ? () => _playPrimaryAction(bookmark)
              : _loading
                  ? null
                  : _searchOtherSources),
      WinButton(_isFavorite ? '已收藏' : '收藏',
          icon: _isFavorite ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
          onPressed: () async {
        final value = await widget.storage.toggleFavorite(_activeSite, _video);
        if (mounted) _updateWindowsState(() => _isFavorite = value);
      }),
      WinButton('下载',
          icon: CupertinoIcons.arrow_down_to_line,
          onPressed: _showDownloadSheet),
    ]);
    return WinPanel(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (stacked) ...[
            Align(alignment: Alignment.center, child: poster),
            const SizedBox(height: 18),
            metadata,
          ] else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              poster,
              const SizedBox(width: 20),
              Expanded(child: metadata),
            ]),
          const SizedBox(height: 16),
          actions,
          if (bookmark != null) ...[
            const SizedBox(height: 10),
            Text(
                '${bookmark.episode} · 已看 ${_formatBookmarkTime(bookmark.position)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: winMuted(context), fontSize: 12)),
          ],
        ]));
  }

  Widget _windowsEpisodePanel(WatchHistoryEntry? bookmark) => WinPanel(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text('片源与选集',
                  style: TextStyle(
                      color: winInk(context),
                      fontSize: 20,
                      fontWeight: FontWeight.w600))),
          WinButton('切换片源',
              icon: CupertinoIcons.layers_alt,
              onPressed: _showSourcePickerSheet),
        ]),
        if (_loading)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(minHeight: 2)),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: WinPanel(dark: true, child: _buildDetailError())),
        if (_video.sourceWarnings.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child:
                  WinPanel(dark: true, child: _buildSourceWarningsSection())),
        if (_video.lines.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 7, runSpacing: 7, children: [
            for (var i = 0; i < _video.lines.length; i++)
              Builder(builder: (_) {
                final line = _video.lines[i];
                final spec = OhosRuntime.isOhos
                    ? ''
                    : MediaBadges.formatDotJoined(
                        _specBadgesForLine(line),
                        maxBadges: 2,
                      );
                final label = spec.isEmpty ? line.name : '${line.name} · $spec';
                return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Tooltip(
                        message: label,
                        child: WinButton(label,
                            selected: i == _selectedLine,
                            onPressed: () => _updateWindowsState(() {
                                  _selectedLine = i;
                                  _selectedPage = 0;
                                  _selectedInLineSeason = null;
                                }))));
              }),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 7, runSpacing: 7, children: [
            WinButton(
                '选集 · ${_currentSeasonLabel(_video.lines[_selectedLine.clamp(0, _video.lines.length - 1)])}',
                icon: CupertinoIcons.chevron_down,
                onPressed: _showSeasonPickerSheet),
            WinButton(_descending ? '倒序' : '正序', icon: CupertinoIcons.sort_down,
                onPressed: () {
              _updateWindowsState(() {
                _descending = !_descending;
                _selectedPage = 0;
              });
              widget.storage.setEpisodesDescending(_descending);
            }),
            WinButton('全部剧集',
                icon: CupertinoIcons.square_grid_2x2,
                onPressed: () => _showAllEpisodesGridSheet(bookmark)),
            WinButton('网盘账号',
                onPressed: () => showNetdiskAccountSheet(
                        context, widget.storage, onChanged: () {
                      if (mounted) _updateWindowsState(() {});
                    })),
          ]),
          const SizedBox(height: 16),
          _windowsEpisodes(bookmark),
        ] else if (!_loading) ...[
          const SizedBox(height: 20),
          Text('这个来源暂未提供可播放剧集', style: TextStyle(color: winMuted(context))),
          const SizedBox(height: 12),
          WinButton('搜索其他来源', onPressed: _searchOtherSources),
        ],
        if (_video.actor.isNotEmpty ||
            _effectiveSeriesSynopsis().isNotEmpty) ...[
          const SizedBox(height: 20),
          Divider(color: winMuted(context).withValues(alpha: .15)),
          ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              iconColor: winMuted(context),
              collapsedIconColor: winMuted(context),
              title: Text('剧情与演职员',
                  style: TextStyle(color: winInk(context), fontSize: 15)),
              children: [
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        [
                          if (_video.actor.isNotEmpty) '演员 · ${_video.actor}',
                          _effectiveSeriesSynopsis()
                              .replaceAll(RegExp('<[^>]+>'), ''),
                        ].where((s) => s.isNotEmpty).join('\n\n'),
                        style: TextStyle(
                            color: winMuted(context),
                            height: 1.8,
                            fontSize: 13)))
              ])
        ],
      ]));

  Widget _windowsEpisodes(WatchHistoryEntry? bookmark) {
    final lineIndex = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[lineIndex];
    final active = _activeEpisodeIndicesFor(line);
    final indices = _descending ? active.reversed.toList() : active;
    final pageCount = (indices.length / CmsParser.episodePageSize).ceil();
    final page = _selectedPage.clamp(0, pageCount == 0 ? 0 : pageCount - 1);
    final visible = indices
        .skip(page * CmsParser.episodePageSize)
        .take(CmsParser.episodePageSize);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_lineUnavailableReason(line) case final reason?)
        Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(reason, style: TextStyle(color: winMuted(context)))),
      LayoutBuilder(builder: (context, box) {
        final columns = (box.maxWidth / 122).floor().clamp(2, 10);
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final index in visible)
            SizedBox(
                width: (box.maxWidth - (columns - 1) * 10) / columns,
                child: Tooltip(
                    message: [
                      line.episodes[index].name,
                      if (_episodeUnavailableReason(line.episodes[index])
                          case final reason?)
                        reason
                    ].join(' · '),
                    child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                            key: ValueKey('ep_card_${lineIndex}_$index'),
                            onTap: () => _openPlayer(lineIndex, index),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 48),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color:
                                      winMuted(context).withValues(alpha: .07),
                                  border: Border.all(
                                      color: bookmark?.line == line.name &&
                                              bookmark?.index == index
                                          ? const Color(0xFF6489AC)
                                          : winMuted(context)
                                              .withValues(alpha: .14))),
                              child: Text(line.episodes[index].name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: winInk(context),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500)),
                            ))))),
        ]);
      }),
      if (pageCount > 1)
        Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Wrap(spacing: 7, runSpacing: 7, children: [
              for (var i = 0; i < pageCount; i++)
                WinButton(
                    '${i * CmsParser.episodePageSize + 1}–${math.min((i + 1) * CmsParser.episodePageSize, indices.length)}',
                    selected: i == page,
                    onPressed: () =>
                        _updateWindowsState(() => _selectedPage = i)),
            ])),
    ]);
  }
}
