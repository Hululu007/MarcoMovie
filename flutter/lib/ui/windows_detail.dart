part of 'detail_screen.dart';

extension _WindowsDetail on _DetailScreenState {
  Widget _buildWindowsDetail(BuildContext context) {
    final bookmark = _findBookmark();
    final width = MediaQuery.sizeOf(context).width;
    final pad = width > 1000 ? 44.0 : 24.0;
    final hasLines = _video.lines.isNotEmpty;
    return Scaffold(
        backgroundColor: Colors.transparent,
        body: WindowsBackdrop(
            child: SafeArea(
                bottom: false,
                child: ListView(
                    padding: EdgeInsets.fromLTRB(pad, 20, pad, 36),
                    children: [
                      Row(children: [
                        WinButton('返回',
                            icon: CupertinoIcons.back,
                            onPressed: () => Navigator.of(context).pop()),
                        const Spacer(),
                        WinButton(_activeSite.name,
                            icon: CupertinoIcons.layers_alt,
                            onPressed: _showSourcePickerSheet)
                      ]),
                      const SizedBox(height: 19),
                      SizedBox(
                          height: width > 1000 ? 410 : 365,
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(30),
                              child: Stack(fit: StackFit.expand, children: [
                                PosterImage(
                                    url: _video.poster,
                                    title: _publicLookupTitle,
                                    year: _video.year,
                                    highRes: true,
                                    forBackdrop: true,
                                    placeholder: const ColoredBox(
                                        color: Color(0xFF29445C))),
                                const DecoratedBox(
                                    decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                  Color(0xED14283E),
                                  Color(0xA01D354A),
                                  Color(0x101D354A)
                                ], stops: [
                                  0,
                                  .48,
                                  1
                                ]))),
                                Padding(
                                    padding:
                                        EdgeInsets.all(width > 1000 ? 44 : 28),
                                    child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: SizedBox(
                                            width:
                                                (width * .53).clamp(380, 660),
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(_video.title,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                          color: Colors.white,
                                                          fontSize: width > 1000
                                                              ? 44
                                                              : 32,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          height: 1.2)),
                                                  const SizedBox(height: 16),
                                                  Text(
                                                      [
                                                        _video.year,
                                                        _video.area,
                                                        _video.remarks
                                                      ]
                                                          .where((s) =>
                                                              s.isNotEmpty)
                                                          .join(' · '),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                          color: Colors.white70,
                                                          fontSize: 13)),
                                                  const SizedBox(height: 15),
                                                  Text(
                                                      _effectiveSeriesSynopsis()
                                                          .replaceAll(
                                                              RegExp('<[^>]+>'),
                                                              ''),
                                                      maxLines: 3,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                          color: Colors.white70,
                                                          fontSize: 13,
                                                          height: 1.8)),
                                                  const SizedBox(height: 23),
                                                  Wrap(
                                                      spacing: 12,
                                                      runSpacing: 8,
                                                      children: [
                                                        FilledButton.icon(
                                                            style: FilledButton.styleFrom(
                                                                backgroundColor:
                                                                    Colors
                                                                        .white,
                                                                foregroundColor:
                                                                    const Color(
                                                                        0xFF23394E),
                                                                padding: const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        24,
                                                                    vertical:
                                                                        19)),
                                                            onPressed: hasLines
                                                                ? () =>
                                                                    _playPrimaryAction(
                                                                        bookmark)
                                                                : _loading
                                                                    ? null
                                                                    : _searchOtherSources,
                                                            icon: const Icon(
                                                                CupertinoIcons
                                                                    .play_fill,
                                                                size: 16),
                                                            label: Text(hasLines
                                                                ? bookmark !=
                                                                            null &&
                                                                        bookmark.resumePosition >
                                                                            0
                                                                    ? '继续观看'
                                                                    : '立即播放'
                                                                : _loading
                                                                    ? '加载片源中…'
                                                                    : '搜索其他片源')),
                                                        _windowsHeroAction(
                                                            _isFavorite
                                                                ? '已收藏'
                                                                : '收藏',
                                                            _isFavorite
                                                                ? CupertinoIcons
                                                                    .heart_fill
                                                                : CupertinoIcons
                                                                    .heart,
                                                            () async {
                                                          final value = await widget
                                                              .storage
                                                              .toggleFavorite(
                                                                  _activeSite,
                                                                  _video);
                                                          if (mounted)
                                                            _updateWindowsState(
                                                                () =>
                                                                    _isFavorite =
                                                                        value);
                                                        }),
                                                        _windowsHeroAction(
                                                            '下载',
                                                            CupertinoIcons
                                                                .arrow_down_to_line,
                                                            _showDownloadSheet),
                                                      ]),
                                                  if (bookmark != null) ...[
                                                    const SizedBox(height: 17),
                                                    Text(
                                                        '${bookmark.episode} · 已看 ${_formatBookmarkTime(bookmark.position)}',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                            color:
                                                                Colors.white70,
                                                            fontSize: 12))
                                                  ],
                                                ])))),
                              ]))),
                      const SizedBox(height: 27),
                      if (_loading) const LinearProgressIndicator(minHeight: 2),
                      if (_error != null)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: WinPanel(
                                dark: true, child: _buildDetailError())),
                      if (_video.sourceWarnings.isNotEmpty)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: WinPanel(
                                dark: true,
                                child: _buildSourceWarningsSection())),
                      if (hasLines) ...[
                        Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              WinButton(
                                  '选集 · ${_currentSeasonLabel(_video.lines[_selectedLine.clamp(0, _video.lines.length - 1)])}',
                                  selected: true,
                                  icon: CupertinoIcons.chevron_down,
                                  onPressed: _showSeasonPickerSheet),
                              WinButton(_descending ? '倒序' : '正序',
                                  icon: CupertinoIcons.sort_down,
                                  onPressed: () {
                                _updateWindowsState(() {
                                  _descending = !_descending;
                                  _selectedPage = 0;
                                });
                                widget.storage
                                    .setEpisodesDescending(_descending);
                              }),
                              WinButton('全部剧集',
                                  icon: CupertinoIcons.square_grid_2x2,
                                  onPressed: () =>
                                      _showAllEpisodesGridSheet(bookmark)),
                              WinButton('切换片源',
                                  onPressed: _showSourcePickerSheet),
                              WinButton('网盘账号',
                                  onPressed: () => showNetdiskAccountSheet(
                                          context, widget.storage,
                                          onChanged: () {
                                        if (mounted) _updateWindowsState(() {});
                                      })),
                            ]),
                        const SizedBox(height: 14),
                        SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(children: [
                              for (int i = 0; i < _video.lines.length; i++)
                                Padding(
                                    padding: const EdgeInsets.only(right: 7),
                                    child: WinButton(_video.lines[i].name,
                                        selected: i == _selectedLine,
                                        onPressed: () =>
                                            _updateWindowsState(() {
                                              _selectedLine = i;
                                              _selectedPage = 0;
                                              _selectedInLineSeason = null;
                                            })))
                            ])),
                        const SizedBox(height: 22),
                        _windowsEpisodes(bookmark),
                      ],
                      if (!hasLines && !_loading)
                        WinPanel(
                            child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('这个来源暂未提供可播放剧集',
                                style: TextStyle(color: winInk(context))),
                            const SizedBox(height: 12),
                            Wrap(spacing: 10, children: [
                              WinButton('切换片源',
                                  onPressed: _showSourcePickerSheet),
                              WinButton('搜索其他来源',
                                  onPressed: _searchOtherSources),
                            ]),
                          ],
                        )),
                      const SizedBox(height: 24),
                      if (_video.actor.isNotEmpty)
                        Text('演员 · ${_video.actor}',
                            style: TextStyle(
                                color: winMuted(context), height: 1.8)),
                      if (_effectiveSeriesSynopsis().isNotEmpty) ...[
                        const SizedBox(height: 15),
                        ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text('剧情介绍',
                                style: TextStyle(
                                    color: winInk(context), fontSize: 17)),
                            children: [
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                      _effectiveSeriesSynopsis()
                                          .replaceAll(RegExp('<[^>]+>'), ''),
                                      style: TextStyle(
                                          color: winMuted(context),
                                          height: 1.9)))
                            ])
                      ],
                    ]))));
  }

  Widget _windowsHeroAction(String label, IconData icon, VoidCallback action) =>
      OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white38),
              backgroundColor: Colors.white12,
              padding:
                  const EdgeInsets.symmetric(horizontal: 19, vertical: 18)),
          onPressed: action,
          icon: Icon(icon, size: 17),
          label: Text(label));

  Widget _windowsEpisodes(WatchHistoryEntry? bookmark) {
    final lineIndex = _selectedLine.clamp(0, _video.lines.length - 1);
    final line = _video.lines[lineIndex];
    final active = _activeEpisodeIndicesFor(line);
    final indices = _descending ? active.reversed.toList() : active;
    final pageCount = (indices.length / CmsParser.episodePageSize).ceil();
    final page = _selectedPage.clamp(0, pageCount == 0 ? 0 : pageCount - 1);
    final visible = indices
        .skip(page * CmsParser.episodePageSize)
        .take(CmsParser.episodePageSize)
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_lineUnavailableReason(line) case final reason?)
        Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(reason, style: TextStyle(color: winMuted(context)))),
      LayoutBuilder(builder: (context, box) {
        final columns = (box.maxWidth / 280).floor().clamp(2, 5);
        return Wrap(spacing: 22, runSpacing: 25, children: [
          for (final index in visible)
            SizedBox(
                width: (box.maxWidth - (columns - 1) * 22) / columns,
                child: InkWell(
                  key: ValueKey('ep_card_${lineIndex}_$index'),
                  onTap: () => _openPlayer(lineIndex, index),
                  borderRadius: BorderRadius.circular(18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Container(
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(19),
                                    border: Border.all(
                                        color: bookmark?.line == line.name &&
                                                bookmark?.index == index
                                            ? const Color(0xFF6A8CAC)
                                            : Colors.transparent,
                                        width: 2)),
                                padding: const EdgeInsets.all(2),
                                child: ClipRRect(
                                    borderRadius: BorderRadius.circular(15),
                                    child: EpisodeStillImage(
                                        seriesTitle: _publicLookupTitle,
                                        year: _video.year,
                                        episodeIndex: index,
                                        fallbackPosterUrl: _video.poster,
                                        placeholder: ColoredBox(
                                            color: winMuted(context)
                                                .withValues(alpha: .1),
                                            child: Center(
                                                child: Icon(
                                                    CupertinoIcons.play_rectangle,
                                                    color: winMuted(context),
                                                    size: 35))))))),
                        const SizedBox(height: 12),
                        Text(line.episodes[index].name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: winInk(context),
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        if (_episodeUnavailableReason(line.episodes[index])
                            case final reason?)
                          Text(reason,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: winMuted(context), fontSize: 11)),
                      ]),
                ))
        ]);
      }),
      if (pageCount > 1)
        Padding(
            padding: const EdgeInsets.only(top: 23),
            child: Wrap(spacing: 7, runSpacing: 7, children: [
              for (int i = 0; i < pageCount; i++)
                WinButton(
                    '${i * CmsParser.episodePageSize + 1}–${math.min((i + 1) * CmsParser.episodePageSize, indices.length)}',
                    selected: i == page,
                    onPressed: () =>
                        _updateWindowsState(() => _selectedPage = i))
            ])),
    ]);
  }
}
