import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/cms_client.dart';
import '../core/models.dart';
import '../core/personal_netdisk_library.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_settings.dart';
import 'netdisk_sheet.dart';
import 'poster_image.dart';

/// Multi-level directory browser shared by Personal Cloud Drives, WebDAV,
/// AList / OpenList, and pure SMB libraries whenever a listing returns nested
/// folders (`video.tag == 'media-folder'`).
class MediaFolderBrowserPage extends StatefulWidget {
  const MediaFolderBrowserPage({
    super.key,
    required this.site,
    required this.client,
    required this.storage,
    required this.folderId,
    required this.folderTitle,
    required this.onOpenVideo,
    this.backLabel = '返回',
  });

  final CmsSite site;
  final CmsClient client;
  final StorageService storage;
  final String folderId;
  final String folderTitle;
  final void Function(CmsSite site, CmsVideo video) onOpenVideo;
  final String backLabel;

  @override
  State<MediaFolderBrowserPage> createState() => _MediaFolderBrowserPageState();
}

class _MediaFolderBrowserPageState extends State<MediaFolderBrowserPage> {
  final List<CmsVideo> _items = <CmsVideo>[];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  bool _requiresReauth = false;
  int _page = 1;
  int _pageCount = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPage(1, replace: true));
  }

  Future<void> _loadPage(int page, {required bool replace}) async {
    if (mounted) {
      setState(() {
        if (replace) {
          _loading = true;
          _error = null;
          _requiresReauth = false;
        } else {
          _loadingMore = true;
        }
      });
    }
    try {
      final listing = await widget.client.fetchCategory(
        widget.site,
        widget.folderId,
        page,
      );
      if (!mounted) return;
      setState(() {
        if (replace) _items.clear();
        _items.addAll(listing.videos);
        _page = listing.page;
        _pageCount = listing.pageCount;
        _loading = false;
        _loadingMore = false;
        _error = null;
        _requiresReauth = false;
      });
    } on PersonalCloudException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.message;
        _requiresReauth = e.requiresReauth;
      });
    } catch (e) {
      if (!mounted) return;
      final detail = e
          .toString()
          .replaceFirst(RegExp(r'^(?:Exception|FormatException|StateError):\s*'), '')
          .trim();
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '读取目录失败：$detail（已有资源库不受影响，请检查网络或重试）';
        _requiresReauth = false;
      });
    }
  }

  Future<void> _handleReauth() async {
    String? providerKey;
    if (PersonalCloudLibrary.isSupportedSite(widget.site)) {
      try {
        final lib = await PersonalCloudLibrary.open(widget.site);
        providerKey = lib.provider.key;
        lib.close();
      } catch (_) {}
    }
    if (!mounted) return;
    await showNetdiskAccountSheet(
      context,
      widget.storage,
      initialDriveKey: providerKey,
      iosBackLabel: widget.folderTitle,
    );
    if (mounted) {
      await _loadPage(1, replace: true);
    }
  }

  void _openItem(CmsVideo item) {
    if (item.tag == PersonalCloudLibrary.folderTag ||
        item.id.startsWith('mmfolder://')) {
      Navigator.of(context).push<void>(
        buildApplePageRoute<void>(
          builder: (_) => MediaFolderBrowserPage(
            site: widget.site,
            client: widget.client,
            storage: widget.storage,
            folderId: item.id,
            folderTitle: item.title,
            backLabel: widget.folderTitle,
            onOpenVideo: widget.onOpenVideo,
          ),
        ),
      );
      return;
    }
    widget.onOpenVideo(widget.site, item);
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    return IosSettingsScaffold(
      title: widget.folderTitle,
      backLabel: widget.backLabel,
      trailing: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(44, 44),
        onPressed: _loading ? null : () => _loadPage(1, replace: true),
        child: const Icon(CupertinoIcons.refresh, size: 19),
      ),
      body: _buildBody(palette),
    );
  }

  Widget _buildBody(ApplePalette palette) {
    if (_loading && _items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(radius: 13),
            SizedBox(height: 12),
            Text('正在读取目录…', style: TextStyle(fontSize: 13.5)),
          ],
        ),
      );
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.exclamationmark_triangle_fill,
                size: 36,
                color: AppleColors.systemOrange,
              ),
              const SizedBox(height: 10),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  if (_requiresReauth)
                    AppleCapsuleButton(
                      label: '重新授权',
                      icon: CupertinoIcons.qrcode,
                      primary: true,
                      compact: true,
                      onPressed: _handleReauth,
                    ),
                  AppleCapsuleButton(
                    label: '重试',
                    icon: CupertinoIcons.refresh,
                    primary: !_requiresReauth,
                    compact: true,
                    onPressed: () => _loadPage(1, replace: true),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.folder_open,
                size: 40,
                color: palette.labelTertiary,
              ),
              const SizedBox(height: 10),
              Text(
                '此目录为空，没有子目录或可播放视频',
                style: TextStyle(color: palette.labelSecondary, fontSize: 14),
              ),
              const SizedBox(height: 14),
              AppleCapsuleButton(
                label: '刷新目录',
                icon: CupertinoIcons.refresh,
                compact: true,
                onPressed: () => _loadPage(1, replace: true),
              ),
            ],
          ),
        ),
      );
    }

    final hasMore = _page < _pageCount;
    final listView = ListView.separated(
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      itemCount: _items.length + (hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: _loadingMore
                  ? const CupertinoActivityIndicator()
                  : AppleCapsuleButton(
                      label: '加载更多（第 ${_page + 1} / $_pageCount 页）',
                      compact: true,
                      onPressed: () => _loadPage(_page + 1, replace: false),
                    ),
            ),
          );
        }
        final item = _items[index];
        final isFolder = item.tag == PersonalCloudLibrary.folderTag ||
            item.id.startsWith('mmfolder://');
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openItem(item),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: palette.isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                width: 0.6,
              ),
            ),
            child: Row(
              children: [
                if (isFolder)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppleColors.systemBlue.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      CupertinoIcons.folder_fill,
                      color: AppleColors.systemBlue,
                      size: 20,
                    ),
                  )
                else if (item.poster.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: PosterImage(
                        url: item.poster,
                        title: item.title,
                        placeholder: Container(
                          color: AppleColors.systemIndigo.withValues(alpha: 0.14),
                          child: const Icon(
                            CupertinoIcons.play_rectangle_fill,
                            color: AppleColors.systemIndigo,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppleColors.systemIndigo.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      CupertinoIcons.play_rectangle_fill,
                      color: AppleColors.systemIndigo,
                      size: 20,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (item.remarks.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.remarks,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.labelSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  isFolder
                      ? CupertinoIcons.chevron_right
                      : CupertinoIcons.play_circle,
                  size: isFolder ? 16 : 22,
                  color: isFolder
                      ? palette.labelTertiary
                      : AppleColors.systemBlue,
                ),
              ],
            ),
          ),
        );
      },
    );
    if (_error == null) return listView;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: (_requiresReauth
                      ? AppleColors.systemBlue
                      : AppleColors.systemOrange)
                  .withValues(alpha: palette.isDark ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: (_requiresReauth
                        ? AppleColors.systemBlue
                        : AppleColors.systemOrange)
                    .withValues(alpha: 0.30),
                width: 0.8,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _error!,
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_requiresReauth)
                      AppleCapsuleButton(
                        label: '重新授权',
                        icon: CupertinoIcons.qrcode,
                        primary: true,
                        compact: true,
                        onPressed: _handleReauth,
                      ),
                    AppleCapsuleButton(
                      label: '重试下一页',
                      icon: CupertinoIcons.refresh,
                      primary: !_requiresReauth,
                      compact: true,
                      onPressed: () => _loadPage(
                        hasMore ? _page + 1 : 1,
                        replace: !hasMore,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(child: listView),
      ],
    );
  }
}
