import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'apple_theme.dart';
import '../core/windows_appearance_preferences.dart';

class WindowsBackdropPreset {
  final String id;
  final String name;
  final List<Color> colors;
  final bool dark;
  const WindowsBackdropPreset(this.id, this.name, this.colors,
      {this.dark = false});
}

const windowsBackdropPresets = [
  WindowsBackdropPreset('dusk', '暮色流光', [
    Color(0xFFBDAFE5),
    Color(0xFF85C5CF),
    Color(0xFFEDB5B5),
    Color(0xFFB1A8D5)
  ]),
  WindowsBackdropPreset('sea', '海盐蓝', [
    Color(0xFFB5D0E6),
    Color(0xFF99D4CD),
    Color(0xFFBEDFE5),
    Color(0xFF8E9BC8)
  ]),
  WindowsBackdropPreset('sunset', '落日余温', [
    Color(0xFFE4C7AB),
    Color(0xFFC7B4D9),
    Color(0xFFE7A4A2),
    Color(0xFFDCB6A9)
  ]),
  WindowsBackdropPreset('forest', '松间薄雾', [
    Color(0xFFBDD7CD),
    Color(0xFFB9B9CC),
    Color(0xFFC8CFB2),
    Color(0xFF99BAB2)
  ]),
  WindowsBackdropPreset('rose', '玫瑰星云', [
    Color(0xFFA8AFD4),
    Color(0xFFD9AAC1),
    Color(0xFFECC1BA),
    Color(0xFFADA6CD)
  ]),
  WindowsBackdropPreset(
      'midnight',
      '深海微光',
      [
        Color(0xFF49436F),
        Color(0xFF235A69),
        Color(0xFF3C3B63),
        Color(0xFF172B3C)
      ],
      dark: true),
];

/// Windows-only preferences. Managed wallpaper copies never reference the original file.
class WindowsAppearance extends ChangeNotifier {
  final Directory directory;
  SharedPreferences? _preferences;
  String presetId = 'dusk';
  String imagePath = '';
  String importedImagePath = '';
  String mode = 'auto';
  double brightness = 1;
  double blur = 0;
  double imageLuminance = .5;
  String position = 'center';
  bool importing = false;
  bool _disposed = false;
  Future<void> _writeQueue = Future.value();
  static const prefix = 'windows_v4_';

  WindowsAppearance(this.directory);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  WindowsBackdropPreset get preset =>
      windowsBackdropPresets.firstWhere((p) => p.id == presetId,
          orElse: () => windowsBackdropPresets.first);
  bool get hasImage => imagePath.isNotEmpty;
  String get label => hasImage ? '我的图片' : preset.name;
  bool get dark =>
      mode == 'dark' ||
      (mode == 'auto' &&
          (hasImage
              ? imageLuminance * brightness < .42
              : preset.dark || brightness < .63));

  Future<void> load() async {
    final prefs = _preferences = await SharedPreferences.getInstance();
    String string(String key, String fallback) =>
        prefs.get('$prefix$key') is String
            ? prefs.get('$prefix$key') as String
            : fallback;
    double number(String key, double fallback) {
      final value = prefs.get('$prefix$key');
      return value is num && value.isFinite ? value.toDouble() : fallback;
    }

    presetId = string('preset', 'dusk');
    if (!windowsBackdropPresets.any((p) => p.id == presetId)) presetId = 'dusk';
    mode = string('mode', 'auto');
    if (!['auto', 'light', 'dark'].contains(mode)) mode = 'auto';
    brightness = number('brightness', 1).clamp(.35, 1.1);
    blur = number('blur', 0).clamp(0, 40);
    position = string('position', 'center');
    if (!['top', 'center', 'bottom'].contains(position)) position = 'center';
    imageLuminance = number('luminance', .5).clamp(0, 1);
    final saved = string('image', '');
    imagePath = saved.isNotEmpty && await File(saved).exists() ? saved : '';
    final imported = string('imported_image', imagePath);
    importedImagePath =
        imported.isNotEmpty && await File(imported).exists() ? imported : '';
    _changed();
  }

