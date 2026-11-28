import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, Uint8List, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/cms_client.dart';
import '../core/cms_parser.dart';
import '../core/csp_bridge.dart';
import '../core/emby_library.dart';
import '../core/media_library_connectors.dart';
import '../core/models.dart';
import '../core/ohos_runtime.dart';
import '../core/personal_netdisk_library.dart';
import '../core/storage_service.dart';
import 'apple_theme.dart';
import 'ios_settings.dart';
import 'motion/ios27_springs.dart';
import 'personal_netdisk_picker_page.dart';

/// Computes the responsive column count for the Add Resource Library grid:
/// - Narrow phone / large Dynamic Type / narrow iPad Split View: 2 columns
/// - Standard iPhone: 3 columns
/// - Wide / iPad: 4 columns
int computeAddLibraryColumnCount({
  required double availableWidth,
  required double textScale,
}) {
  final safeScale = math.max(1.0, textScale);
  final effectiveWidth = availableWidth / safeScale;
  if (availableWidth < 330 || effectiveWidth < 280) return 2;
  if (availableWidth < 540 || effectiveWidth < 460) return 3;
  return 4;
}

/// Maximum width of the iOS / iPadOS icon grid content so icons never drift
/// far apart on a wide iPad canvas (content is centered with symmetric
/// margins beyond this width).
const double kIosAddLibraryMaxContentWidth = 640.0;

/// iOS / iPadOS Home-Screen-style column count for the Add Resource Library
/// icon grid ([availableWidth] is the grid content width):
/// - iPhone portrait (320–440pt): 4 columns
/// - Narrow iPad Split View / Slide Over: 5 columns
/// - iPad / landscape: 6 columns
/// - Very large Dynamic Type on narrow widths: 3 columns
int computeIosAddLibraryColumnCount({
  required double availableWidth,
  required double textScale,
}) {
  final safeScale = math.max(1.0, textScale);
  if (availableWidth / safeScale < 200) return 3;
  if (availableWidth < 460) return 4;
  if (availableWidth < 580) return 5;
  return 6;
}

/// App-icon edge length for a grid cell of [cellWidth] (60pt on a standard
/// iPhone, 52pt minimum on 320pt devices, 64pt maximum on iPad).
double iosAddLibraryIconSize(double cellWidth) =>
    (cellWidth * 0.68).clamp(52.0, 64.0).floorToDouble();

