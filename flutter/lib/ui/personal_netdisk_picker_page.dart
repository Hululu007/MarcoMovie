import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/personal_netdisk_library.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_settings.dart';
import 'netdisk_sheet.dart';

class _FolderCrumb {
  const _FolderCrumb({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}

/// Guided end-to-end flow for adding a personal cloud drive folder as a
/// persistent resource library (Quark / UC / Baidu / Ali):
///
/// 1. Reuse logged-in account or launch provider auth and auto-return here.
/// 2. Load personal root directory and browse nested folders with pagination.
/// 3. Select current directory -> verify -> save deduplicated resource library.
/// 4. Never creates an empty library on auth cancel or failure.
class PersonalNetdiskPickerPage extends StatefulWidget {
  const PersonalNetdiskPickerPage({
    super.key,
    required this.provider,
    required this.storage,
    required this.group,
    required this.isPrivate,
    required this.onLibrarySaved,
    this.client,
    this.onAuthorizeOverride,
    this.backLabel = '添加资源库',
  });

  final PersonalCloudProvider provider;
  final StorageService storage;
  final String group;
  final bool isPrivate;
  final ValueChanged<({SubscriptionEntry entry, bool updatedExisting})>
      onLibrarySaved;
  final PersonalCloudDriveClient? client;
  final Future<void> Function(BuildContext context)? onAuthorizeOverride;
  final String backLabel;

  @override
  State<PersonalNetdiskPickerPage> createState() =>
      _PersonalNetdiskPickerPageState();
}

class _PersonalNetdiskPickerPageState extends State<PersonalNetdiskPickerPage> {
  late final PersonalCloudDriveClient _client =
      widget.client ?? PersonalCloudDriveClient.fromStorage(widget.storage);
  late final bool _ownsClient = widget.client == null;

  late final List<_FolderCrumb> _stack = <_FolderCrumb>[
    _FolderCrumb(
      id: widget.provider.rootFolderId,
      name: widget.provider.rootLabel,
    ),
  ];

  final List<PersonalCloudItem> _items = <PersonalCloudItem>[];
  bool _loading = false;
  bool _loadingMore = false;
  bool _saving = false;
  bool _needsAuth = false;
  String? _error;
  String? _statusNote;
  int _page = 1;
  int _pageCount = 1;
  bool _hasMore = false;
  String _nextMarker = '';
  String _driveId = '';
  bool _autoAuthAttempted = false;

  _FolderCrumb get _current => _stack.last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrap());
    });
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (!widget.storage.isNetdiskLoggedIn(widget.provider.key)) {
      if (!_autoAuthAttempted) {
        _autoAuthAttempted = true;
        await _runAuthorization(autoStarted: true);
      } else if (mounted) {
        setState(() {
          _needsAuth = true;
          _error = '尚未授权${widget.provider.displayName}，未创建空资源库';
        });
      }
      return;
    }
    await _loadCurrentFolder(page: 1, replace: true);
  }

  Future<void> _runAuthorization({bool autoStarted = false}) async {
    if (mounted) {
      setState(() {
        _loading = false;
        _statusNote = '正在等待${widget.provider.displayName}授权…';
        _error = null;
      });
    }
    if (widget.onAuthorizeOverride != null) {
      await widget.onAuthorizeOverride!(context);
    } else {
      await showNetdiskAccountSheet(
        context,
        widget.storage,
        initialDriveKey: widget.provider.key,
        iosBackLabel: widget.provider.displayName,
      );
    }
    if (!mounted) return;
    if (!widget.storage.isNetdiskLoggedIn(widget.provider.key)) {
      setState(() {
        _needsAuth = true;
        _statusNote = null;
        _error = autoStarted
            ? '已取消${widget.provider.displayName}授权，未创建资源库。完成授权后可继续选择个人目录。'
            : '仍未检测到${widget.provider.displayName}有效登录，请完成扫码或账号配置后重试。';
      });
      return;
    }
    setState(() {
      _needsAuth = false;
      _statusNote = null;
      _error = null;
    });
    await _loadCurrentFolder(page: 1, replace: true);
  }

  Future<void> _loadCurrentFolder({
    required int page,
    required bool replace,
    String marker = '',
  }) async {
    final requestEpoch = ++_loadEpoch;
    final targetFolderId = _current.id;
    if (mounted) {
      setState(() {
        if (replace) {
          _loading = true;
          _error = null;
          _needsAuth = false;
          _statusNote = null;
        } else {
          _loadingMore = true;
        }
      });
    }
    try {
      final res = await _client.listFolder(
        widget.provider,
        folderId: targetFolderId,
        page: page,
        marker: marker,
        driveId: _driveId,
      );
      if (!mounted ||
          requestEpoch != _loadEpoch ||
          targetFolderId != _current.id) {
        return;
      }
      setState(() {
        if (replace) _items.clear();
        _items.addAll(res.items);
        _page = res.page;
        _pageCount = res.pageCount;
        _hasMore = res.hasMore;
        _nextMarker = res.nextMarker;
        if (res.driveId.isNotEmpty) _driveId = res.driveId;
        _loading = false;
        _loadingMore = false;
        _needsAuth = false;
        _error = null;
      });
    } on PersonalCloudException catch (e) {
      if (!mounted ||
          requestEpoch != _loadEpoch ||
          targetFolderId != _current.id) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        _needsAuth = e.requiresReauth;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted ||
          requestEpoch != _loadEpoch ||
          targetFolderId != _current.id) {
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '读取${widget.provider.displayName}目录失败：$e';
      });
    }
  }

  int _loadEpoch = 0;

  void _enterFolder(PersonalCloudItem dir) {
    _loadEpoch++;
    setState(() {
      _stack.add(_FolderCrumb(id: dir.id, name: dir.name));
      _items.clear();
      _page = 1;
      _pageCount = 1;
      _hasMore = false;
      _nextMarker = '';
      _loadingMore = false;
    });
    unawaited(_loadCurrentFolder(page: 1, replace: true));
  }

  void _jumpToCrumb(int index) {
    if (index < 0 || index >= _stack.length - 1) return;
    _loadEpoch++;
    setState(() {
      _stack.removeRange(index + 1, _stack.length);
      _items.clear();
      _page = 1;
      _pageCount = 1;
      _hasMore = false;
      _nextMarker = '';
      _loadingMore = false;
    });
    unawaited(_loadCurrentFolder(page: 1, replace: true));
  }

  Future<void> _saveCurrentDirectory() async {
    if (_saving || _needsAuth || _loading) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await PersonalCloudLibrary.create(
        client: _client,
        provider: widget.provider,
        folderId: _current.id,
        folderName: _current.name,
        driveId: _driveId,
        group: widget.group,
        isPrivate: widget.isPrivate,
      );
      await widget.storage.upsertSubscriptions([result.entry]);
      if (!mounted) return;
      widget.onLibrarySaved(result);
      Navigator.of(context).pop(result);
    } on PersonalCloudException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _needsAuth = e.requiresReauth;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存资源库失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final canSave = !_loading && !_saving && !_needsAuth && _error == null;

    return IosSettingsScaffold(
      title: widget.provider.displayName,
      backLabel: widget.backLabel,
      trailing: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(44, 44),
        onPressed: _loading
            ? null
            : () => _loadCurrentFolder(page: 1, replace: true),
        child: const Icon(CupertinoIcons.refresh, size: 19),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Breadcrumb bar
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                  width: 0.5,
                ),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < _stack.length; i++) ...[
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          CupertinoIcons.chevron_right,
                          size: 12,
                          color: palette.labelTertiary,
                        ),
                      ),
                    GestureDetector(
                      onTap: i < _stack.length - 1
                          ? () => _jumpToCrumb(i)
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Text(
                          _stack[i].name,
                          style: TextStyle(
                            color: i == _stack.length - 1
                                ? palette.labelPrimary
                                : AppleColors.systemBlue,
                            fontSize: 13.5,
                            fontWeight: i == _stack.length - 1
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Expanded(child: _buildListBody(palette)),
          // Bottom action bar: Add selected directory as resource library
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_statusNote != null) ...[
                      Text(
                        _statusNote!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Semantics(
                      button: true,
                      enabled: canSave,
                      label: '添加「${_current.name}」为资源库',
                      child: GestureDetector(
                        key: const ValueKey('personal-netdisk-save-folder-btn'),
                        behavior: HitTestBehavior.opaque,
                        onTap: canSave ? _saveCurrentDirectory : null,
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 48),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: canSave
                                ? AppleColors.systemBlue
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.10)
                                    : Colors.black.withValues(alpha: 0.08)),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: _saving
                              ? const CupertinoActivityIndicator(
                                  color: Colors.white,
                                )
                              : Text(
                                  '添加「${_current.name}」为资源库',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: canSave
                                        ? Colors.white
                                        : palette.labelTertiary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListBody(ApplePalette palette) {
    if (_loading && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 13),
            const SizedBox(height: 12),
            Text(
              '正在读取${widget.provider.displayName}目录…',
              style: TextStyle(color: palette.labelSecondary, fontSize: 13.5),
            ),
          ],
        ),
      );
    }
    if (_needsAuth || (_error != null && _items.isEmpty)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _needsAuth
                    ? CupertinoIcons.person_crop_circle_badge_exclam
                    : CupertinoIcons.exclamationmark_triangle_fill,
                size: 40,
                color: _needsAuth
                    ? AppleColors.systemBlue
                    : AppleColors.systemOrange,
              ),
              const SizedBox(height: 12),
              Text(
                _error ?? '需要授权${widget.provider.displayName}',
                key: const ValueKey('personal-netdisk-error-text'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.labelPrimary,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  if (_needsAuth)
                    AppleCapsuleButton(
                      key: const ValueKey('personal-netdisk-reauth-btn'),
                      label: '前往授权${widget.provider.shortName}账号',
                      icon: CupertinoIcons.qrcode,
                      primary: true,
                      compact: true,
                      onPressed: () => _runAuthorization(autoStarted: false),
                    ),
                  AppleCapsuleButton(
                    label: '重试读取',
                    icon: CupertinoIcons.refresh,
                    primary: !_needsAuth,
                    compact: true,
                    onPressed: () => _loadCurrentFolder(page: 1, replace: true),
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
                CupertinoIcons.folder,
                size: 40,
                color: palette.labelTertiary,
              ),
              const SizedBox(height: 10),
              Text(
                _hasMore
                    ? '当前页没有子目录或可播放视频'
                    : '当前目录没有子目录或视频文件',
                style: TextStyle(color: palette.labelSecondary, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                _hasMore
                    ? '该目录还有更多分页，可继续加载下一页查看影片，或直接将此目录加入资源库。'
                    : '您仍可返回上级目录选择包含影片的文件夹，或直接将此目录加入资源库。',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.labelTertiary, fontSize: 12.5),
              ),
              if (_hasMore) ...[
                const SizedBox(height: 16),
                if (_loadingMore)
                  const CupertinoActivityIndicator()
                else
                  AppleCapsuleButton(
                    key: const ValueKey('personal-netdisk-load-more-btn'),
                    label: _pageCount > 1
                        ? '加载更多（第 ${_page + 1}/$_pageCount 页）'
                        : '加载更多（第 ${_page + 1} 页）',
                    primary: true,
                    compact: true,
                    onPressed: () => _loadCurrentFolder(
                      page: _page + 1,
                      replace: false,
                      marker: _nextMarker,
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      itemCount: _items.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _loadingMore
                  ? const CupertinoActivityIndicator()
                  : AppleCapsuleButton(
                      key: const ValueKey('personal-netdisk-load-more-btn'),
                      label: _pageCount > 1
                          ? '加载更多（第 ${_page + 1}/$_pageCount 页）'
                          : '加载更多（第 ${_page + 1} 页）',
                      compact: true,
                      onPressed: () => _loadCurrentFolder(
                        page: _page + 1,
                        replace: false,
                        marker: _nextMarker,
                      ),
                    ),
            ),
          );
        }
        final item = _items[index];
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: item.isDir ? () => _enterFolder(item) : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(
                color: palette.isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
                width: 0.6,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  item.isDir
                      ? CupertinoIcons.folder_fill
                      : CupertinoIcons.film_fill,
                  color: item.isDir
                      ? AppleColors.systemBlue
                      : palette.labelSecondary,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 14,
                          fontWeight:
                              item.isDir ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (!item.isDir && item.size > 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          PersonalCloudLibrary.formatFileSize(item.size),
                          style: TextStyle(
                            color: palette.labelTertiary,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (item.isDir)
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 16,
                    color: palette.labelTertiary,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