  Future<void> save() {
    final values = (
      presetId,
      mode,
      brightness,
      blur,
      position,
      imagePath,
      imageLuminance,
      importedImagePath
    );
    _writeQueue = _writeQueue.catchError((Object _) {}).then((_) async {
      final prefs = _preferences ??= await SharedPreferences.getInstance();
      final results = await Future.wait([
        prefs.setString('${prefix}preset', values.$1),
        prefs.setString('${prefix}mode', values.$2),
        prefs.setDouble('${prefix}brightness', values.$3),
        prefs.setDouble('${prefix}blur', values.$4),
        prefs.setString('${prefix}position', values.$5),
        prefs.setString('${prefix}image', values.$6),
        prefs.setDouble('${prefix}luminance', values.$7),
        prefs.setString('${prefix}imported_image', values.$8),
      ]);
      if (results.contains(false)) throw const FileSystemException('背景设置无法保存');
    });
    return _writeQueue;
  }

  void preview(
      {String? preset,
      String? theme,
      double? light,
      double? softness,
      String? alignment}) {
    if (preset != null) {
      presetId = preset;
      imagePath = '';
      blur = 0;
    }
    if (theme != null) mode = theme;
    if (light != null) brightness = light.clamp(.35, 1.1);
    if (softness != null) blur = softness.clamp(0, 40);
    if (alignment != null) position = alignment;
    _changed();
  }

  Future<void> selectPreset(String id) async {
    if (importing) return;
    final previous = (presetId, imagePath, blur);
    preview(preset: id);
    try {
      await save();
    } catch (_) {
      presetId = previous.$1;
      imagePath = previous.$2;
      blur = previous.$3;
      _changed();
      rethrow;
    }
  }

  Future<void> useImportedImage() async {
    if (importing || importedImagePath.isEmpty) return;
    final previous = imagePath;
    imagePath = importedImagePath;
    try {
      await save();
    } catch (_) {
      imagePath = previous;
      rethrow;
    }
    _changed();
  }

  Future<void> importImage(String path) async {
    if (importing) return;
    importing = true;
    _changed();
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      final source = File(path);
      if (await source.length() > 20 * 1024 * 1024) {
        throw const FormatException('请选择小于 20 MB 的图片');
      }
      final bytes = await source.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final ratio = (2560 /
                (descriptor.width > descriptor.height
                    ? descriptor.width
                    : descriptor.height))
            .clamp(0.0, 1.0);
        codec = await descriptor.instantiateCodec(
            targetWidth: (descriptor.width * ratio).round().clamp(1, 2560),
            targetHeight: (descriptor.height * ratio).round().clamp(1, 2560));
        decoded = (await codec.getNextFrame()).image;
      } finally {
        descriptor.dispose();
        buffer.dispose();
      }
      final rgba = await decoded.toByteData();
      double luminance = 0;
      int samples = 0;
      if (rgba != null) {
        final data = rgba.buffer.asUint8List();
        final step = ((data.length ~/ 4096) ~/ 4 + 1) * 4;
        for (int i = 0; i + 3 < data.length; i += step) {
          luminance +=
              (.2126 * data[i] + .7152 * data[i + 1] + .0722 * data[i + 2]) /
                  255;
          samples++;
        }
      }
      final png = await decoded.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw const FormatException('无法读取这张图片');
      final folder = Directory('${directory.path}/windows-backgrounds');
      await folder.create(recursive: true);
      final target = File(
          '${folder.path}/background-${DateTime.now().microsecondsSinceEpoch}.png');
      await target.writeAsBytes(png.buffer.asUint8List(), flush: true);
      final oldPath = imagePath;
      final oldImported = importedImagePath;
      final oldLuminance = imageLuminance;
      final oldBlur = blur;
      imagePath = target.path;
      importedImagePath = target.path;
      imageLuminance = samples == 0 ? .5 : luminance / samples;
      blur = 8;
      try {
        await save();
      } catch (_) {
        imagePath = oldPath;
        importedImagePath = oldImported;
        imageLuminance = oldLuminance;
        blur = oldBlur;
        await target.delete();
        rethrow;
      }
      await _deleteManagedImage(oldPath);
      if (oldImported != oldPath) await _deleteManagedImage(oldImported);
    } finally {
      decoded?.dispose();
      codec?.dispose();
      importing = false;
      _changed();
    }
  }

  Future<void> _deleteManagedImage(String path) async {
    final folder = Directory('${directory.path}/windows-backgrounds')
        .absolute
        .uri
        .normalizePath()
        .toString()
        .toLowerCase();
    if (path.isEmpty ||
        File(path)
                .parent
                .absolute
                .uri
                .normalizePath()
                .toString()
                .toLowerCase() !=
            folder) return;
    try {
      await File(path).delete();
    } on FileSystemException {
      /* An unused wallpaper is safe to leave for later cleanup. */
    }
  }

  Future<void> removeImage() async {
    if (importing) return;
    final oldPath = imagePath;
    final oldImported = importedImagePath;
    final oldBlur = blur;
    imagePath = '';
    importedImagePath = '';
    blur = 0;
    try {
      await save();
    } catch (_) {
      imagePath = oldPath;
      importedImagePath = oldImported;
      blur = oldBlur;
      rethrow;
    }
    await _deleteManagedImage(oldPath);
    if (oldImported != oldPath) await _deleteManagedImage(oldImported);
    _changed();
  }

  Future<void> reset() async {
    if (importing) return;
    imagePath = '';
    presetId = 'dusk';
    mode = 'auto';
    brightness = 1;
    blur = 0;
    position = 'center';
    await save();
    _changed();
  }
}