/// Continuous-corner (superellipse) app-icon outline matching Apple's
/// first-party icon silhouette.
Path buildIosAppIconSquircle(Rect rect, {double exponent = 5.0}) {
  final path = Path();
  final cx = rect.center.dx;
  final cy = rect.center.dy;
  final a = rect.width / 2;
  final b = rect.height / 2;
  const segments = 180;
  final e = 2 / exponent;
  for (var i = 0; i < segments; i++) {
    final t = i / segments * 2 * math.pi;
    final c = math.cos(t);
    final s = math.sin(t);
    final x = cx + a * c.sign * math.pow(c.abs(), e);
    final y = cy + b * s.sign * math.pow(s.abs(), e);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path..close();
}

enum _LibraryTileId {
  emby,
  jellyfin,
  plex,
  webdav,
  smb,
  alistNas,
  quarkDrive,
  ucDrive,
  baiduDrive,
  aliDrive,
  localDevice,
  manualInput,
  localPack,
}

class _LibraryTileSpec {
  final _LibraryTileId id;
  final String label;

  const _LibraryTileSpec({
    required this.id,
    required this.label,
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

/// Reorganized "添加资源库" hub with four clear aligned sections (Media Servers,
/// Network Storage, Personal Cloud Drives, Local & Subscriptions), zero scatter
/// animation, and real end-to-end verified connectors.
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
  final void Function(String title, String message)? onImportNotice;
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
    this.onImportNotice,
    this.onNeedsPrivacyPassword,
  });

  @override
  State<AddResourceLibraryView> createState() => _AddResourceLibraryViewState();
}

class _AddResourceLibraryViewState extends State<AddResourceLibraryView> {
  static const List<_LibrarySectionSpec> _sections = <_LibrarySectionSpec>[
    _LibrarySectionSpec(
      title: '媒体服务器',
      tiles: [
        _LibraryTileSpec(id: _LibraryTileId.emby, label: 'Emby'),
        _LibraryTileSpec(id: _LibraryTileId.jellyfin, label: 'Jellyfin'),
        _LibraryTileSpec(id: _LibraryTileId.plex, label: 'Plex'),
      ],
    ),
    _LibrarySectionSpec(
      title: '网络存储',
      tiles: [
        _LibraryTileSpec(id: _LibraryTileId.webdav, label: 'WebDAV'),
        _LibraryTileSpec(id: _LibraryTileId.smb, label: 'SMB'),
        _LibraryTileSpec(id: _LibraryTileId.alistNas, label: 'AList / OpenList'),
      ],
    ),
    _LibrarySectionSpec(
      title: '个人网盘',
      tiles: [
        _LibraryTileSpec(id: _LibraryTileId.quarkDrive, label: '夸克'),
        _LibraryTileSpec(id: _LibraryTileId.ucDrive, label: 'UC'),
        _LibraryTileSpec(id: _LibraryTileId.baiduDrive, label: '百度'),
        _LibraryTileSpec(id: _LibraryTileId.aliDrive, label: '阿里'),
      ],
    ),
    _LibrarySectionSpec(
      title: '本机与订阅',
      tiles: [
        _LibraryTileSpec(id: _LibraryTileId.localDevice, label: '当前设备'),
        _LibraryTileSpec(id: _LibraryTileId.manualInput, label: '手动输入'),
        _LibraryTileSpec(id: _LibraryTileId.localPack, label: '本地配置包'),
      ],
    ),
  ];

  bool _busy = false;
  _LibraryTileId? _busyTileId;
  int? _noticeSectionIndex;
  String? _bannerNotice;
  bool _bannerIsError = false;
  bool _openedInitialManual = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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

  String _cleanErrorText(Object error) {
    return error
        .toString()
        .replaceFirst(RegExp(r'^(?:Exception|FormatException|StateError):\s*'), '')
        .trim();
  }

  void _setNotice(
    String msg, {
    bool isError = false,
    int? sectionIndex,
  }) {
    if (!mounted) return;
    setState(() {
      _bannerNotice = msg;
      _bannerIsError = isError;
      _noticeSectionIndex = sectionIndex;
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
      case _LibraryTileId.quarkDrive:
        await _openPersonalNetdiskPicker(PersonalCloudProvider.quark);
        return;
      case _LibraryTileId.ucDrive:
        await _openPersonalNetdiskPicker(PersonalCloudProvider.uc);
        return;
      case _LibraryTileId.baiduDrive:
        await _openPersonalNetdiskPicker(PersonalCloudProvider.baidu);
        return;
      case _LibraryTileId.aliDrive:
        await _openPersonalNetdiskPicker(PersonalCloudProvider.ali);
        return;
      case _LibraryTileId.emby:
        final added = await showEmbyLibraryFormPage(
          context: context,
          storage: widget.storage,
          initialGroup: widget.initialGroup,
          initialIsPrivate: widget.initialIsPrivate,
          backLabel: '添加资源库',
          onSaved: widget.onLibraryAdded,
          onNeedsPrivacyPassword: widget.onNeedsPrivacyPassword,
        );
        if (added && mounted) {
          Navigator.of(context).pop();
        }
        return;
      case _LibraryTileId.jellyfin:
        await _openEmbyFamilyForm(
          title: '连接 Jellyfin 媒体库',
          accentColor: const Color(0xFF7B61FF),
          defaultPort: '8096',
          onConnect: (address, user, pass, label, group, isPriv) =>
              JellyfinLibrary.login(
            address,
            user,
            pass,
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
          title: '添加 AList / OpenList 资源库',
          accentColor: const Color(0xFF0EA5E9),
          addressHint: 'http://nas.example:5244',
          fields: const [
            _FormFieldSpec('address', 'AList / OpenList 地址', 'http://nas.example:5244'),
            _FormFieldSpec('root', '起始目录（可选）', '/'),
            _FormFieldSpec('user', '账号（公开站可留空）', 'admin'),
            _FormFieldSpec('pass', '密码（公开站可留空）', '填写登录密码', obscure: true),
            _FormFieldSpec('label', '显示名称（可选）', '如：家庭 OpenList'),
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
          title: '添加 SMB 共享资源库',
          accentColor: const Color(0xFF2563EB),
          addressHint: 'nas.example',
          fields: const [
            _FormFieldSpec('host', '主机 IP 或域名', '如：nas.example 或局域网主机 IP'),
            _FormFieldSpec('share', '共享目录名', '如：Movies 或 Video'),
            _FormFieldSpec('port', '端口（默认 445）', '445'),
            _FormFieldSpec('user', '用户名（访客可留空）', 'SMB 登录账号'),
            _FormFieldSpec('pass', '密码（访客可留空）', 'SMB 登录密码', obscure: true),
            _FormFieldSpec(
              'webdav',
              '伴随 WebDAV 地址（可选，留空即使用纯 SMB 直连）',
              'https://dav.example:5006/Movies/',
            ),
          ],
          onConnect: (values, group, isPriv) => SmbNasLibrary.configure(
            host: values['host'] ?? '',
            port: int.tryParse((values['port'] ?? '').trim()) ?? 445,
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

  Future<void> _openPersonalNetdiskPicker(
    PersonalCloudProvider provider,
  ) async {
    final saved =
        await Navigator.of(context).push<({SubscriptionEntry entry, bool updatedExisting})>(
      buildApplePageRoute<({SubscriptionEntry entry, bool updatedExisting})>(
        builder: (_) => PersonalNetdiskPickerPage(
          provider: provider,
          storage: widget.storage,
          group: widget.initialGroup,
          isPrivate: widget.initialIsPrivate,
          onLibrarySaved: (_) {
            widget.onLibraryAdded();
          },
        ),
      ),
    );
    if (saved != null && mounted) {
      if (widget.initialIsPrivate && !widget.storage.hasPrivacyPassword) {
        await widget.onNeedsPrivacyPassword?.call();
      }
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _handlePickLocalPack() async {
    setState(() {
      _busy = true;
      _busyTileId = _LibraryTileId.localPack;
      _bannerNotice = null;
    });
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
      _setNotice('读取本地配置包失败：$e', isError: true, sectionIndex: 3);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyTileId = null;
        });
      }
    }
  }

  Future<void> _handlePickLocalVideos() async {
    setState(() {
      _busy = true;
      _busyTileId = _LibraryTileId.localDevice;
      _bannerNotice = null;
    });
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
      _setNotice('导入本机影片失败：$e', isError: true, sectionIndex: 3);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyTileId = null;
        });
      }
    }
  }

  Future<void> _openEmbyFamilyForm({
    required String title,
    required Color accentColor,
    required String defaultPort,
    required Future<SubscriptionEntry> Function(
      String address,
      String user,
      String pass,
      String label,
      String group,
      bool isPrivate,
    )
    onConnect,
  }) async {
    bool useHttps = false;
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: defaultPort);
    final pathCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
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
                Text(
                  '协议与连接方式',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                CupertinoSlidingSegmentedControl<bool>(
                  groupValue: useHttps,
                  children: const {
                    false: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text('HTTP（默认 8096）'),
                    ),
                    true: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text('HTTPS（443 / 8920）'),
                    ),
                  },
                  onValueChanged: (v) {
                    if (v == null) return;
                    setModalState(() {
                      useHttps = v;
                      final p = portCtrl.text.trim();
                      if (useHttps && p == defaultPort) {
                        portCtrl.text = '';
                      } else if (!useHttps && p.isEmpty) {
                        portCtrl.text = defaultPort;
                      }
                    });
                  },
                ),
                const SizedBox(height: 14),
                Text(
                  '服务器地址',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _buildStyledInput(
                  ctx,
                  controller: hostCtrl,
                  placeholder: '域名或 IP（如 emby.example），也支持直接粘贴完整网址',
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '端口号（选填）',
                            style: TextStyle(
                              color: palette.labelSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _buildStyledInput(
                            ctx,
                            controller: portCtrl,
                            placeholder: useHttps ? '默认 443' : '默认 $defaultPort',
                            keyboardType: TextInputType.number,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '路径（选填）',
                            style: TextStyle(
                              color: palette.labelSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _buildStyledInput(
                            ctx,
                            controller: pathCtrl,
                            placeholder: '选填（如 /path）',
                            keyboardType: TextInputType.url,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  '名称（选填）',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _buildStyledInput(
                  ctx,
                  controller: nameCtrl,
                  placeholder: '选填，留空自动识别媒体库名称',
                ),
                const SizedBox(height: 14),
                Text(
                  '用户名',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _buildStyledInput(
                  ctx,
                  controller: userCtrl,
                  placeholder: '填写登录用户名',
                ),
                const SizedBox(height: 14),
                Text(
                  '密码（可留空）',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                _buildStyledInput(
                  ctx,
                  controller: passCtrl,
                  placeholder: '填写登录密码',
                  obscure: true,
                ),
                const SizedBox(height: 14),
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
                              final composed = EmbyLibrary.composeServerAddress(
                                useHttps: useHttps,
                                hostOrUrl: hostCtrl.text,
                                port: portCtrl.text,
                                path: pathCtrl.text,
                              );
                              final group = groupCtrl.text.trim().isEmpty
                                  ? '默认分组'
                                  : groupCtrl.text.trim();
                              final entry = await onConnect(
                                composed,
                                userCtrl.text.trim(),
                                passCtrl.text,
                                nameCtrl.text.trim(),
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
                                final detail = _cleanErrorText(e);
                                setModalState(() {
                                  busy = false;
                                  error = '连接失败：$detail（已有资源库不受影响，请检查地址或凭据后重试）';
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
    hostCtrl.dispose();
    portCtrl.dispose();
    pathCtrl.dispose();
    nameCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    groupCtrl.dispose();
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
                                final detail = _cleanErrorText(e);
                                setModalState(() {
                                  busy = false;
                                  error = '连接失败：$detail（已有资源库不受影响，请检查地址或凭据后重试）';
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
              final limitation = (!kIsWeb && !Platform.isAndroid)
                  ? CspBridge.buildSubscriptionRuntimeLimitationNotice(entries)
                  : null;
              if (ctx.mounted) Navigator.of(ctx).pop();
              widget.onLibraryAdded();
              if (effectivePrivate && !widget.storage.hasPrivacyPassword) {
                await widget.onNeedsPrivacyPassword?.call();
              }
              if (mounted) Navigator.of(context).pop();
              if (limitation != null) {
                widget.onImportNotice?.call(
                  limitation.title,
                  limitation.message,
                );
              }
            } catch (e) {
              if (ctx.mounted) {
                final detail = _cleanErrorText(e);
                setModalState(() {
                  submitting = false;
                  errorText = '导入失败：$detail（已有订阅不受影响，请修正内容后重试）';
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
                Text(
                  '订阅地址（每行一个，支持 JSON / 多仓 / M3U）',
                  style: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
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

  /// The icon-first Home-Screen-style hub is iOS / iPadOS only; Windows,
  /// HarmonyOS and Android keep the previous card grid unchanged.
  static bool get _useIosLibraryDesign =>
      !kIsWeb &&
      !OhosRuntime.isOhos &&
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    if (_useIosLibraryDesign) return _buildIosHub(context);
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    return SingleChildScrollView(
      key: const ValueKey('add-resource-library-hub'),
      padding: EdgeInsets.fromLTRB(16, 8, 16, safeBottom + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_bannerNotice != null && _noticeSectionIndex == null) ...[
            _buildInlineNoticeBanner(),
            const SizedBox(height: 12),
          ],
          for (var sIdx = 0; sIdx < _sections.length; sIdx++) ...[
            _buildSectionBlock(context, _sections[sIdx], sectionIndex: sIdx),
            if (_bannerNotice != null && _noticeSectionIndex == sIdx) ...[
              const SizedBox(height: 8),
              _buildInlineNoticeBanner(),
            ],
            if (sIdx < _sections.length - 1) const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  Widget _buildIosHub(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    return SingleChildScrollView(
      key: const ValueKey('add-resource-library-hub'),
      padding: EdgeInsets.only(top: 10, bottom: safeBottom + 32),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewWidth = constraints.maxWidth;
          final hPad = viewWidth < 360 ? 14.0 : 18.0;
          final contentWidth = math.max(
            0.0,
            math.min(viewWidth - hPad * 2, kIosAddLibraryMaxContentWidth),
          );
          return Center(
            child: SizedBox(
              width: contentWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_bannerNotice != null && _noticeSectionIndex == null) ...[
                    _buildInlineNoticeBanner(),
                    const SizedBox(height: 16),
                  ],
                  for (var sIdx = 0; sIdx < _sections.length; sIdx++) ...[
                    _buildIosSection(
                      context,
                      _sections[sIdx],
                      sectionIndex: sIdx,
                      width: contentWidth,
                    ),
                    if (_bannerNotice != null && _noticeSectionIndex == sIdx) ...[
                      const SizedBox(height: 12),
                      _buildInlineNoticeBanner(),
                    ],
                    if (sIdx < _sections.length - 1) const SizedBox(height: 28),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildIosSection(
    BuildContext context,
    _LibrarySectionSpec section, {
    required int sectionIndex,
    required double width,
  }) {
    final palette = ApplePalette.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14.0) / 14.0;
    final cols = computeIosAddLibraryColumnCount(
      availableWidth: width,
      textScale: textScale,
    );
    final cellWidth = width / cols;
    final iconSize = iosAddLibraryIconSize(cellWidth);
    // Header aligns with the left edge of the first icon (not the cell), so
    // the title reads as part of the icon grid like the iOS App Library.
    final headerInset = math.max(0.0, (cellWidth - iconSize) / 2);
    final rowCount = (section.tiles.length / cols).ceil();
    return Column(
      key: ValueKey('add-lib-section-$sectionIndex'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(headerInset, 0, headerInset, 12),
          child: Semantics(
            header: true,
            child: Text(
              section.title,
              style: TextStyle(
                color: palette.labelSecondary,
                fontSize: 13,
                height: 1.25,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.08,
              ),
            ),
          ),
        ),
        Column(
          key: ValueKey('add-lib-section-$sectionIndex-cols-$cols'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var r = 0; r < rowCount; r++) ...[
              if (r > 0) const SizedBox(height: 18),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < cols; c++)
                    Expanded(
                      child: (r * cols + c) < section.tiles.length
                          ? _IosLibraryIconTile(
                              key: ValueKey(
                                'add-lib-tile-${section.tiles[r * cols + c].id.name}',
                              ),
                              tile: section.tiles[r * cols + c],
                              iconSize: iconSize,
                              labelColor: palette.labelPrimary,
                              busy: _busyTileId == section.tiles[r * cols + c].id,
                              onTap: () => unawaited(
                                _handleTileTap(section.tiles[r * cols + c].id),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildInlineNoticeBanner() {
    return Container(
      key: const ValueKey('add-lib-inline-notice'),
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
        _bannerNotice ?? '',
        style: TextStyle(
          color:
              _bannerIsError ? AppleColors.systemRed : AppleColors.systemGreen,
          fontSize: 13,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _buildSectionBlock(
    BuildContext context,
    _LibrarySectionSpec section, {
    required int sectionIndex,
  }) {
    final palette = ApplePalette.of(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14.0) / 14.0;
    return Column(
      key: ValueKey('add-lib-section-$sectionIndex'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Text(
            section.title,
            style: TextStyle(
              color: palette.labelSecondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = computeAddLibraryColumnCount(
              availableWidth: constraints.maxWidth,
              textScale: textScale,
            );
            const colGap = 12.0;
            const rowGap = 10.0;
            final rowCount = (section.tiles.length / cols).ceil();
            return Column(
              key: ValueKey('add-lib-section-$sectionIndex-cols-$cols'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var r = 0; r < rowCount; r++) ...[
                  if (r > 0) const SizedBox(height: rowGap),
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var c = 0; c < cols; c++) ...[
                          if (c > 0) const SizedBox(width: colGap),
                          Expanded(
                            child: (r * cols + c) < section.tiles.length
                                ? _LegacyResourceTileButton(
                                    key: ValueKey(
                                      'add-lib-tile-${section.tiles[r * cols + c].id.name}',
                                    ),
                                    tile: section.tiles[r * cols + c],
                                    labelColor: palette.labelPrimary,
                                    busy: _busyTileId ==
                                        section.tiles[r * cols + c].id,
                                    onTap: () => unawaited(
                                      _handleTileTap(
                                        section.tiles[r * cols + c].id,
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ],
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

class _LegacyResourceTileButton extends StatefulWidget {
  final _LibraryTileSpec tile;
  final Color labelColor;
  final bool busy;
  final VoidCallback onTap;

  const _LegacyResourceTileButton({
    super.key,
    required this.tile,
    required this.labelColor,
    required this.busy,
    required this.onTap,
  });

  @override
  State<_LegacyResourceTileButton> createState() =>
      _LegacyResourceTileButtonState();
}

class _LegacyResourceTileButtonState extends State<_LegacyResourceTileButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final isDark = ApplePalette.isDarkOf(context);
    final cardFill = isDark
        ? (_pressed ? const Color(0xFF28282C) : const Color(0xFF1C1C1F))
        : (_pressed ? const Color(0xFFF1F3F8) : Colors.white);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.055);
    return Semantics(
      button: true,
      label: widget.tile.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: reduceMotion
              ? const Duration(milliseconds: 60)
              : const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 88),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: cardFill,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: cardBorder, width: 0.65),
              boxShadow: isDark
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      key: ValueKey('add-lib-icon-${widget.tile.id.name}'),
                      width: 54,
                      height: 54,
                      child: CustomPaint(
                        painter: _LegacyLibraryIconPainter(
                          id: widget.tile.id,
                          isDark: isDark,
                          fontFamily:
                              DefaultTextStyle.of(context).style.fontFamily,
                        ),
                      ),
                    ),
                    if (widget.busy)
                      Container(
                        width: 49,
                        height: 49,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.36),
                          borderRadius: BorderRadius.circular(13.0),
                        ),
                        child: const Center(
                          child: CupertinoActivityIndicator(
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  widget.tile.label,
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: widget.labelColor,
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
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

/// Legacy (Windows / HarmonyOS / Android) squircle icon set: every resource
/// library shares identical squircle geometry, gradient depth, specular sheen,
/// inner rim, and vector stroke language, while each service has a distinct
/// color palette and unique geometric emblem so no two icons look alike.
class _LegacyLibraryIconPainter extends CustomPainter {
  final _LibraryTileId id;
  final bool isDark;
  final String? fontFamily;

  const _LegacyLibraryIconPainter({
    required this.id,
    required this.isDark,
    this.fontFamily,
  });

  @override
  void paint(Canvas canvas, Size size) {
    switch (id) {
      case _LibraryTileId.emby:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF4ADE80), Color(0xFF16A34A)],
        );
        _paintEmbyDiamondPlayGlyph(canvas, size);
        break;
      case _LibraryTileId.jellyfin:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFFA855F7), Color(0xFF6D28D9)],
        );
        _paintJellyfinPrismGlyph(canvas, size);
        break;
      case _LibraryTileId.plex:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF323540), Color(0xFF14151A)],
        );
        _paintPlexChevronGlyph(canvas, size);
        break;
      case _LibraryTileId.webdav:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF38BDF8), Color(0xFF0284C7)],
        );
        _paintWebDavGlobeGlyph(canvas, size);
        break;
      case _LibraryTileId.smb:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF4F46E5), Color(0xFF1E3A8A)],
        );
        _paintSmbLanShareGlyph(canvas, size);
        break;
      case _LibraryTileId.alistNas:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF2DD4BF), Color(0xFF0F766E)],
        );
        _paintServerRackGlyph(canvas, size);
        break;
      case _LibraryTileId.quarkDrive:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF60A5FA), Color(0xFF2563EB)],
        );
        _paintQuarkOrbitGlyph(canvas, size);
        break;
      case _LibraryTileId.ucDrive:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFFFB923C), Color(0xFFEA580C)],
        );
        _paintUcWaveGlyph(canvas, size);
        break;
      case _LibraryTileId.baiduDrive:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFFFB7185), Color(0xFFE11D48)],
        );
        _paintBaiduTrefoilGlyph(canvas, size);
        break;
      case _LibraryTileId.aliDrive:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF818CF8), Color(0xFF4338CA)],
        );
        _paintAliCloudWingGlyph(canvas, size);
        break;
      case _LibraryTileId.localDevice:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFF34D399), Color(0xFF059669)],
        );
        _paintLocalDeviceGlyph(canvas, size);
        break;
      case _LibraryTileId.manualInput:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFFE879F9), Color(0xFFA21CAF)],
        );
        _paintLinkGlyph(canvas, size);
        break;
      case _LibraryTileId.localPack:
        _paintUniformSquircle(
          canvas,
          size,
          const [Color(0xFFFBBF24), Color(0xFFD97706)],
        );
        _paintZipGlyph(canvas, size);
        break;
    }
  }

  void _paintUniformSquircle(
    Canvas canvas,
    Size size,
    List<Color> colors,
  ) {
    final rect = Rect.fromLTWH(3, 3, size.width - 6, size.height - 6);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(14.5));
    canvas.drawShadow(
      Path()..addRRect(rrect),
      colors.last.withValues(alpha: isDark ? 0.42 : 0.28),
      5.5,
      false,
    );
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(rect);
    canvas.drawRRect(rrect, fillPaint);

    // Unified subtle top-left glass specular sheen
    final sheenPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: const Alignment(0.65, 0.75),
        colors: [
          Colors.white.withValues(alpha: 0.26),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, sheenPaint);

    // Unified crisp inner rim highlight
    final rimRect = rect.deflate(0.45);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rimRect, const Radius.circular(14.0)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = Colors.white.withValues(alpha: 0.22),
    );
  }

  Paint _strokePaint({double width = 2.4, Color color = Colors.white}) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  void _paintEmbyDiamondPlayGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    const r = 14.5;
    final diamond = Path()
      ..moveTo(cx, cy - r)
      ..lineTo(cx + r, cy)
      ..lineTo(cx, cy + r)
      ..lineTo(cx - r, cy)
      ..close();
    canvas.drawPath(
      diamond,
      Paint()..color = Colors.white.withValues(alpha: 0.16),
    );
    canvas.drawPath(diamond, _strokePaint(width: 2.3));
    final play = Path()
      ..moveTo(cx - 3.6, cy - 5.6)
      ..lineTo(cx + 6.4, cy)
      ..lineTo(cx - 3.6, cy + 5.6)
      ..close();
    canvas.drawPath(play, Paint()..color = Colors.white);
  }

  void _paintJellyfinPrismGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.51;
    final outer = Path()
      ..moveTo(cx, cy - 13.5)
      ..cubicTo(cx + 6.5, cy - 13.5, cx + 15.5, cy + 4.5, cx + 12.2, cy + 9.5)
      ..cubicTo(cx + 9.0, cy + 14.2, cx - 9.0, cy + 14.2, cx - 12.2, cy + 9.5)
      ..cubicTo(cx - 15.5, cy + 4.5, cx - 6.5, cy - 13.5, cx, cy - 13.5)
      ..close();
    canvas.drawPath(
      outer,
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );
    canvas.drawPath(outer, _strokePaint(width: 2.3));
    final inner = Path()
      ..moveTo(cx, cy - 5.2)
      ..lineTo(cx + 5.8, cy + 5.2)
      ..lineTo(cx - 5.8, cy + 5.2)
      ..close();
    canvas.drawPath(inner, Paint()..color = Colors.white);
  }

  void _paintPlexChevronGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final chevron = Path()
      ..moveTo(cx - 8.0, cy - 12.0)
      ..lineTo(cx - 0.5, cy - 12.0)
      ..lineTo(cx + 9.5, cy)
      ..lineTo(cx - 0.5, cy + 12.0)
      ..lineTo(cx - 8.0, cy + 12.0)
      ..lineTo(cx + 2.0, cy)
      ..close();
    canvas.drawPath(
      chevron,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFCD34D), Color(0xFFE5A00D)],
        ).createShader(
          Rect.fromCenter(center: Offset(cx, cy), width: 22, height: 26),
        ),
    );
  }

  void _paintWebDavGlobeGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    const r = 13.2;
    final stroke = _strokePaint(width: 2.1);
    canvas.drawCircle(Offset(cx, cy), r, stroke);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: r * 1.05, height: r * 2.0),
      stroke,
    );
    canvas.drawLine(
      Offset(cx - r + 1.2, cy - 4.4),
      Offset(cx + r - 1.2, cy - 4.4),
      stroke,
    );
    canvas.drawLine(
      Offset(cx - r + 1.2, cy + 4.4),
      Offset(cx + r - 1.2, cy + 4.4),
      stroke,
    );
  }

  void _paintSmbLanShareGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final stroke = _strokePaint(width: 2.2);
    // Shared folder body above a 3-node LAN bus
    final folder = Path()
      ..moveTo(cx - 12.0, cy - 10.5)
      ..lineTo(cx - 3.5, cy - 10.5)
      ..lineTo(cx - 0.8, cy - 7.5)
      ..lineTo(cx + 12.0, cy - 7.5)
      ..lineTo(cx + 12.0, cy + 3.5)
      ..lineTo(cx - 12.0, cy + 3.5)
      ..close();
    canvas.drawPath(
      folder,
      Paint()..color = Colors.white.withValues(alpha: 0.20),
    );
    canvas.drawPath(folder, stroke);
    // Vertical stem + LAN horizontal bus
    canvas.drawLine(Offset(cx, cy + 3.5), Offset(cx, cy + 10.5), stroke);
    canvas.drawLine(
      Offset(cx - 11.5, cy + 10.5),
      Offset(cx + 11.5, cy + 10.5),
      stroke,
    );
    for (final dx in const [-10.0, 0.0, 10.0]) {
      canvas.drawCircle(
        Offset(cx + dx, cy + 10.5),
        2.5,
        Paint()..color = Colors.white,
      );
    }
  }

  void _paintServerRackGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final stroke = _strokePaint(width: 2.1);
    for (final dy in const [-9.5, 0.0, 9.5]) {
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + dy), width: 26, height: 7.2),
        const Radius.circular(3.0),
      );
      canvas.drawRRect(r, stroke);
      canvas.drawCircle(
        Offset(cx - 7.5, cy + dy),
        1.5,
        Paint()..color = Colors.white,
      );
      canvas.drawLine(
        Offset(cx - 2.0, cy + dy),
        Offset(cx + 8.0, cy + dy),
        _strokePaint(width: 1.9, color: Colors.white.withValues(alpha: 0.85)),
      );
    }
  }

  void _paintQuarkOrbitGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    canvas.drawCircle(
      Offset(cx, cy),
      6.4,
      Paint()..color = Colors.white,
    );
    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(-0.48);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 31, height: 12.5),
      _strokePaint(width: 2.3),
    );
    canvas.drawCircle(
      const Offset(13.2, -2.5),
      2.3,
      Paint()..color = Colors.white,
    );
    canvas.restore();
  }

  void _paintUcWaveGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: 12.2),
      -math.pi * 0.72,
      math.pi * 1.46,
      false,
      _strokePaint(width: 3.1),
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx + 1.0, cy), radius: 6.4),
      -math.pi * 0.55,
      math.pi * 1.15,
      false,
      _strokePaint(width: 2.4, color: Colors.white.withValues(alpha: 0.88)),
    );
    canvas.drawCircle(
      Offset(cx + 1.5, cy),
      2.6,
      Paint()..color = Colors.white,
    );
  }

  void _paintBaiduTrefoilGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.52;
    final ring = _strokePaint(width: 2.8);
    canvas.drawCircle(Offset(cx - 6.6, cy + 4.2), 6.2, ring);
    canvas.drawCircle(Offset(cx + 6.6, cy + 4.2), 6.2, ring);
    canvas.drawCircle(Offset(cx, cy - 5.8), 6.2, ring);
  }

  void _paintAliCloudWingGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.52;
    final cloud = Path()
      ..moveTo(cx - 10.5, cy + 6.5)
      ..lineTo(cx + 10.5, cy + 6.5)
      ..cubicTo(cx + 15.5, cy + 6.5, cx + 16.0, cy - 1.5, cx + 10.8, cy - 2.6)
      ..cubicTo(cx + 10.2, cy - 10.2, cx + 0.5, cy - 12.2, cx - 3.6, cy - 6.4)
      ..cubicTo(cx - 8.5, cy - 8.2, cx - 14.5, cy - 3.0, cx - 13.8, cy + 2.2)
      ..cubicTo(cx - 13.5, cy + 5.0, cx - 12.2, cy + 6.5, cx - 10.5, cy + 6.5)
      ..close();
    canvas.drawPath(
      cloud,
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );
    canvas.drawPath(cloud, _strokePaint(width: 2.3));
    // Inner upward folded ribbon chevron distinguishing Ali Drive
    final wing = Path()
      ..moveTo(cx - 5.2, cy + 1.8)
      ..lineTo(cx, cy - 3.4)
      ..lineTo(cx + 5.2, cy + 1.8);
    canvas.drawPath(wing, _strokePaint(width: 2.3));
  }

  void _paintLocalDeviceGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final phoneRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: 19, height: 29),
      const Radius.circular(4.8),
    );
    canvas.drawRRect(
      phoneRect,
      Paint()..color = Colors.white.withValues(alpha: 0.16),
    );
    canvas.drawRRect(phoneRect, _strokePaint(width: 2.2));
    // Top speaker / Dynamic Island notch
    canvas.drawLine(
      Offset(cx - 3.2, cy - 10.4),
      Offset(cx + 3.2, cy - 10.4),
      _strokePaint(width: 2.0),
    );
    // Play triangle inside device screen
    final play = Path()
      ..moveTo(cx - 2.6, cy - 3.8)
      ..lineTo(cx + 4.4, cy + 0.4)
      ..lineTo(cx - 2.6, cy + 4.6)
      ..close();
    canvas.drawPath(play, Paint()..color = Colors.white);
  }

  void _paintLinkGlyph(Canvas canvas, Size size) {
    final p = _strokePaint(width: 2.6);
    canvas.save();
    canvas.translate(size.width * 0.5, size.height * 0.5);
    canvas.rotate(-math.pi / 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-13, -5.0, 14, 10),
        const Radius.circular(5.0),
      ),
      p,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-1, -5.0, 14, 10),
        const Radius.circular(5.0),
      ),
      p,
    );
    canvas.restore();
  }

  void _paintZipGlyph(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: 22, height: 26),
      const Radius.circular(4.8),
    );
    canvas.drawRRect(
      rect,
      Paint()..color = Colors.white.withValues(alpha: 0.16),
    );
    canvas.drawRRect(rect, _strokePaint(width: 2.2));
    final teeth = Paint()..color = Colors.white;
    for (var i = 0; i < 4; i++) {
      final left = i.isEven ? -2.8 : 0.4;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx + left, cy - 9.0 + i * 4.7, 2.8, 2.8),
          const Radius.circular(0.8),
        ),
        teeth,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LegacyLibraryIconPainter oldDelegate) =>
      oldDelegate.id != id ||
      oldDelegate.isDark != isDark ||
      oldDelegate.fontFamily != fontFamily;
}

