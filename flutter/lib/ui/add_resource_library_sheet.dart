import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, Uint8List, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/cms_client.dart';
import '../core/cms_parser.dart';
import '../core/emby_library.dart';
import '../core/media_library_connectors.dart';
import '../core/models.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_settings.dart';
import 'motion/ios27_springs.dart';
import 'netdisk_sheet.dart';

enum _LibraryTileId {
  manualInput,
  localPack,
  clipboardQuick,
  configCenter,
  webdav,
  smb,
  localDevice,
  emby,
  jellyfin,
  plex,
  alistNas,
  quarkDrive,
  ucDrive,
  baiduDrive,
  aliDrive,
}

class _LibraryTileSpec {
  final _LibraryTileId id;
  final String label;
  final int sectionIndex;
  final int columnIndex;

  const _LibraryTileSpec({
    required this.id,
    required this.label,
    required this.sectionIndex,
    required this.columnIndex,
  });
}

class _LibrarySectionSpec {
  final String title;
  final List<_LibraryTileSpec> tiles;

  const _LibrarySectionSpec({
    required this.title,
    required this.tiles,
  });
}

class _ScatterSeed {
  final Offset startOffset;
  final double startAngle;
  final double startScale;
  final double staggerStart;
  final double ambientPhase;

  const _ScatterSeed({
    required this.startOffset,
    required this.startAngle,
    required this.startScale,
    required this.staggerStart,
    required this.ambientPhase,
  });
}

/// Rex-inspired "添加资源库" hub replacing the legacy import dialog.
///
/// Features:
/// - Categorized resource library grid (Subscriptions, File System, Media
///   Servers, Cloud Drives & NAS) with real end-to-end connectors.
/// - Custom animated vector icons with tactile spring bounce & ambient motion.
/// - Randomized scatter/stacked-pile -> categorized aligned grid entrance.
/// - Cleanly redesigned manual subscription & group-pill form.
class AddResourceLibraryView extends StatefulWidget {
  final StorageService storage;
  final CmsClient client;
  final String? initialInput;
  final String? initialError;
  final String initialGroup;
  final bool initialIsPrivate;
  final List<CmsSite> loadedSites;
  final String activeGroup;
  final VoidCallback? onOpenCatPawSettings;
  final VoidCallback onLibraryAdded;
  final Future<void> Function()? onNeedsPrivacyPassword;

  const AddResourceLibraryView({
    super.key,
    required this.storage,
    required this.client,
    this.initialInput,
    this.initialError,
    this.initialGroup = '默认分组',
    this.initialIsPrivate = false,
    this.loadedSites = const <CmsSite>[],
    this.activeGroup = '',
    this.onOpenCatPawSettings,
    required this.onLibraryAdded,
    this.onNeedsPrivacyPassword,
  });

  @override
  State<AddResourceLibraryView> createState() => _AddResourceLibraryViewState();
}