class WindowsAppearanceScope extends InheritedNotifier<WindowsAppearance> {
  const WindowsAppearanceScope(
      {super.key, required WindowsAppearance controller, required super.child})
      : super(notifier: controller);
  static WindowsAppearance? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WindowsAppearanceScope>()
      ?.notifier;
  static WindowsAppearance of(BuildContext context) => maybeOf(context)!;
}

class WindowsAppearanceHost extends StatefulWidget {
  final Directory directory;
  final Widget child;
  const WindowsAppearanceHost(
      {super.key, required this.directory, required this.child});
  @override
  State<WindowsAppearanceHost> createState() => _WindowsAppearanceHostState();
}

class _WindowsAppearanceHostState extends State<WindowsAppearanceHost> {
  late final WindowsAppearance controller = WindowsAppearance(widget.directory);
  @override
  void initState() {
    super.initState();
    WindowsAppearancePreferences.revision.addListener(_reload);
    controller.load().catchError((Object _) {
      // An unavailable preference store must not prevent the app from opening.
    });
  }

  void _reload() {
    controller.load().catchError((Object _) {});
  }

  @override
  void dispose() {
    WindowsAppearancePreferences.revision.removeListener(_reload);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WindowsAppearanceScope(
      controller: controller,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final dark = controller.dark;
          final scheme = ColorScheme.fromSeed(
              seedColor: const Color(0xFF53799D),
              brightness: dark ? Brightness.dark : Brightness.light);
          final theme = Theme.of(context).copyWith(
            brightness: dark ? Brightness.dark : Brightness.light,
            colorScheme: scheme,
            scaffoldBackgroundColor: Colors.transparent,
            textTheme: Theme.of(context).textTheme.apply(
                bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
          );
          return Theme(
              data: theme,
              child: DefaultTextStyle(
                  style: TextStyle(
                      fontFamily: 'Microsoft YaHei UI',
                      color: scheme.onSurface,
                      fontSize: 14),
                  child: widget.child));
        },
      ));
}

Color winInk(BuildContext context) => WindowsAppearanceScope.of(context).dark
    ? const Color(0xFFF2F5FC)
    : const Color(0xFF263649);
Color winMuted(BuildContext context) => WindowsAppearanceScope.of(context).dark
    ? const Color(0xFFBFCDE1)
    : const Color(0xFF39495F);

class WindowsBackdrop extends StatelessWidget {
  final Widget child;
  const WindowsBackdrop({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final a = WindowsAppearanceScope.of(context);
    final position = a.position == 'top'
        ? Alignment.topCenter
        : a.position == 'bottom'
            ? Alignment.bottomCenter
            : Alignment.center;
    return Stack(fit: StackFit.expand, children: [
      RepaintBoundary(
          child: ClipRect(
              child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: a.blur, sigmaY: a.blur),
        enabled: a.blur > 0,
        child: ColorFiltered(
            colorFilter: ColorFilter.matrix([
              a.brightness,
              0,
              0,
              0,
              0,
              0,
              a.brightness,
              0,
              0,
              0,
              0,
              0,
              a.brightness,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
            ]),
            child: a.hasImage
                ? Image.file(File(a.imagePath),
                    fit: BoxFit.cover,
                    alignment: position,
                    errorBuilder: (_, __, ___) =>
                        SoftGradient(preset: a.preset))
                : SoftGradient(preset: a.preset)),
      ))),
      if (a.hasImage || a.mode != 'auto' || a.brightness < .85)
        ColoredBox(
            color: a.dark
                ? Colors.black.withValues(alpha: .68)
                : Colors.white.withValues(alpha: .78)),
      child,
    ]);
  }
}