/// iOS / iPadOS Home-Screen-style resource tile: a bare app icon with its
/// label centered below — no card, fill, border or shadow behind the tile.
/// Press feedback mirrors SpringBoard (icon scales to 0.92 and dims slightly,
/// one-shot, no splash).
class _IosLibraryIconTile extends StatefulWidget {
  final _LibraryTileSpec tile;
  final double iconSize;
  final Color labelColor;
  final bool busy;
  final VoidCallback onTap;

  const _IosLibraryIconTile({
    super.key,
    required this.tile,
    required this.iconSize,
    required this.labelColor,
    required this.busy,
    required this.onTap,
  });

  @override
  State<_IosLibraryIconTile> createState() => _IosLibraryIconTileState();
}

class _IosLibraryIconTileState extends State<_IosLibraryIconTile> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = Ios27ConcentricGeometry.isReduceMotion(context);
    final isDark = ApplePalette.isDarkOf(context);
    final duration = Duration(milliseconds: _pressed ? 90 : 160);
    return Semantics(
      button: true,
      label: widget.tile.label,
      value: widget.busy ? '正在连接' : null,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setPressed(true),
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedScale(
                scale: _pressed && !reduceMotion ? 0.92 : 1.0,
                duration: duration,
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: _pressed ? 0.7 : 1.0,
                  duration: duration,
                  curve: Curves.easeOut,
                  child: SizedBox(
                    key: ValueKey('add-lib-icon-${widget.tile.id.name}'),
                    width: widget.iconSize,
                    height: widget.iconSize,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CustomPaint(
                          painter: _IosLibraryIconPainter(
                            id: widget.tile.id,
                            isDark: isDark,
                          ),
                        ),
                        if (widget.busy)
                          ClipPath(
                            clipper: const _IosAppIconClipper(),
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.38),
                              child: const Center(
                                child: CupertinoActivityIndicator(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                widget.tile.label,
                maxLines: 2,
                softWrap: true,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.labelColor,
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.08,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IosAppIconClipper extends CustomClipper<Path> {
  const _IosAppIconClipper();

  @override
  Path getClip(Size size) => buildIosAppIconSquircle(Offset.zero & size);

  @override
  bool shouldReclip(covariant _IosAppIconClipper oldClipper) => false;
}

/// Apple first-party style app icons for the iOS resource library: one
/// continuous-corner superellipse, a smooth two-stop vertical gradient, a
/// faint top sheen and a single bold white SF-Symbols-like glyph drawn on a
/// 100×100 design grid (resolution independent). Glyphs are original
/// pictograms (no third-party logos).
class _IosLibraryIconPainter extends CustomPainter {
  final _LibraryTileId id;
  final bool isDark;

  const _IosLibraryIconPainter({required this.id, required this.isDark});

  static const Color _white = Color(0xFFFFFFFF);

  static List<Color> _gradientFor(_LibraryTileId id) {
    switch (id) {
      case _LibraryTileId.emby:
        return const [Color(0xFF62DD76), Color(0xFF1FA94B)];
      case _LibraryTileId.jellyfin:
        return const [Color(0xFFC383FF), Color(0xFF7F3CE0)];
      case _LibraryTileId.plex:
        return const [Color(0xFF4D4D53), Color(0xFF1C1C1F)];
      case _LibraryTileId.webdav:
        return const [Color(0xFF5FCBFF), Color(0xFF0B8FE6)];
      case _LibraryTileId.smb:
        return const [Color(0xFF8B89FF), Color(0xFF4A45D8)];
      case _LibraryTileId.alistNas:
        return const [Color(0xFF4FE0CF), Color(0xFF0AA294)];
      case _LibraryTileId.quarkDrive:
        return const [Color(0xFF6AA6FF), Color(0xFF2161EC)];
      case _LibraryTileId.ucDrive:
        return const [Color(0xFFFFB84D), Color(0xFFFF7A00)];
      case _LibraryTileId.baiduDrive:
        return const [Color(0xFFFF7373), Color(0xFFE0293C)];
      case _LibraryTileId.aliDrive:
        return const [Color(0xFFFF82BA), Color(0xFFE5367C)];
      case _LibraryTileId.localDevice:
        return const [Color(0xFF6BE5BE), Color(0xFF0FB07B)];
      case _LibraryTileId.manualInput:
        return const [Color(0xFFB3B9C4), Color(0xFF6C7483)];
      case _LibraryTileId.localPack:
        return const [Color(0xFFFFD34D), Color(0xFFF59E00)];
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = buildIosAppIconSquircle(rect);
    if (!isDark) {
      canvas.drawShadow(shape, const Color(0x33000000), 1.4, false);
    }
    canvas.drawPath(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: _gradientFor(id),
        ).createShader(rect),
    );
    // Faint top sheen (static, no animation).
    canvas.drawPath(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: const Alignment(0, 0.15),
          colors: [
            _white.withValues(alpha: 0.18),
            _white.withValues(alpha: 0.0),
          ],
        ).createShader(rect),
    );
    if (isDark) {
      canvas.drawPath(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = _white.withValues(alpha: 0.14),
      );
    }

    canvas.save();
    canvas.clipPath(shape);
    canvas.scale(size.width / 100, size.height / 100);
    const grid = Rect.fromLTWH(0, 0, 100, 100);
    canvas.saveLayer(grid, Paint());
    _paintGlyph(canvas);
    if (id == _LibraryTileId.plex) {
      // Warm amber glyph on graphite for a distinct "home theater" look.
      canvas.drawRect(
        grid,
        Paint()
          ..blendMode = BlendMode.srcIn
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFCB45), Color(0xFFFF9F0A)],
          ).createShader(const Rect.fromLTWH(0, 20, 100, 60)),
      );
    }
    canvas.restore();
    canvas.restore();
  }

  static Paint _fill([double alpha = 1.0]) => Paint()
    ..isAntiAlias = true
    ..color = _white.withValues(alpha: alpha);

  static Paint _stroke(double width) => Paint()
    ..isAntiAlias = true
    ..color = _white
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  static Paint _clear() => Paint()
    ..isAntiAlias = true
    ..blendMode = BlendMode.clear;

  static Paint _clearStroke(double width) => Paint()
    ..isAntiAlias = true
    ..blendMode = BlendMode.clear
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  static RRect _rr(double l, double t, double r, double b, double radius) =>
      RRect.fromLTRBR(l, t, r, b, Radius.circular(radius));

  /// Rounded-corner triangle knock-out (fill + round-join stroke).
  static void _knockTriangle(Canvas c, List<Offset> pts, {double round = 3.4}) {
    final path = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..close();
    c.drawPath(path, _clear());
    c.drawPath(path, _clearStroke(round));
  }

  void _paintGlyph(Canvas c) {
    switch (id) {
      case _LibraryTileId.emby:
        _glyphTvPlay(c);
      case _LibraryTileId.jellyfin:
        _glyphClapper(c);
      case _LibraryTileId.plex:
        _glyphPlayStack(c);
      case _LibraryTileId.webdav:
        _glyphGlobe(c);
      case _LibraryTileId.smb:
        _glyphNetworkDrive(c);
      case _LibraryTileId.alistNas:
        _glyphServerRack(c);
      case _LibraryTileId.quarkDrive:
        _glyphAtom(c);
      case _LibraryTileId.ucDrive:
        _glyphCloudDownload(c);
      case _LibraryTileId.baiduDrive:
        _glyphCloudFolder(c);
      case _LibraryTileId.aliDrive:
        _glyphLayers(c);
      case _LibraryTileId.localDevice:
        _glyphPhonePlay(c);
      case _LibraryTileId.manualInput:
        _glyphLink(c);
      case _LibraryTileId.localPack:
        _glyphArchiveBox(c);
    }
  }

  // Emby · media server: TV with a play knock-out.
  void _glyphTvPlay(Canvas c) {
    c.drawRRect(_rr(21, 25, 79, 65, 9), _fill());
    c.drawRRect(_rr(37, 70, 63, 75, 2.5), _fill());
    _knockTriangle(c, const [Offset(45, 36.5), Offset(58.5, 45), Offset(45, 53.5)]);
  }

  // Jellyfin · media server: clapperboard.
  void _glyphClapper(Canvas c) {
    c.save();
    c.translate(50, 52);
    c.scale(0.94);
    c.translate(-50, -50);
    c.drawRRect(_rr(22, 45, 78, 75, 6.5), _fill());
    for (final x in const [31.0, 45.0, 59.0]) {
      c.drawPath(
        Path()
          ..moveTo(x, 44)
          ..lineTo(x + 7, 44)
          ..lineTo(x + 2, 53.5)
          ..lineTo(x - 5, 53.5)
          ..close(),
        _clear(),
      );
    }
    c.save();
    c.translate(22, 41);
    c.rotate(-0.24);
    c.drawRRect(_rr(0, -10.5, 57, 0, 3), _fill());
    for (final x in const [13.0, 27.0, 41.0]) {
      c.drawPath(
        Path()
          ..moveTo(x, -11)
          ..lineTo(x + 7, -11)
          ..lineTo(x + 2, 0.5)
          ..lineTo(x - 5, 0.5)
          ..close(),
        _clear(),
      );
    }
    c.restore();
    c.restore();
  }

  // Plex · media server: stacked frames with a play knock-out (amber tint).
  void _glyphPlayStack(Canvas c) {
    c.drawRRect(_rr(34, 23, 66, 27, 2), _fill(0.62));
    c.drawRRect(_rr(28, 29.5, 72, 34, 2.25), _fill(0.86));
    c.drawRRect(_rr(22, 37, 78, 75, 8), _fill());
    _knockTriangle(c, const [Offset(45, 47), Offset(58.5, 56), Offset(45, 65)]);
  }

  // WebDAV · network storage: globe.
  void _glyphGlobe(Canvas c) {
    const center = Offset(50, 50);
    const r = 26.0;
    final st = _stroke(5.2);
    c.drawCircle(center, r, st);
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    c.drawOval(Rect.fromCenter(center: center, width: 24, height: 2 * r), st);
    c.drawLine(const Offset(22, 50), const Offset(78, 50), st);
    c.drawPath(
      Path()
        ..moveTo(26, 35)
        ..quadraticBezierTo(50, 41, 74, 35),
      st,
    );
    c.drawPath(
      Path()
        ..moveTo(26, 65)
        ..quadraticBezierTo(50, 59, 74, 65),
      st,
    );
    c.restore();
  }

  // SMB · network storage: drive connected to a LAN line.
  void _glyphNetworkDrive(Canvas c) {
    c.save();
    c.translate(0, 1.5);
    c.drawRRect(_rr(20, 24, 80, 50, 9), _fill());
    c.drawLine(const Offset(30, 37), const Offset(47, 37), _clearStroke(4.4));
    c.drawCircle(const Offset(69, 37), 3.5, _clear());
    c.drawRect(const Rect.fromLTRB(47.5, 49, 52.5, 64), _fill());
    c.drawRRect(_rr(18, 63.5, 82, 68.5, 2.5), _fill());
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(50, 66), width: 15, height: 15),
        const Radius.circular(4.5),
      ),
      _fill(),
    );
    c.restore();
  }

  // AList / OpenList · network storage: server rack.
  void _glyphServerRack(Canvas c) {
    for (final top in const [25.0, 43.0, 61.0]) {
      c.drawRRect(_rr(21, top, 79, top + 14, 4.5), _fill());
      final cy = top + 7;
      c.drawCircle(Offset(30.5, cy), 2.6, _clear());
      c.drawCircle(Offset(38.5, cy), 2.6, _clear());
      c.drawLine(Offset(52, cy), Offset(70, cy), _clearStroke(3.2));
    }
  }

  // Quark · cloud drive: atom orbits.
  void _glyphAtom(Canvas c) {
    final st = _stroke(4.4);
    for (final angle in const [0.0, math.pi / 3, 2 * math.pi / 3]) {
      c.save();
      c.translate(50, 50);
      c.rotate(angle);
      c.drawOval(
        Rect.fromCenter(center: Offset.zero, width: 58, height: 23),
        st,
      );
      c.restore();
    }
    c.drawCircle(const Offset(50, 50), 5.6, _fill());
  }

  Path _cloudPath() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(37, 52), radius: 13))
    ..addOval(Rect.fromCircle(center: const Offset(56, 44), radius: 17))
    ..addRRect(_rr(22, 50, 79, 71, 10.5));

  // UC · cloud drive: cloud with a download arrow knock-out.
  void _glyphCloudDownload(Canvas c) {
    c.save();
    c.translate(0, 1);
    c.drawPath(_cloudPath(), _fill());
    final k = _clearStroke(5.2);
    c.drawLine(const Offset(50, 44), const Offset(50, 61), k);
    c.drawPath(
      Path()
        ..moveTo(42.5, 54)
        ..lineTo(50, 61.5)
        ..lineTo(57.5, 54),
      k,
    );
    c.restore();
  }

  // Baidu · cloud drive: folder with a cloud knock-out.
  void _glyphCloudFolder(Canvas c) {
    c.save();
    c.translate(0, 1);
    c.drawRRect(_rr(21, 25, 47, 38, 5), _fill());
    c.drawRRect(_rr(21, 31, 79, 73, 7.5), _fill());
    c.drawLine(const Offset(19, 38.5), const Offset(81, 38.5), _clearStroke(2.6));
    c.drawCircle(const Offset(44.5, 58), 6.2, _clear());
    c.drawCircle(const Offset(52.5, 54), 8, _clear());
    c.drawRRect(_rr(37, 56, 63, 64.5, 4.25), _clear());
    c.restore();
  }

  // Ali · cloud drive: stacked storage layers.
  void _glyphLayers(Canvas c) {
    c.save();
    c.translate(0, 2);
    final top = Path()
      ..moveTo(50, 21)
      ..lineTo(78, 35)
      ..lineTo(50, 49)
      ..lineTo(22, 35)
      ..close();
    c.drawPath(top, _fill());
    c.drawPath(top, _stroke(4.5));
    final st = _stroke(6.2);
    c.drawPath(
      Path()
        ..moveTo(23, 47.5)
        ..lineTo(50, 61)
        ..lineTo(77, 47.5),
      st,
    );
    c.drawPath(
      Path()
        ..moveTo(23, 59.5)
        ..lineTo(50, 73)
        ..lineTo(77, 59.5),
      st,
    );
    c.restore();
  }

  // Current device: phone with a play knock-out.
  void _glyphPhonePlay(Canvas c) {
    c.drawRRect(_rr(32, 20, 68, 80, 9.5), _fill());
    c.drawRRect(_rr(44, 25.5, 56, 29.5, 2), _clear());
    _knockTriangle(c, const [Offset(45.5, 42.5), Offset(57.5, 50.5), Offset(45.5, 58.5)]);
  }

  // Manual input: subscription link.
  void _glyphLink(Canvas c) {
    c.save();
    c.translate(50, 50);
    c.rotate(-math.pi / 4);
    final st = _stroke(6.4);
    c.drawRRect(_rr(-27, -9.5, 3, 9.5, 9.5), st);
    c.drawRRect(_rr(-3, -9.5, 27, 9.5, 9.5), st);
    c.restore();
  }

  // Local config pack: archive box.
  void _glyphArchiveBox(Canvas c) {
    c.drawRRect(_rr(20, 24, 80, 37, 4.5), _fill());
    c.drawRRect(_rr(24, 40.5, 76, 76, 6), _fill());
    c.drawRRect(_rr(40, 48.5, 60, 55, 3.25), _clear());
  }

  @override
  bool shouldRepaint(covariant _IosLibraryIconPainter oldDelegate) =>
      oldDelegate.id != id || oldDelegate.isDark != isDark;
}

