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
              if (ctx.mounted) Navigator.of(ctx).pop();
              widget.onLibraryAdded();
              if (effectivePrivate && !widget.storage.hasPrivacyPassword) {
                await widget.onNeedsPrivacyPassword?.call();
              }
              if (mounted) Navigator.of(context).pop();
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

  @override
  Widget build(BuildContext context) {
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
                                ? _ResourceTileButton(
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

class _ResourceTileButton extends StatefulWidget {
  final _LibraryTileSpec tile;
  final Color labelColor;
  final bool busy;
  final VoidCallback onTap;

  const _ResourceTileButton({
    super.key,
    required this.tile,
    required this.labelColor,
    required this.busy,
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
                        painter: _LibraryIconPainter(
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

/// Unified iOS squircle icon set: every resource library shares identical
/// squircle geometry, gradient depth, specular sheen, inner rim, and vector
/// stroke language, while each service has a distinct color palette and unique
/// geometric emblem so no two icons look alike.
class _LibraryIconPainter extends CustomPainter {
  final _LibraryTileId id;
  final bool isDark;
  final String? fontFamily;

  const _LibraryIconPainter({
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
  bool shouldRepaint(covariant _LibraryIconPainter oldDelegate) =>
      oldDelegate.id != id ||
      oldDelegate.isDark != isDark ||
      oldDelegate.fontFamily != fontFamily;
}