class SoftGradient extends StatelessWidget {
  final WindowsBackdropPreset preset;
  const SoftGradient({super.key, required this.preset});
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [preset.colors[0], preset.colors[2]])),
        child: Stack(fit: StackFit.expand, children: [
          DecoratedBox(
              decoration: BoxDecoration(
                  gradient: RadialGradient(
                      center: Alignment.topRight,
                      radius: 1.15,
                      colors: [
                preset.colors[1],
                preset.colors[1].withValues(alpha: 0)
              ]))),
          DecoratedBox(
              decoration: BoxDecoration(
                  gradient: RadialGradient(
                      center: Alignment.bottomLeft,
                      radius: .95,
                      colors: [
                preset.colors[3],
                preset.colors[3].withValues(alpha: 0)
              ]))),
        ]),
      );
}

class WinPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool dark;
  const WinPanel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(22),
      this.radius = 24,
      this.dark = false});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: Listenable.merge(
          [GlassworkBackdrop.reduceTransparency, GlassworkBackdrop.intensity]),
      builder: (context, _) => _surface(context));

  Widget _surface(BuildContext context) {
    final isDark = dark || WindowsAppearanceScope.of(context).dark;
    final opaque = GlassworkBackdrop.reduceTransparency.value ||
        MediaQuery.highContrastOf(context) ||
        GlassworkBackdrop.intensity.value <= .02;
    return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          enabled: false,
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: opaque
                    ? (isDark
                        ? const Color(0xFF29364A)
                        : const Color(0xFFF0F1F5))
                    : isDark
                        ? const Color(0xFF1C293E).withValues(
                            alpha:
                                .80 + .08 * GlassworkBackdrop.intensity.value)
                        : Colors.white.withValues(
                            alpha:
                                .48 + .12 * GlassworkBackdrop.intensity.value),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(
                    color: Colors.white.withValues(alpha: isDark ? .18 : .57)),
              ),
              child: child),
        ));
  }
}

class WinButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool selected;
  const WinButton(this.label,
      {super.key, required this.onPressed, this.icon, this.selected = false});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: GlassworkBackdrop.reduceTransparency,
      builder: (context, opaque, _) => TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
                foregroundColor: winInk(context),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
                backgroundColor: selected
                    ? opaque
                        ? WindowsAppearanceScope.of(context).dark
                            ? const Color(0xFF455166)
                            : Colors.white
                        : Colors.white.withValues(
                            alpha: WindowsAppearanceScope.of(context).dark
                                ? .2
                                : .65)
                    : Colors.transparent,
                shape: const StadiumBorder(),
                minimumSize: const Size(44, 44)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 17),
                const SizedBox(width: 8)
              ],
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis))
            ]),
          ));
}

bool usesWindowsAppearance(BuildContext context) =>
    defaultTargetPlatform == TargetPlatform.windows &&
    WindowsAppearanceScope.maybeOf(context) != null;

/// Limits shared settings adapters to settings routes, leaving player sheets intact.
class WindowsSettingsRegion extends InheritedWidget {
  const WindowsSettingsRegion({super.key, required super.child});
  @override
  bool updateShouldNotify(WindowsSettingsRegion oldWidget) => false;
}

bool usesWindowsSettings(BuildContext context) => usesWindowsAppearance(context) &&
    context.dependOnInheritedWidgetOfExactType<WindowsSettingsRegion>() != null;

Color settingsInk(BuildContext context) =>
    usesWindowsAppearance(context) ? winInk(context) : AppleColors.labelPrimary;
Color settingsMuted(BuildContext context) => usesWindowsAppearance(context)
    ? winMuted(context)
    : AppleColors.labelSecondary;