/// Opens the structured Emby connection / editing page in native iOS form style.
/// Returns `true` when an Emby library entry is verified and saved.
Future<bool> showEmbyLibraryFormPage({
  required BuildContext context,
  required StorageService storage,
  SubscriptionEntry? editingSubscription,
  String initialGroup = '默认分组',
  bool initialIsPrivate = false,
  String backLabel = '添加资源库',
  VoidCallback? onSaved,
  Future<void> Function()? onNeedsPrivacyPassword,
}) async {
  final isEditing = editingSubscription != null;
  final title = isEditing ? '编辑 Emby' : '连接 Emby 媒体库';
  bool? result;

  if (defaultTargetPlatform == TargetPlatform.iOS) {
    result = await Navigator.of(context).push<bool>(
      buildApplePageRoute<bool>(
        builder: (_) => _EmbyLibraryIosPage(
          title: title,
          backLabel: backLabel,
          storage: storage,
          editingSubscription: editingSubscription,
          initialGroup: initialGroup,
          initialIsPrivate: initialIsPrivate,
          onSaved: onSaved,
          onNeedsPrivacyPassword: onNeedsPrivacyPassword,
        ),
      ),
    );
  } else {
    result = await showIos27LiquidSheet<bool>(
      context: context,
      title: title,
      maxWidth: 520,
      builder: (_) => _EmbyLibraryFormSheet(
        storage: storage,
        editingSubscription: editingSubscription,
        initialGroup: initialGroup,
        initialIsPrivate: initialIsPrivate,
        onSaved: onSaved,
        onNeedsPrivacyPassword: onNeedsPrivacyPassword,
      ),
    );
  }
  return result == true;
}