class _AddResourceLibraryViewState extends State<AddResourceLibraryView>
    with TickerProviderStateMixin {
  static const List<_LibrarySectionSpec> _sections = <_LibrarySectionSpec>[
    _LibrarySectionSpec(
      title: '文件系统',
      tiles: [
        _LibraryTileSpec(
          id: _LibraryTileId.webdav,
          label: 'WebDAV',
          sectionIndex: 0,
          columnIndex: 0,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.smb,
          label: 'SMB',
          sectionIndex: 0,
          columnIndex: 1,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.localDevice,
          label: '当前设备',
          sectionIndex: 0,
          columnIndex: 2,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.localPack,
          label: '本地配置包',
          sectionIndex: 0,
          columnIndex: 3,
        ),
      ],
    ),
    _LibrarySectionSpec(
      title: '媒体服务器',
      tiles: [
        _LibraryTileSpec(
          id: _LibraryTileId.emby,
          label: 'Emby',
          sectionIndex: 1,
          columnIndex: 0,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.jellyfin,
          label: 'Jellyfin',
          sectionIndex: 1,
          columnIndex: 1,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.plex,
          label: 'Plex',
          sectionIndex: 1,
          columnIndex: 2,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.alistNas,
          label: 'NAS / AList',
          sectionIndex: 1,
          columnIndex: 3,
        ),
      ],
    ),
    _LibrarySectionSpec(
      title: '订阅与手动导入',
      tiles: [
        _LibraryTileSpec(
          id: _LibraryTileId.manualInput,
          label: '手动输入',
          sectionIndex: 2,
          columnIndex: 0,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.clipboardQuick,
          label: '剪贴板快导',
          sectionIndex: 2,
          columnIndex: 1,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.configCenter,
          label: '配置中心',
          sectionIndex: 2,
          columnIndex: 2,
        ),
      ],
    ),
    _LibrarySectionSpec(
      title: '网盘与云库',
      tiles: [
        _LibraryTileSpec(
          id: _LibraryTileId.quarkDrive,
          label: '夸克云盘',
          sectionIndex: 3,
          columnIndex: 0,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.ucDrive,
          label: 'UC 网盘',
          sectionIndex: 3,
          columnIndex: 1,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.baiduDrive,
          label: '百度网盘',
          sectionIndex: 3,
          columnIndex: 2,
        ),
        _LibraryTileSpec(
          id: _LibraryTileId.aliDrive,
          label: '阿里云盘',
          sectionIndex: 3,
          columnIndex: 3,
        ),
      ],
    ),
  ];

  late final AnimationController _entranceCtrl;
  late final AnimationController _ambientCtrl;
  late final Map<_LibraryTileId, _ScatterSeed> _seeds;
  bool _busy = false;
  String? _bannerNotice;
  bool _bannerIsError = false;
  bool _openedInitialManual = false;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    _ambientCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
    _seeds = _generateRandomScatterSeeds();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Ios27ConcentricGeometry.isReduceMotion(context)) {
        _entranceCtrl.value = 1.0;
      } else {
        unawaited(_entranceCtrl.forward());
      }
      final hasDirectPayload =
          (widget.initialInput != null && widget.initialInput!.trim().isNotEmpty) ||
              (widget.initialError != null &&
                  widget.initialError!.trim().isNotEmpty);
      if (hasDirectPayload && !_openedInitialManual) {
        _openedInitialManual = true;
        unawaited(
          _openManualImportForm(
            initialUrl: widget.initialInput,
            initialError: widget.initialError,
          ),
        );
      }
    });
  }

  Map<_LibraryTileId, _ScatterSeed> _generateRandomScatterSeeds() {
    final rng = math.Random();
    final map = <_LibraryTileId, _ScatterSeed>{};
    var idx = 0;
    for (final section in _sections) {
      for (final tile in section.tiles) {
        // Pull every tile initially into a lively, randomized stacked deck near
        // the center of the sheet, with varied tilt angles & slight depth scale.
        final centerColBias = (1.5 - tile.columnIndex) * 76.0;
        final centerRowBias = (1.45 - tile.sectionIndex) * 116.0;
        final jitterX = (rng.nextDouble() * 2 - 1) * 34.0;
        final jitterY = (rng.nextDouble() * 2 - 1) * 28.0;
        final angle = (rng.nextDouble() * 2 - 1) * 0.44;
        final scale = 0.72 + rng.nextDouble() * 0.24;
        final stagger = (idx * 0.026).clamp(0.0, 0.36);
        map[tile.id] = _ScatterSeed(
          startOffset: Offset(centerColBias + jitterX, centerRowBias + jitterY),
          startAngle: angle,
          startScale: scale,
          staggerStart: stagger,
          ambientPhase: rng.nextDouble() * math.pi * 2,
        );
        idx++;
      }
    }
    return map;
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _ambientCtrl.dispose();
    super.dispose();
  }

  void _setNotice(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _bannerNotice = msg;
      _bannerIsError = isError;
    });
  }

  Future<void> _commitSubscriptionEntry(
    SubscriptionEntry entry, {
    bool isPrivate = false,
  }) async {
    await widget.storage.upsertSubscriptions([entry]);
    widget.onLibraryAdded();
    if (isPrivate && !widget.storage.hasPrivacyPassword) {
      await widget.onNeedsPrivacyPassword?.call();
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleTileTap(_LibraryTileId id) async {
    if (_busy) return;
    unawaited(HapticFeedback.selectionClick());
    switch (id) {
      case _LibraryTileId.manualInput:
        await _openManualImportForm();
        return;
      case _LibraryTileId.localPack:
        await _handlePickLocalPack();
        return;
      case _LibraryTileId.clipboardQuick:
        await _handleClipboardQuickImport();
        return;
      case _LibraryTileId.configCenter:
        await _openConfigCenter(null);
        return;
      case _LibraryTileId.quarkDrive:
        await _openConfigCenter('quark');
        return;
      case _LibraryTileId.ucDrive:
        await _openConfigCenter('uc');
        return;
      case _LibraryTileId.baiduDrive:
        await _openConfigCenter('baidu');
        return;
      case _LibraryTileId.aliDrive:
        await _openConfigCenter('ali');
        return;
      case _LibraryTileId.emby:
        await _openServerForm(
          title: '连接 Emby 媒体库',
          accentColor: const Color(0xFF52B54B),
          addressHint: 'https://emby.example:8096',
          fields: const [
            _FormFieldSpec('address', '服务器地址', 'https://emby.example:8096'),
            _FormFieldSpec('user', '用户名', '填写 Emby 账号'),
            _FormFieldSpec('pass', '密码', '填写登录密码', obscure: true),
          ],
          onConnect: (values, group, isPriv) => EmbyLibrary.login(
            values['address'] ?? '',
            values['user'] ?? '',
            values['pass'] ?? '',
            group: group,
            isPrivate: isPriv,
          ),
        );
        return;
      case _LibraryTileId.jellyfin:
        await _openServerForm(
          title: '连接 Jellyfin 媒体库',
          accentColor: const Color(0xFF7B61FF),
          addressHint: 'https://jellyfin.example:8096',
          fields: const [
            _FormFieldSpec('address', '服务器地址', 'https://jellyfin.example:8096'),
            _FormFieldSpec('user', '用户名', '填写 Jellyfin 账号'),
            _FormFieldSpec('pass', '密码', '填写登录密码', obscure: true),
          ],
          onConnect: (values, group, isPriv) => JellyfinLibrary.login(
            values['address'] ?? '',
            values['user'] ?? '',
            values['pass'] ?? '',
            group: group,
            isPrivate: isPriv,
          ),
        );
        return;
      case _LibraryTileId.plex:
        await _openServerForm(
          title: '连接 Plex 媒体库',
          accentColor: const Color(0xFFE5A00D),
          addressHint: 'http://plex.example:32400',
          fields: const [
            _FormFieldSpec('address', '服务器地址', 'http://plex.example:32400'),
            _FormFieldSpec('token', 'X-Plex-Token', '粘贴 Plex 访问令牌', obscure: true),
            _FormFieldSpec('label', '显示名称（可选）', '如：客厅 Plex'),
          ],
          onConnect: (values, group, isPriv) => PlexLibrary.login(
            values['address'] ?? '',
            values['token'] ?? '',
            label: values['label'] ?? '',
            group: group,
            isPrivate: isPriv,
          ),
        );
        return;
      case _LibraryTileId.webdav:
        await _openServerForm(
          title: '添加 WebDAV 资源库',
          accentColor: const Color(0xFF0A84FF),
          addressHint: 'https://nas.example:5006/video/',
          fields: const [
            _FormFieldSpec('address', 'WebDAV 地址', 'https://dav.example/movies/'),
            _FormFieldSpec('user', '用户名（可选）', '留空支持匿名访问'),
            _FormFieldSpec('pass', '密码（可选）', '填写密码或应用专用密码', obscure: true),
            _FormFieldSpec('label', '资源库名称（可选）', '如：家庭电影库'),
          ],
          onConnect: (values, group, isPriv) => WebDavMediaLibrary.login(
            values['address'] ?? '',
            username: values['user'] ?? '',
            password: values['pass'] ?? '',
            label: values['label'] ?? '',
            group: group,
            isPrivate: isPriv,
          ),
        );
        return;
      case _LibraryTileId.alistNas:
        await _openServerForm(
          title: '添加 NAS / AList 资源库',
          accentColor: const Color(0xFF0EA5E9),
          addressHint: 'http://nas.example:5244',
          fields: const [
            _FormFieldSpec('address', 'AList / OpenList 地址', 'http://nas.example:5244'),
            _FormFieldSpec('root', '起始目录（可选）', '/'),
            _FormFieldSpec('user', '账号（公开站可留空）', 'admin'),
            _FormFieldSpec('pass', '密码（公开站可留空）', '填写登录密码', obscure: true),
            _FormFieldSpec('label', '显示名称（可选）', '如：群晖 / 飞牛 NAS'),
          ],
          onConnect: (values, group, isPriv) => AlistNasLibrary.login(
            values['address'] ?? '',
            username: values['user'] ?? '',
            password: values['pass'] ?? '',
            rootPath: (values['root'] ?? '').trim().isEmpty
                ? '/'
                : values['root']!.trim(),
            label: values['label'] ?? '',
            group: group,
            isPrivate: isPriv,
          ),
        );
        return;
      case _LibraryTileId.smb:
        await _openServerForm(
          title: '添加 SMB / 局域网 NAS',
          accentColor: const Color(0xFF2563EB),
          addressHint: 'nas.example',
          fields: const [
            _FormFieldSpec('host', '主机 IP 或域名', '如：nas.example 或局域网主机 IP'),
            _FormFieldSpec('share', '共享目录名', '如：Movies 或 Video'),
            _FormFieldSpec('user', '用户名（可选）', 'SMB 登录账号'),
            _FormFieldSpec('pass', '密码（可选）', 'SMB 登录密码', obscure: true),
            _FormFieldSpec(
              'webdav',
              '伴随 WebDAV 地址（可选，用于目录浏览）',
              'https://dav.example:5006/Movies/',
            ),
          ],
          onConnect: (values, group, isPriv) => SmbNasLibrary.configure(
            host: values['host'] ?? '',
            share: values['share'] ?? '',
            username: values['user'] ?? '',
            password: values['pass'] ?? '',
            webdavCompanionUrl: values['webdav'] ?? '',
            group: group,
            isPrivate: isPriv,
          ),
        );
        return;
      case _LibraryTileId.localDevice:
        await _handlePickLocalVideos();
        return;
    }
  }

  Future<void> _openConfigCenter(String? initialDriveKey) async {
    await showNetdiskAccountSheet(
      context,
      widget.storage,
      initialDriveKey: initialDriveKey,
      iosBackLabel: '添加资源库',
      sites: widget.loadedSites,
      activeGroup: widget.activeGroup,
      onOpenCatPawSettings: widget.onOpenCatPawSettings,
      onChanged: widget.onLibraryAdded,
    );
  }

  Future<void> _handlePickLocalPack() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
      );
      final entry = picked?.files.single;
      if (entry == null || !mounted) return;
      final Uint8List rawBytes;
      if (entry.path != null && entry.path!.isNotEmpty) {
        final file = File(entry.path!);
        if (await file.length() > CmsClient.maxResponseBytes) {
          throw const FormatException('文件超过 6 MB');
        }
        rawBytes = await file.readAsBytes();
      } else if (entry.bytes != null) {
        if (entry.bytes!.length > CmsClient.maxResponseBytes) {
          throw const FormatException('文件超过 6 MB');
        }
        rawBytes = entry.bytes!;
      } else {
        return;
      }
      final body = CmsClient.readSubscriptionFile(rawBytes, entry.name);
      if (!mounted) return;
      await _openManualImportForm(initialJson: body);
    } catch (e) {
      _setNotice('读取本地配置包失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handlePickLocalVideos() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: false,
      );
      final paths = (picked?.files ?? const <PlatformFile>[])
          .map((f) => f.path ?? '')
          .where((p) => p.isNotEmpty)
          .toList();
      if (paths.isEmpty || !mounted) return;
      // If the user picked a single JSON/ZIP/M3U config file, route to config pack parser.
      if (paths.length == 1) {
        final lower = paths.first.toLowerCase();
        if (lower.endsWith('.json') ||
            lower.endsWith('.zip') ||
            lower.endsWith('.m3u') ||
            lower.endsWith('.txt')) {
          final rawBytes = await File(paths.first).readAsBytes();
          final body = CmsClient.readSubscriptionFile(
            rawBytes,
            paths.first.split(Platform.pathSeparator).last,
          );
          if (!mounted) return;
          await _openManualImportForm(initialJson: body);
          return;
        }
      }
      final entry = await LocalDeviceLibrary.createFromPaths(
        paths,
        label: '当前设备 · ${paths.length} 部影片',
        group: widget.initialGroup,
        isPrivate: widget.initialIsPrivate,
      );
      await _commitSubscriptionEntry(entry, isPrivate: widget.initialIsPrivate);
    } catch (e) {
      _setNotice('导入本机影片失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleClipboardQuickImport() async {
    setState(() => _busy = true);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = (data?.text ?? '').trim();
      if (text.isEmpty) {
        _setNotice('剪贴板为空，请先复制订阅链接或配置内容', isError: true);
        return;
      }
      if (CmsParser.isBackupPayload(text)) {
        await widget.storage.importBackupJson(text);
        widget.onLibraryAdded();
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final entries = await widget.client.resolveBatchSubscriptions(
        rawTextInput: text,
        defaultGroup: widget.initialGroup,
        isPrivate: widget.initialIsPrivate,
      );
      await widget.storage.upsertSubscriptions(entries);
      widget.onLibraryAdded();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      await _openManualImportForm(
        initialUrl: (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        initialError: '剪贴板内容未能自动识别：$e',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openServerForm({
    required String title,
    required Color accentColor,
    required String addressHint,
    required List<_FormFieldSpec> fields,
    required Future<SubscriptionEntry> Function(
      Map<String, String> values,
      String group,
      bool isPrivate,
    )
    onConnect,
  }) async {
    final ctrls = <String, TextEditingController>{
      for (final f in fields) f.key: TextEditingController(),
    };
    final groupCtrl = TextEditingController(text: widget.initialGroup);
    var isPrivate = widget.initialIsPrivate;
    var busy = false;
    String? error;
    final showPrivacy =
        widget.initialIsPrivate || !widget.storage.hasPrivacyConfigured;

    await _pushSubForm(
      title: title,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final palette = ApplePalette.of(ctx);
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              24 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGroupSelectorBlock(
                  ctx: ctx,
                  groupCtrl: groupCtrl,
                  onChanged: () => setModalState(() {}),
                ),
                const SizedBox(height: 16),
                for (final f in fields) ...[
                  Text(
                    f.label,
                    style: TextStyle(
                      color: palette.labelSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _buildStyledInput(
                    ctx,
                    controller: ctrls[f.key]!,
                    placeholder: f.placeholder,
                    obscure: f.obscure,
                  ),
                  const SizedBox(height: 14),
                ],
                if (showPrivacy) ...[
                  _buildPrivacyToggleRow(
                    ctx,
                    value: isPrivate,
                    onChanged: (v) => setModalState(() => isPrivate = v),
                  ),
                  const SizedBox(height: 14),
                ],
                if (error != null) ...[
                  _buildErrorBanner(error!),
                  const SizedBox(height: 14),
                ],
                SizedBox(
                  height: 48,
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    color: accentColor,
                    borderRadius: BorderRadius.circular(14),
                    onPressed: busy
                        ? null
                        : () async {
                            setModalState(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              final vals = <String, String>{
                                for (final e in ctrls.entries)
                                  e.key: e.value.text.trim(),
                              };
                              final group = groupCtrl.text.trim().isEmpty
                                  ? '默认分组'
                                  : groupCtrl.text.trim();
                              final entry = await onConnect(
                                vals,
                                group,
                                isPrivate,
                              );
                              if (ctx.mounted) Navigator.of(ctx).pop();
                              await _commitSubscriptionEntry(
                                entry,
                                isPrivate: isPrivate,
                              );
                            } catch (e) {
                              if (ctx.mounted) {
                                setModalState(() {
                                  busy = false;
                                  error = '$e';
                                });
                              }
                            }
                          },
                    child: busy
                        ? const CupertinoActivityIndicator(
                            color: Colors.white,
                            radius: 10,
                          )
                        : const Text(
                            '验证并添加资源库',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    for (final c in ctrls.values) {
      c.dispose();
    }
    groupCtrl.dispose();
  }

  Future<void> _openManualImportForm({
    String? initialUrl,
    String? initialJson,
    String? initialError,
  }) async {
    final urlCtrl = TextEditingController(
      text: initialUrl ??
          (initialJson == null && !widget.initialIsPrivate
              ? widget.storage.configOrigin
              : ''),
    );
    final jsonCtrl = TextEditingController(text: initialJson ?? '');
    final groupCtrl = TextEditingController(text: widget.initialGroup);
    var isPrivate = widget.initialIsPrivate;
    var submitting = false;
    String? errorText = initialError;
    final showPrivacyToggle =
        widget.initialIsPrivate || !widget.storage.hasPrivacyConfigured;

    await _pushSubForm(
      title: widget.initialIsPrivate ? '导入隐私订阅' : '手动导入订阅',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final palette = ApplePalette.of(ctx);
          Future<void> handleImport() async {
            setModalState(() {
              submitting = true;
              errorText = null;
            });
            try {
              final urlText = urlCtrl.text.trim();
              final jsonText = jsonCtrl.text.trim();
              final selectedGroup = groupCtrl.text.trim().isEmpty
                  ? '默认分组'
                  : groupCtrl.text.trim();
              final effectivePrivate = isPrivate ||
                  selectedGroup.contains('隐私') ||
                  selectedGroup.contains('私密');
              final candidateBackup = jsonText.isNotEmpty ? jsonText : urlText;
              if (CmsParser.isBackupPayload(candidateBackup)) {
                await widget.storage.importBackupJson(candidateBackup);
                if (ctx.mounted) Navigator.of(ctx).pop();
                widget.onLibraryAdded();
                if (mounted) Navigator.of(context).pop();
                return;
              }
              final entries = await widget.client.resolveBatchSubscriptions(
                urlInput: urlText,
                rawTextInput: jsonText,
                defaultGroup: selectedGroup,
                isPrivate: effectivePrivate,
              );
              await widget.storage.upsertSubscriptions(entries);
              if (ctx.mounted) Navigator.of(ctx).pop();
              widget.onLibraryAdded();
              if (effectivePrivate && !widget.storage.hasPrivacyPassword) {
                await widget.onNeedsPrivacyPassword?.call();
              }
              if (mounted) Navigator.of(context).pop();
            } catch (e) {
              if (ctx.mounted) {
                setModalState(() {
                  submitting = false;
                  errorText = '导入失败：$e';
                });
              }
            }
          }

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              24 + MediaQuery.viewInsetsOf(ctx).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGroupSelectorBlock(
                  ctx: ctx,
                  groupCtrl: groupCtrl,
                  onChanged: () => setModalState(() {}),
                ),
                const SizedBox(height: 16),
                if (showPrivacyToggle) ...[
                  _buildPrivacyToggleRow(
                    ctx,
                    value: isPrivate,
                    onChanged: (v) => setModalState(() {
                      isPrivate = v;
                      if (v && groupCtrl.text.trim() == '默认分组') {
                        groupCtrl.text = '隐私分组';
                      } else if (!v && groupCtrl.text.trim() == '隐私分组') {
                        groupCtrl.text = '默认分组';
                      }
                    }),
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '订阅地址（支持 JSON / 多仓 / VOD / M3U）',
                        style: TextStyle(
                          color: palette.labelSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 28),
                      onPressed: () async {
                        final data =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        final clip = (data?.text ?? '').trim();
                        if (clip.isEmpty) return;
                        if (clip.startsWith('{') ||
                            clip.startsWith('[') ||
                            clip.startsWith('#EXTM3U') ||
                            clip.startsWith('<')) {
                          jsonCtrl.text = clip;
                        } else {
                          urlCtrl.text = clip;
                        }
                        setModalState(() => errorText = null);
                      },
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.doc_on_clipboard,
                            size: 14,
                            color: AppleColors.systemBlue,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '粘贴',
                            style: TextStyle(
                              color: AppleColors.systemBlue,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _buildStyledInput(
                  ctx,
                  controller: urlCtrl,
                  placeholder: 'https://config.example/config.json（每行一个地址）',
                  minLines: 2,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                ),
                const SizedBox(height: 14),
                Text(
                  '或直接粘贴配置内容（JSON / M3U / TXT / JS）',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _buildStyledInput(
                  ctx,
                  controller: jsonCtrl,
                  placeholder: '{"sites": [...]} 或 #EXTM3U 播放列表',
                  minLines: 2,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 14),
                  _buildErrorBanner(errorText!),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  height: 48,
                  child: CupertinoButton(
                    key: const ValueKey('manual-import-submit-btn'),
                    padding: EdgeInsets.zero,
                    color: AppleColors.systemBlue,
                    borderRadius: BorderRadius.circular(14),
                    onPressed: submitting ? null : handleImport,
                    child: submitting
                        ? const CupertinoActivityIndicator(
                            color: Colors.white,
                            radius: 10,
                          )
                        : const Text(
                            '立即解析并导入',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    urlCtrl.dispose();
    jsonCtrl.dispose();
    groupCtrl.dispose();
  }

  Future<void> _pushSubForm({
    required String title,
    required WidgetBuilder builder,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await Navigator.of(context).push<void>(
        buildApplePageRoute<void>(
          builder: (ctx) => IosSettingsScaffold(
            title: title,
            backLabel: '添加资源库',
            body: builder(ctx),
          ),
        ),
      );
      return;
    }
    await showIos27LiquidSheet<void>(
      context: context,
      title: title,
      maxWidth: 520,
      builder: builder,
    );
  }

  Widget _buildGroupSelectorBlock({
    required BuildContext ctx,
    required TextEditingController groupCtrl,
    required VoidCallback onChanged,
  }) {
    const presetGroups = ['默认分组', '主力影视', '超清专线', '电视直播', '动漫番剧'];
    final palette = ApplePalette.of(ctx);
    final isDark = palette.isDark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '订阅分组',
          style: TextStyle(
            color: palette.labelSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final g in presetGroups)
              GestureDetector(
                key: ValueKey('import-group-pill-$g'),
                onTap: () {
                  groupCtrl.text = g;
                  onChanged();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: groupCtrl.text.trim() == g
                        ? AppleColors.systemBlue
                        : (isDark
                            ? const Color(0xFF2C2C2E)
                            : Colors.white),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: groupCtrl.text.trim() == g
                          ? AppleColors.systemBlue
                          : (isDark
                              ? Colors.white.withValues(alpha: 0.14)
                              : const Color(0xFFCBD5E1)),
                      width: 0.9,
                    ),
                  ),
                  child: Text(
                    g,
                    style: TextStyle(
                      color: groupCtrl.text.trim() == g
                          ? Colors.white
                          : palette.labelPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _buildStyledInput(
          ctx,
          controller: groupCtrl,
          placeholder: '或输入自定义分组名（如：主力4K）',
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }

  Widget _buildStyledInput(
    BuildContext ctx, {
    required TextEditingController controller,
    required String placeholder,
    bool obscure = false,
    int minLines = 1,
    int maxLines = 1,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) {
    final palette = ApplePalette.of(ctx);
    final isDark = palette.isDark;
    return TextSelectionMouseGuard(
      child: CupertinoTextField(
        controller: controller,
        placeholder: placeholder,
        obscureText: obscure,
        minLines: minLines,
        maxLines: obscure ? 1 : maxLines,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: false,
        smartQuotesType: SmartQuotesType.disabled,
        smartDashesType: SmartDashesType.disabled,
        cursorColor: AppleColors.systemBlue,
        onChanged: onChanged,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        style: TextStyle(
          color: palette.labelPrimary,
          fontSize: 14.5,
          fontWeight: FontWeight.w500,
        ),
        placeholderStyle: TextStyle(
          color: isDark ? const Color(0xFF9A9AA6) : const Color(0xFF6B7280),
          fontSize: 13.5,
        ),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.14)
                : const Color(0xFFCBD5E1),
            width: 0.85,
          ),
        ),
      ),
    );
  }

  Widget _buildPrivacyToggleRow(
    BuildContext ctx, {
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final palette = ApplePalette.of(ctx);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.separator, width: 0.65),
      ),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.lock_shield_fill,
            color: AppleColors.systemPurple,
            size: 19,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '设为隐私分组',
              style: TextStyle(
                color: palette.labelPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          CupertinoSwitch(
            value: value,
            activeTrackColor: AppleColors.systemPurple,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x24FF453A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x66FF453A), width: 0.7),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: AppleColors.systemRed,
          fontSize: 13,
          height: 1.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    return SingleChildScrollView(
      key: const ValueKey('add-resource-library-hub'),
      padding: EdgeInsets.fromLTRB(20, 14, 20, safeBottom + 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rex-style sheet hero header
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1C1C22) : const Color(0xFF11131A),
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x260F172A),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: MarcoBrandLogo(iconSize: 28, showWordmark: false),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.initialIsPrivate ? '添加隐私资源库' : '添加资源库',
                      style: TextStyle(
                        color: palette.labelPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.35,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Marco Movie 可自动识别并管理各类文件与片源。',
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (_busy) const CupertinoActivityIndicator(radius: 10),
            ],
          ),
          if (_bannerNotice != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                color: _bannerIsError
                    ? const Color(0x22FF453A)
                    : const Color(0x2230D158),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _bannerIsError
                      ? const Color(0x55FF453A)
                      : const Color(0x5530D158),
                  width: 0.7,
                ),
              ),
              child: Text(
                _bannerNotice!,
                style: TextStyle(
                  color: _bannerIsError
                      ? AppleColors.systemRed
                      : AppleColors.systemGreen,
                  fontSize: 13,
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          // Categorized Rex-style icon grid with scatter/stack -> aligned entrance
          AnimatedBuilder(
            animation: _entranceCtrl,
            builder: (context, _) {
              final rawT = _entranceCtrl.value;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var sIdx = 0; sIdx < _sections.length; sIdx++) ...[
                    _buildSectionBlock(
                      context,
                      _sections[sIdx],
                      sectionIndex: sIdx,
                      entranceT: rawT,
                    ),
                    if (sIdx < _sections.length - 1) const SizedBox(height: 22),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSectionBlock(
    BuildContext context,
    _LibrarySectionSpec section, {
    required int sectionIndex,
    required double entranceT,
  }) {
    final palette = ApplePalette.of(context);
    final headerT =
        ((entranceT - (0.28 + sectionIndex * 0.08)) / 0.42).clamp(0.0, 1.0);
    final headerEase = Curves.easeOutCubic.transform(headerT);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(
          opacity: headerEase,
          child: Transform.translate(
            offset: Offset(0, (1.0 - headerEase) * 8.0),
            child: Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 12),
              child: Text(
                section.title,
                style: TextStyle(
                  color: palette.labelSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            const cols = 4;
            final tileW = (constraints.maxWidth / cols).floorToDouble();
            return Wrap(
              alignment: WrapAlignment.start,
              runSpacing: 16,
              children: [
                for (final tile in section.tiles)
                  SizedBox(
                    width: tileW,
                    child: _buildAnimatedTile(
                      context,
                      tile,
                      entranceT: entranceT,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildAnimatedTile(
    BuildContext context,
    _LibraryTileSpec tile, {
    required double entranceT,
  }) {
    final seed = _seeds[tile.id]!;
    final palette = ApplePalette.of(context);
    // Phase 1 (0..0.16): icons pop in as a messy stacked pile at center.
    // Phase 2 (staggerStart..1.0): icons smoothly un-rotate & spring into grid.
    final localT = ((entranceT - seed.staggerStart) /
            math.max(0.05, 1.0 - seed.staggerStart))
        .clamp(0.0, 1.0);
    final springCurve = Ios27Spring.bouncy.curve.transform(localT);
    final dx = seed.startOffset.dx * (1.0 - springCurve);
    final dy = seed.startOffset.dy * (1.0 - springCurve);
    final angle = seed.startAngle * (1.0 - springCurve);
    final scale = seed.startScale + (1.0 - seed.startScale) * springCurve;
    final iconFade = (entranceT / 0.16).clamp(0.0, 1.0);
    final labelFade = ((localT - 0.55) / 0.45).clamp(0.0, 1.0);

    return Transform.translate(
      offset: Offset(dx, dy),
      child: Transform.rotate(
        angle: angle,
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: iconFade,
            child: _ResourceTileButton(
              key: ValueKey('add-lib-tile-${tile.id.name}'),
              tile: tile,
              ambientCtrl: _ambientCtrl,
              ambientPhase: seed.ambientPhase,
              labelOpacity: labelFade,
              labelColor: palette.labelPrimary,
              onTap: () => unawaited(_handleTileTap(tile.id)),
            ),
          ),
        ),
      ),
    );
  }
}

class _FormFieldSpec {
  final String key;
  final String label;
  final String placeholder;
  final bool obscure;

  const _FormFieldSpec(
    this.key,
    this.label,
    this.placeholder, {
    this.obscure = false,
  });
}

class _ResourceTileButton extends StatefulWidget {
  final _LibraryTileSpec tile;
  final AnimationController ambientCtrl;
  final double ambientPhase;
  final double labelOpacity;
  final Color labelColor;
  final VoidCallback onTap;

  const _ResourceTileButton({
    super.key,
    required this.tile,
    required this.ambientCtrl,
    required this.ambientPhase,
    required this.labelOpacity,
    required this.labelColor,
    required this.onTap,
  });

  @override
  State<_ResourceTileButton> createState() => _ResourceTileButtonState();
}

class _ResourceTileButtonState extends State<_ResourceTileButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.88 : 1.0,
        duration: reduceMotion
            ? const Duration(milliseconds: 80)
            : const Duration(milliseconds: 220),
        curve: Ios27Spring.bouncy.curve,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: widget.ambientCtrl,
              builder: (context, _) {
                final theta =
                    widget.ambientCtrl.value * math.pi * 2 + widget.ambientPhase;
                final bobY = reduceMotion ? 0.0 : math.sin(theta) * 1.8;
                final pulse = reduceMotion ? 0.5 : (math.sin(theta) + 1.0) * 0.5;
                return Transform.translate(
                  offset: Offset(0, bobY),
                  child: SizedBox(
                    width: 60,
                    height: 60,
                    child: CustomPaint(
                      painter: _LibraryIconPainter(
                        id: widget.tile.id,
                        pulse: pulse,
                        isDark: ApplePalette.isDarkOf(context),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Opacity(
              opacity: widget.labelOpacity,
              child: Text(
                widget.tile.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.labelColor,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bespoke animated vector icon painter matching Rex's crisp 3D translucent
/// folder-cloud emblems, Emby diamond, Jellyfin gradient triangle, Plex badge,
/// and cloud drive / subscription icons.
class _LibraryIconPainter extends CustomPainter {
  final _LibraryTileId id;
  final double pulse;
  final bool isDark;

  const _LibraryIconPainter({
    required this.id,
    required this.pulse,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    switch (id) {
      case _LibraryTileId.webdav:
        _paintCloudFolder(
          canvas,
          size,
          topCloud: const Color(0xFF9FE3FF),
          folderTop: const Color(0xFF3CB4FF),
          folderBottom: const Color(0xFF007AFF),
          glyph: 'DAV',
        );
        break;
      case _LibraryTileId.smb:
        _paintCloudFolder(
          canvas,
          size,
          topCloud: const Color(0xFFB5E8FF),
          folderTop: const Color(0xFF2EA7FF),
          folderBottom: const Color(0xFF0A66E8),
          glyph: 'SMB',
        );
        break;
      case _LibraryTileId.localDevice:
        _paintCloudFolder(
          canvas,
          size,
          topCloud: const Color(0xFFA7F3D0),
          folderTop: const Color(0xFF38BDF8),
          folderBottom: const Color(0xFF0284C7),
          glyph: 'iOS',
        );
        break;
      case _LibraryTileId.localPack:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFFFFB340), Color(0xFFF97316)],
        );
        _paintZipGlyph(canvas, size);
        break;
      case _LibraryTileId.emby:
        _paintEmbyIcon(canvas, size);
        break;
      case _LibraryTileId.jellyfin:
        _paintJellyfinIcon(canvas, size);
        break;
      case _LibraryTileId.plex:
        _paintPlexIcon(canvas, size);
        break;
      case _LibraryTileId.alistNas:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFF38BDF8), Color(0xFF1D4ED8)],
        );
        _paintServerRackGlyph(canvas, size);
        break;
      case _LibraryTileId.manualInput:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFF4F8BFF), Color(0xFF2563EB)],
        );
        _paintLinkGlyph(canvas, size);
        break;
      case _LibraryTileId.clipboardQuick:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFF34D399), Color(0xFF059669)],
        );
        _paintClipboardGlyph(canvas, size);
        break;
      case _LibraryTileId.configCenter:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFF818CF8), Color(0xFF4F46E5)],
        );
        _paintQrCenterGlyph(canvas, size);
        break;
      case _LibraryTileId.quarkDrive:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFF38BDF8), Color(0xFF2563EB)],
        );
        _paintQuarkOrbitGlyph(canvas, size, w, h);
        break;
      case _LibraryTileId.ucDrive:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFFFF9500), Color(0xFFFF5E00)],
        );
        _paintUcWaveGlyph(canvas, size);
        break;
      case _LibraryTileId.baiduDrive:
        _paintRoundedBadge(
          canvas,
          size,
          isDark
              ? const [Color(0xFFFFFFFF), Color(0xFFEFF3F8)]
              : const [Color(0xFFFFFFFF), Color(0xFFF3F6FB)],
          borderColor: Colors.black.withValues(alpha: 0.08),
        );
        _paintBaiduCloudGlyph(canvas, size);
        break;
      case _LibraryTileId.aliDrive:
        _paintRoundedBadge(
          canvas,
          size,
          const [Color(0xFF6366F1), Color(0xFF3B82F6)],
        );
        _paintAliRibbonGlyph(canvas, size);
        break;
    }
  }

  void _paintRoundedBadge(
    Canvas canvas,
    Size size,
    List<Color> colors, {
    Color? borderColor,
  }) {
    final rect = Rect.fromLTWH(4, 4, size.width - 8, size.height - 8);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(14));
    canvas.drawShadow(
      Path()..addRRect(rrect),
      colors.last.withValues(alpha: 0.30),
      6,
      false,
    );
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
    // Subtle animated specular sheen
    final sheenPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment(-1.0 + pulse * 0.6, -1.0),
        end: Alignment(0.5 + pulse * 0.6, 0.8),
        colors: [
          Colors.white.withValues(alpha: 0.28),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, sheenPaint);
    if (borderColor != null) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = borderColor,
      );
    }
  }

  void _paintCloudFolder(
    Canvas canvas,
    Size size, {
    required Color topCloud,
    required Color folderTop,
    required Color folderBottom,
    required String glyph,
  }) {
    final w = size.width;
    final h = size.height;
    // Soft translucent cloud silhouette behind the folder (Rex style)
    final cloudPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          topCloud.withValues(alpha: 0.92),
          folderTop.withValues(alpha: 0.62),
        ],
      ).createShader(Rect.fromLTWH(4, 6, w - 8, h * 0.65));
    final cloudY = 2.0 - pulse * 1.4;
    canvas.drawCircle(Offset(w * 0.50, h * 0.34 + cloudY), w * 0.24, cloudPaint);
    canvas.drawCircle(Offset(w * 0.26, h * 0.44 + cloudY), w * 0.16, cloudPaint);
    canvas.drawCircle(Offset(w * 0.74, h * 0.44 + cloudY), w * 0.16, cloudPaint);

    // Front glossy 3D folder body
    final folderRect = Rect.fromLTWH(w * 0.15, h * 0.40, w * 0.70, h * 0.46);
    final folderRRect =
        RRect.fromRectAndRadius(folderRect, const Radius.circular(8.5));
    canvas.drawShadow(
      Path()..addRRect(folderRRect),
      folderBottom.withValues(alpha: 0.34),
      5,
      false,
    );
    final folderPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [folderTop, folderBottom],
      ).createShader(folderRect);
    canvas.drawRRect(folderRRect, folderPaint);
    // Folder tab notch
    final tabRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.18, h * 0.34, w * 0.27, h * 0.11),
      const Radius.circular(4),
    );
    canvas.drawRRect(tabRRect, Paint()..color = folderTop);
    // Subtle top highlight stripe
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.21, h * 0.47, w * 0.58, 2.2),
        const Radius.circular(2),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.42 + pulse * 0.18),
    );
    // Crisp protocol micro-tag
    final tp = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.92),
          fontSize: 9.2,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((w - tp.width) * 0.5, folderRect.top + (folderRect.height - tp.height) * 0.58),
    );
  }

  void _paintEmbyIcon(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final r = size.width * 0.39;
    final diamond = Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r, cy)
      ..lineTo(cx, cy + r)
      ..lineTo(cx - r, cy)
      ..close();
    canvas.drawShadow(diamond, const Color(0x6652B54B), 6, false);
    canvas.drawPath(
      diamond,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF66D15C), Color(0xFF3E9C38)],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r)),
    );
    // Crisp white play triangle pulsing subtly
    final s = 0.96 + pulse * 0.08;
    final play = Path()
      ..moveTo(cx - 5.5 * s, cy - 8.5 * s)
      ..lineTo(cx + 9.5 * s, cy)
      ..lineTo(cx - 5.5 * s, cy + 8.5 * s)
      ..close();
    canvas.drawPath(play, Paint()..color = Colors.white);
  }

  void _paintJellyfinIcon(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.52;
    final outer = Path()
      ..moveTo(cx, size.height * 0.14)
      ..cubicTo(
        size.width * 0.68,
        size.height * 0.14,
        size.width * 0.88,
        size.height * 0.66,
        size.width * 0.80,
        size.height * 0.78,
      )
      ..cubicTo(
        size.width * 0.72,
        size.height * 0.89,
        size.width * 0.28,
        size.height * 0.89,
        size.width * 0.20,
        size.height * 0.78,
      )
      ..cubicTo(
        size.width * 0.12,
        size.height * 0.66,
        size.width * 0.32,
        size.height * 0.14,
        cx,
        size.height * 0.14,
      )
      ..close();
    canvas.drawShadow(outer, const Color(0x55AA5CC3), 6, false);
    canvas.drawPath(
      outer,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-0.8 + pulse * 0.4, -1.0),
          end: Alignment(0.8, 1.0),
          colors: const [Color(0xFFAA5CC3), Color(0xFF00A4DC)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    final inner = Path()
      ..moveTo(cx, cy - 10)
      ..lineTo(cx + 10.5, cy + 8)
      ..lineTo(cx - 10.5, cy + 8)
      ..close();
    canvas.drawPath(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white.withValues(alpha: 0.92),
    );
  }

  void _paintPlexIcon(Canvas canvas, Size size) {
    _paintRoundedBadge(
      canvas,
      size,
      const [Color(0xFF1E1E24), Color(0xFF0A0A0E)],
    );
    final tp = TextPainter(
      text: const TextSpan(
        children: [
          TextSpan(
            text: 'ple',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          TextSpan(
            text: 'x',
            style: TextStyle(
              color: Color(0xFFE5A00D),
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(
        (size.width - tp.width) * 0.5,
        (size.height - tp.height) * 0.5,
      ),
    );
  }

  void _paintServerRackGlyph(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.94)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    for (final y in [19.0, 30.0, 41.0]) {
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(size.width * 0.5, y), width: 28, height: 8),
        const Radius.circular(3),
      );
      canvas.drawRRect(r, p);
      canvas.drawCircle(
        Offset(size.width * 0.5 + 8.5, y),
        1.6,
        Paint()
          ..color = Color.lerp(
            const Color(0xFF86EFAC),
            Colors.white,
            pulse,
          )!,
      );
    }
  }

  void _paintZipGlyph(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.5, size.height * 0.5),
        width: 24,
        height: 28,
      ),
      const Radius.circular(5),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.92)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );
    final teeth = Paint()..color = Colors.white;
    for (var i = 0; i < 4; i++) {
      final left = i.isEven ? -3.0 : 0.5;
      canvas.drawRect(
        Rect.fromLTWH(size.width * 0.5 + left, 20.0 + i * 5.0, 3.0, 3.0),
        teeth,
      );
    }
  }

  void _paintLinkGlyph(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round;
    canvas.save();
    canvas.translate(size.width * 0.5, size.height * 0.5);
    canvas.rotate(-math.pi / 4 + (pulse - 0.5) * 0.12);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-14, -5.5, 15, 11),
        const Radius.circular(5.5),
      ),
      p,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-1, -5.5, 15, 11),
        const Radius.circular(5.5),
      ),
      p,
    );
    canvas.restore();
  }

  void _paintClipboardGlyph(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width * 0.5, size.height * 0.54),
          width: 22,
          height: 26,
        ),
        const Radius.circular(4.5),
      ),
      p,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width * 0.5, size.height * 0.30),
          width: 11,
          height: 5,
        ),
        const Radius.circular(2.5),
      ),
      Paint()..color = Colors.white,
    );
    final lineP = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(24, 31), const Offset(36, 31), lineP);
    canvas.drawLine(const Offset(24, 37), const Offset(33, 37), lineP);
  }

  void _paintQrCenterGlyph(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;
    for (final pt in const [
      Offset(21, 21),
      Offset(39, 21),
      Offset(21, 39),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: pt, width: 10, height: 10),
          const Radius.circular(2.5),
        ),
        p,
      );
    }
    canvas.drawCircle(
      const Offset(39, 39),
      3.5 + pulse * 1.2,
      Paint()..color = Colors.white,
    );
  }

  void _paintQuarkOrbitGlyph(Canvas canvas, Size size, double w, double h) {
    final cx = w * 0.5;
    final cy = h * 0.5;
    canvas.drawCircle(
      Offset(cx, cy),
      8.5,
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    );
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(-0.45 + pulse * 0.25);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 34, height: 14),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.82)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );
    canvas.restore();
  }

  void _paintUcWaveGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final arcP = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: 13),
      -math.pi * 0.8 + pulse * 0.25,
      math.pi * 1.45,
      false,
      arcP,
    );
    canvas.drawCircle(
      Offset(cx + 2, cy),
      4.5,
      Paint()..color = Colors.white,
    );
  }

  void _paintBaiduCloudGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.53;
    final blueP = Paint()
      ..color = const Color(0xFF06A7FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2;
    final redP = Paint()
      ..color = const Color(0xFFFF4D6A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2;
    canvas.drawCircle(Offset(cx - 7.5, cy + 4.5), 7.5, blueP);
    canvas.drawCircle(Offset(cx + 7.5, cy + 4.5), 7.5, blueP);
    canvas.drawCircle(Offset(cx, cy - 6.5 - pulse * 1.0), 7.5, redP);
  }

  void _paintAliRibbonGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(cx, cy - 13)
      ..lineTo(cx + 13, cy + 10)
      ..lineTo(cx - 13, cy + 10)
      ..close();
    canvas.drawPath(path, p);
    canvas.drawCircle(
      Offset(cx, cy + 2),
      3.0 + pulse * 0.8,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _LibraryIconPainter oldDelegate) =>
      oldDelegate.id != id ||
      (oldDelegate.pulse - pulse).abs() > 0.01 ||
      oldDelegate.isDark != isDark;
}