/// Shared Windows settings surfaces, including secondary routes and account forms.
class WinSettingsGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> children;
  const WinSettingsGroup(
      {super.key, this.header, this.footer, required this.children});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header?.isNotEmpty ?? false)
            Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                child: Text(header!,
                    style: TextStyle(
                        color: winInk(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w600))),
          WinPanel(
              radius: 20,
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                        height: 1,
                        indent: 18,
                        endIndent: 18,
                        color: winMuted(context).withValues(alpha: .12)),
                  children[i],
                ],
              ])),
          if (footer?.isNotEmpty ?? false)
            Padding(
                padding: const EdgeInsets.fromLTRB(4, 9, 4, 0),
                child: Text(footer!,
                    style: TextStyle(
                        color: winMuted(context), fontSize: 12, height: 1.5))),
        ],
      );
}

class WinSettingsRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? value;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  const WinSettingsRow(
      {super.key,
      required this.title,
      this.subtitle,
      this.value,
      this.icon,
      this.trailing,
      this.onTap,
      this.titleColor});
  @override
  Widget build(BuildContext context) => Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: LayoutBuilder(builder: (context, box) {
              final narrow = box.maxWidth < 520;
              return Row(children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: winMuted(context)),
                  const SizedBox(width: 14),
                ],
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(title,
                          style: TextStyle(
                              color: titleColor ?? winInk(context),
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      if (subtitle?.isNotEmpty ?? false)
                        Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(subtitle!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: winMuted(context),
                                    fontSize: 12,
                                    height: 1.45))),
                      if (narrow && (value?.isNotEmpty ?? false))
                        Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(value!,
                                style: TextStyle(
                                    color: winInk(context), fontSize: 12))),
                    ])),
                if (!narrow && (value?.isNotEmpty ?? false)) ...[
                  const SizedBox(width: 16),
                  ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * .27),
                      child: Text(value!,
                          maxLines: 2,
                          textAlign: TextAlign.end,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: winMuted(context), fontSize: 12))),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: 14),
                  trailing!
                ] else if (onTap != null) ...[
                  const SizedBox(width: 12),
                  Icon(CupertinoIcons.chevron_right,
                      size: 14, color: winMuted(context))
                ],
              ]);
            })),
      ));
}

class WinSettingsScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const WinSettingsScaffold(
      {super.key, required this.title, this.subtitle, required this.child});
  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: Colors.transparent,
      body: WindowsBackdrop(
          child: SafeArea(
              child: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            child: Row(children: [
              WinButton('返回',
                  icon: CupertinoIcons.back,
                  onPressed: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 16),
              Expanded(
                  child: Text(title,
                      style: TextStyle(
                          color: winInk(context),
                          fontSize: 24,
                          fontWeight: FontWeight.w600))),
            ])),
        Expanded(
            child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (subtitle?.isNotEmpty ?? false)
                                Padding(
                                    padding: const EdgeInsets.only(bottom: 20),
                                    child: Text(subtitle!,
                                        style: TextStyle(
                                            color: winMuted(context),
                                            height: 1.5))),
                              WindowsSettingsRegion(child: child),
                            ]))))),
      ]))));
}