class _EmbyLibraryIosPage extends StatefulWidget {
  final String title;
  final String backLabel;
  final StorageService storage;
  final SubscriptionEntry? editingSubscription;
  final String initialGroup;
  final bool initialIsPrivate;
  final VoidCallback? onSaved;
  final Future<void> Function()? onNeedsPrivacyPassword;

  const _EmbyLibraryIosPage({
    required this.title,
    required this.backLabel,
    required this.storage,
    this.editingSubscription,
    required this.initialGroup,
    required this.initialIsPrivate,
    this.onSaved,
    this.onNeedsPrivacyPassword,
  });

  @override
  State<_EmbyLibraryIosPage> createState() => _EmbyLibraryIosPageState();
}

class _EmbyLibraryIosPageState extends State<_EmbyLibraryIosPage> {
  final ValueNotifier<VoidCallback?> _submitTrigger =
      ValueNotifier<VoidCallback?>(null);
  final ValueNotifier<bool> _busyNotifier = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _submitTrigger.dispose();
    _busyNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IosSettingsScaffold(
      title: widget.title,
      backLabel: widget.backLabel,
      trailing: ValueListenableBuilder<bool>(
        valueListenable: _busyNotifier,
        builder: (_, busy, __) => CupertinoButton(
          key: const ValueKey('emby-nav-save-btn'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          minimumSize: const Size(32, 32),
          onPressed: busy ? null : () => _submitTrigger.value?.call(),
          child: const Text(
            '保存',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      body: _EmbyLibraryFormSheet(
        storage: widget.storage,
        editingSubscription: widget.editingSubscription,
        initialGroup: widget.initialGroup,
        initialIsPrivate: widget.initialIsPrivate,
        submitTrigger: _submitTrigger,
        busyNotifier: _busyNotifier,
        onSaved: widget.onSaved,
        onNeedsPrivacyPassword: widget.onNeedsPrivacyPassword,
      ),
    );
  }
}

class _EmbyLibraryFormSheet extends StatefulWidget {
  final StorageService storage;
  final SubscriptionEntry? editingSubscription;
  final String initialGroup;
  final bool initialIsPrivate;
  final ValueNotifier<VoidCallback?>? submitTrigger;
  final ValueNotifier<bool>? busyNotifier;
  final VoidCallback? onSaved;
  final Future<void> Function()? onNeedsPrivacyPassword;

  const _EmbyLibraryFormSheet({
    required this.storage,
    this.editingSubscription,
    required this.initialGroup,
    required this.initialIsPrivate,
    this.submitTrigger,
    this.busyNotifier,
    this.onSaved,
    this.onNeedsPrivacyPassword,
  });

  @override
  State<_EmbyLibraryFormSheet> createState() => _EmbyLibraryFormSheetState();
}

class _EmbyLibraryFormSheetState extends State<_EmbyLibraryFormSheet> {
  final _nameCtrl = TextEditingController();
  final _hostCtrl = TextEditingController();
  final _pathCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '8096');
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _groupCtrl = TextEditingController();

  bool _allowCloudSync = true;
  bool _useHttps = false;
  bool _allowInvalidCert = false;
  bool _obscurePass = true;
  bool _portEditedByUser = false;
  late bool _isPrivate;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final editing = widget.editingSubscription;
    _groupCtrl.text = editing?.group.trim().isNotEmpty == true
        ? editing!.group
        : widget.initialGroup;
    _isPrivate = editing?.isPrivate ?? widget.initialIsPrivate;
    if (editing != null) {
      _nameCtrl.text = editing.name;
    }
    widget.submitTrigger?.value = () => unawaited(_submit());
    if (editing != null) {
      unawaited(_prefillExisting(editing));
    }
  }

  Future<void> _prefillExisting(SubscriptionEntry editing) async {
    final meta = await EmbyLibrary.loadSavedAccountMeta(editing.id);
    if (!mounted || meta == null) return;
    setState(() {
      if (meta.label.trim().isNotEmpty) {
        _nameCtrl.text = meta.label;
      }
      _allowCloudSync = meta.allowCloudSync;
      _useHttps = meta.useHttps;
      _allowInvalidCert = meta.allowInvalidCert;
      _hostCtrl.text = meta.host;
      _pathCtrl.text = meta.path;
      _portCtrl.text =
          meta.port != null ? '${meta.port}' : (meta.useHttps ? '443' : '8096');
      _portEditedByUser = meta.port != null;
      _userCtrl.text = meta.username;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _pathCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _groupCtrl.dispose();
    super.dispose();
  }

  void _setBusy(bool value) {
    _busy = value;
    widget.busyNotifier?.value = value;
  }

  void _handleHttpsChanged(bool nextHttps) {
    setState(() {
      _useHttps = nextHttps;
      if (!nextHttps) {
        _allowInvalidCert = false;
      }
      final currentPort = _portCtrl.text.trim();
      if (!_portEditedByUser ||
          (nextHttps && (currentPort == '8096' || currentPort == '80')) ||
          (!nextHttps && (currentPort == '443' || currentPort == '8920'))) {
        _portCtrl.text = nextHttps ? '443' : '8096';
        _portEditedByUser = false;
      }
    });
  }

  void _handleHostChanged(String value) {
    final trimmed = value.trim();
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(trimmed)) {
      final spec = EmbyLibrary.parseAddressToSpec(
        trimmed,
        defaultHttps: _useHttps,
      );
      setState(() {
        _useHttps = spec.useHttps;
        if (!_useHttps) {
          _allowInvalidCert = false;
        }
        final uri = Uri.tryParse(trimmed);
        if (uri != null && uri.hasPort) {
          _portCtrl.text = '${uri.port}';
          _portEditedByUser = true;
        } else if (!_portEditedByUser) {
          _portCtrl.text = spec.useHttps ? '443' : '8096';
        }
        if (spec.path.isNotEmpty && _pathCtrl.text.trim().isEmpty) {
          _pathCtrl.text = spec.path;
        }
      });
      return;
    }
    setState(() {});
  }

  String? _buildPreviewUrl() {
    if (_hostCtrl.text.trim().isEmpty) return null;
    try {
      return EmbyLibrary.composeAddress(
        useHttps: _useHttps,
        host: _hostCtrl.text,
        path: _pathCtrl.text,
        portText: _portCtrl.text,
      );
    } catch (_) {
      return null;
    }
  }

  String _cleanError(Object error) {
    return error
        .toString()
        .replaceFirst(
          RegExp(r'^(?:Exception|FormatException|StateError):\s*'),
          '',
        )
        .trim();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _setBusy(true);
      _error = null;
    });
    try {
      final address = EmbyLibrary.composeAddress(
        useHttps: _useHttps,
        host: _hostCtrl.text,
        path: _pathCtrl.text,
        portText: _portCtrl.text,
      );
      final username = _userCtrl.text.trim();
      final password = _passCtrl.text;
      final group =
          _groupCtrl.text.trim().isEmpty ? '默认分组' : _groupCtrl.text.trim();
      final label = _nameCtrl.text.trim();
      final editing = widget.editingSubscription;

      SubscriptionEntry? entry;
      if (editing != null && password.isEmpty) {
        try {
          entry = await EmbyLibrary.updateExistingMetaIfValid(
            existing: editing,
            address: address,
            username: username,
            label: label,
            allowCloudSync: _allowCloudSync,
            allowInvalidCert: _allowInvalidCert,
            group: group,
            isPrivate: _isPrivate,
          );
        } catch (e) {
          if (e.toString().contains('拒绝访问')) {
            throw StateError('Emby 登录凭证已失效，请重新输入密码验证');
          }
          rethrow;
        }
      }

      entry ??= await EmbyLibrary.login(
        address,
        username,
        password,
        group: group,
        isPrivate: _isPrivate,
        label: label,
        allowCloudSync: _allowCloudSync,
        allowInvalidCert: _allowInvalidCert,
      );

      await widget.storage.upsertSubscriptions([entry]);
      if (editing != null && editing.id != entry.id) {
        await widget.storage.removeSubscription(editing.id);
      }
      widget.onSaved?.call();
      if (_isPrivate && !widget.storage.hasPrivacyPassword) {
        await widget.onNeedsPrivacyPassword?.call();
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _setBusy(false);
          _error = '连接失败：${_cleanError(e)}（已有资源库不受影响，请检查地址或凭据后重试）';
        });
      }
    }
  }

  Widget _buildField({
    required ValueKey<String> fieldKey,
    required TextEditingController controller,
    required String placeholder,
    bool obscure = false,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
    Widget? suffix,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return TextSelectionMouseGuard(
      child: CupertinoTextField(
        key: fieldKey,
        controller: controller,
        placeholder: placeholder,
        obscureText: obscure,
        maxLines: 1,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: false,
        smartQuotesType: SmartQuotesType.disabled,
        smartDashesType: SmartDashesType.disabled,
        cursorColor: AppleColors.systemBlue,
        onChanged: onChanged,
        suffix: suffix,
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

  Widget _buildSectionLabel(String text) {
    final palette = ApplePalette.of(context);
    return Text(
      text,
      style: TextStyle(
        color: palette.labelSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildSwitchCard({
    required Widget child,
  }) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isEditing = widget.editingSubscription != null;
    final showPrivacy =
        widget.initialIsPrivate || !widget.storage.hasPrivacyConfigured;
    final previewUrl = _buildPreviewUrl();
    const presetGroups = ['默认分组', '主力影视', '超清专线', '电视直播', '动漫番剧'];
    final isDark = palette.isDark;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        28 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionLabel('名称'),
          const SizedBox(height: 6),
          _buildField(
            fieldKey: const ValueKey('emby-name-input'),
            controller: _nameCtrl,
            placeholder: '选填（如：4K影视库）',
          ),
          const SizedBox(height: 14),
          _buildSectionLabel('同步'),
          const SizedBox(height: 6),
          _buildSwitchCard(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '是否允许云端同步',
                    style: TextStyle(
                      color: palette.labelPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                CupertinoSwitch(
                  key: const ValueKey('emby-cloud-sync-switch'),
                  value: _allowCloudSync,
                  activeTrackColor: AppleColors.systemGreen,
                  onChanged: (v) => setState(() => _allowCloudSync = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _buildSectionLabel('协议'),
          const SizedBox(height: 6),
          _buildSwitchCard(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'HTTPS',
                        style: TextStyle(
                          color: palette.labelPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    CupertinoSwitch(
                      key: const ValueKey('emby-https-switch'),
                      value: _useHttps,
                      activeTrackColor: AppleColors.systemGreen,
                      onChanged: _handleHttpsChanged,
                    ),
                  ],
                ),
                if (_useHttps) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Divider(
                      height: 0.5,
                      color: palette.separator,
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '忽略证书校验（自签名 HTTPS）',
                          style: TextStyle(
                            color: palette.labelSecondary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      CupertinoSwitch(
                        key: const ValueKey('emby-insecure-cert-switch'),
                        value: _allowInvalidCert,
                        activeTrackColor: AppleColors.systemOrange,
                        onChanged: (v) => setState(() => _allowInvalidCert = v),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          _buildSectionLabel('服务器地址'),
          const SizedBox(height: 6),
          _buildField(
            fieldKey: const ValueKey('emby-host-input'),
            controller: _hostCtrl,
            placeholder: '域名或 IP（如 emby.example）',
            keyboardType: TextInputType.url,
            onChanged: _handleHostChanged,
          ),
          const SizedBox(height: 14),
          _buildSectionLabel('路径'),
          const SizedBox(height: 6),
          _buildField(
            fieldKey: const ValueKey('emby-path-input'),
            controller: _pathCtrl,
            placeholder: '选填(/path)',
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 14),
          _buildSectionLabel('端口号'),
          const SizedBox(height: 6),
          _buildField(
            fieldKey: const ValueKey('emby-port-input'),
            controller: _portCtrl,
            placeholder: _useHttps ? '选填（默认 443）' : '选填（默认 8096）',
            keyboardType: TextInputType.number,
            onChanged: (v) {
              setState(() {
                _portEditedByUser = v.trim().isNotEmpty;
              });
            },
          ),
          if (previewUrl != null) ...[
            const SizedBox(height: 6),
            Text(
              '连接地址预览：$previewUrl',
              key: const ValueKey('emby-url-preview'),
              style: TextStyle(
                color: palette.labelSecondary,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 14),
          _buildSectionLabel('用户名'),
          const SizedBox(height: 6),
          _buildField(
            fieldKey: const ValueKey('emby-user-input'),
            controller: _userCtrl,
            placeholder: '填写 Emby 账号',
          ),
          const SizedBox(height: 14),
          _buildSectionLabel('密码'),
          const SizedBox(height: 6),
          _buildField(
            fieldKey: const ValueKey('emby-pass-input'),
            controller: _passCtrl,
            placeholder: isEditing
                ? '留空仅更新名称与同步选项，或重新输入密码'
                : '选填（无密码可留空）',
            obscure: _obscurePass,
            suffix: CupertinoButton(
              key: const ValueKey('emby-pass-visibility-btn'),
              padding: const EdgeInsets.only(right: 10),
              minimumSize: const Size(32, 32),
              onPressed: () => setState(() => _obscurePass = !_obscurePass),
              child: Icon(
                _obscurePass ? CupertinoIcons.eye : CupertinoIcons.eye_slash,
                size: 18,
                color: palette.labelSecondary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildSectionLabel('订阅分组'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final g in presetGroups)
                GestureDetector(
                  key: ValueKey('emby-group-pill-$g'),
                  onTap: () => setState(() => _groupCtrl.text = g),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _groupCtrl.text.trim() == g
                          ? AppleColors.systemBlue
                          : (isDark
                              ? const Color(0xFF2C2C2E)
                              : Colors.white),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: _groupCtrl.text.trim() == g
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
                        color: _groupCtrl.text.trim() == g
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
          _buildField(
            fieldKey: const ValueKey('emby-group-input'),
            controller: _groupCtrl,
            placeholder: '或输入自定义分组名（如：主力4K）',
            onChanged: (_) => setState(() {}),
          ),
          if (showPrivacy) ...[
            const SizedBox(height: 14),
            _buildSwitchCard(
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
                    key: const ValueKey('emby-privacy-switch'),
                    value: _isPrivate,
                    activeTrackColor: AppleColors.systemPurple,
                    onChanged: (v) => setState(() => _isPrivate = v),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Container(
              key: const ValueKey('emby-error-banner'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x24FF453A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x66FF453A), width: 0.7),
              ),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppleColors.systemRed,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 48,
            child: CupertinoButton(
              key: const ValueKey('emby-submit-btn'),
              padding: EdgeInsets.zero,
              color: const Color(0xFF52B54B),
              borderRadius: BorderRadius.circular(14),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const CupertinoActivityIndicator(
                      color: Colors.white,
                      radius: 10,
                    )
                  : Text(
                      isEditing ? '验证并保存修改' : '验证并添加资源库',
                      style: const TextStyle(
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
  }
}