class WindowsAppearanceSettings extends StatelessWidget {
  const WindowsAppearanceSettings({super.key});
  Future<void> _save(
      BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e is FormatException ? e.message : '背景设置未能保存，请重试。')));
    }
  }

  Future<void> _pick(BuildContext context) async {
    final a = WindowsAppearanceScope.of(context);
    await _save(context, () async {
      final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['jpg', 'jpeg', 'png', 'webp']);
      if (result?.files.single.path == null || !context.mounted) return;
      await a.importImage(result!.files.single.path!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = WindowsAppearanceScope.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 760;
      final chooser =
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            height: 260,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: WindowsBackdrop(
                    child: Center(
                        child: WinPanel(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('Marco Movie',
                        style: TextStyle(
                            color: winInk(context),
                            fontSize: 26,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 22),
                    Wrap(
                        spacing: 12,
                        children: ['首页', '发现', '直播', '我的']
                            .map((s) => WinButton(s,
                                selected: s == '首页', onPressed: null))
                            .toList()),
                  ]),
                ))))),
        const SizedBox(height: 26),
        Text('渐变柔光',
            style: TextStyle(
                color: winInk(context),
                fontSize: 18,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 18),
        LayoutBuilder(
            builder: (context, box) => Wrap(
                spacing: 14,
                runSpacing: 18,
                children: windowsBackdropPresets
                    .map((preset) => SizedBox(
                          width: (box.maxWidth - 28) / 3,
                          child: Semantics(
                              button: true,
                              selected: !a.hasImage && a.presetId == preset.id,
                              label: preset.name,
                              child: InkWell(
                                onTap: a.importing
                                    ? null
                                    : () => _save(context,
                                        () => a.selectPreset(preset.id)),
                                borderRadius: BorderRadius.circular(18),
                                child: Column(children: [
                                  Container(
                                      height: 80,
                                      padding: const EdgeInsets.all(3),
                                      decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          border: Border.all(
                                              color: !a.hasImage &&
                                                      a.presetId == preset.id
                                                  ? winInk(context)
                                                  : Colors.transparent,
                                              width: 2)),
                                      child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(13),
                                          child: SoftGradient(preset: preset))),
                                  const SizedBox(height: 8),
                                  Text(preset.name,
                                      style: TextStyle(
                                          color: winMuted(context),
                                          fontSize: 12))
                                ]),
                              )),
                        ))
                    .toList())),
      ]);
      final controls = Column(children: [
        WinPanel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('界面颜色',
              style: TextStyle(
                  color: winInk(context), fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(
              children: [('auto', '自动'), ('light', '浅色'), ('dark', '深色')]
                  .map((entry) => Expanded(
                          child: WinButton(entry.$2,
                              selected: a.mode == entry.$1, onPressed: () {
                        a.preview(theme: entry.$1);
                        _save(context, a.save);
                      })))
                  .toList()),
          const SizedBox(height: 24),
          _slider(context, '背景亮度', '${(a.brightness * 100).round()}%',
              a.brightness, .35, 1.1, (v) => a.preview(light: v)),
          const SizedBox(height: 18),
          _slider(context, '背景模糊', '${a.blur.round()} px', a.blur, 0, 40,
              (v) => a.preview(softness: v)),
          if (a.hasImage)
            DropdownButton<String>(
                value: a.position,
                isExpanded: true,
                items: [('center', '居中铺满'), ('top', '保留上方'), ('bottom', '保留下方')]
                    .map(
                        (p) => DropdownMenuItem(value: p.$1, child: Text(p.$2)))
                    .toList(),
                onChanged: (v) {
                  a.preview(alignment: v);
                  _save(context, a.save);
                }),
        ])),
        const SizedBox(height: 20),
        WinPanel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('用自己的照片',
              style: TextStyle(
                  color: winInk(context),
                  fontWeight: FontWeight.w600,
                  fontSize: 16)),
          const SizedBox(height: 12),
          Text('JPG、PNG、WebP · 最大 20 MB',
              style: TextStyle(color: winMuted(context), fontSize: 12)),
          const SizedBox(height: 18),
          WinButton(a.importing ? '正在导入…' : '选择本地图片',
              selected: true,
              icon: CupertinoIcons.photo,
              onPressed: a.importing ? null : () => _pick(context)),
          if (a.importedImagePath.isNotEmpty && !a.hasImage)
            WinButton('使用已导入图片',
                onPressed: () => _save(context, a.useImportedImage)),
          if (a.importedImagePath.isNotEmpty)
            WinButton('移除图片', onPressed: () => _save(context, a.removeImage)),
          Text('外观参数可备份；照片保存在本机，换设备后请重新导入。',
              style: TextStyle(color: winMuted(context), fontSize: 12)),
        ])),
        const SizedBox(height: 15),
        WinButton('恢复默认', onPressed: () => _save(context, a.reset))
      ]);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('背景与外观',
            style: TextStyle(
                color: winInk(context),
                fontSize: 25,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Text('选一个喜欢的氛围，调整后自动保存。', style: TextStyle(color: winMuted(context))),
        const SizedBox(height: 28),
        if (compact) ...[chooser, const SizedBox(height: 28), controls] else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: chooser),
            const SizedBox(width: 28),
            SizedBox(width: 300, child: controls)
          ]),
      ]);
    });
  }

  Widget _slider(
          BuildContext context,
          String label,
          String value,
          double current,
          double min,
          double max,
          ValueChanged<double> update) =>
      Column(children: [
        Row(children: [
          Text(label, style: TextStyle(color: winInk(context))),
          const Spacer(),
          Text(value, style: TextStyle(color: winMuted(context), fontSize: 12))
        ]),
        Slider(
            value: current,
            min: min,
            max: max,
            label: value,
            onChanged: update,
            onChangeEnd: (_) =>
                _save(context, WindowsAppearanceScope.of(context).save)),
      ]);
}
