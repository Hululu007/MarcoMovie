import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';

/// Runtime bridge to Apple's true iOS 26+ Liquid Glass UIKit primitives
/// (`UITabBar`, `UIGlassEffect`, `UIButton.Configuration.glass()`,
/// `UISegmentedControl`, and native `UIAlertController`).
///
/// On iOS 15–18, macOS, Windows, Android, HarmonyOS, and widget tests,
/// [isAvailable] resolves to `false` and every widget / presenter seamlessly
/// renders its high-fidelity Flutter fallback.
class IosLiquidGlassBridge {
  static const MethodChannel channel = MethodChannel(
    'marco_movie/ios_liquid_glass',
  );

  static final ValueNotifier<bool> available = ValueNotifier<bool>(false);
  static bool _initialized = false;
  static bool? _testOverride;

  static bool get isAvailable {
    if (_testOverride != null) return _testOverride!;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    return available.value;
  }

  static Future<bool> ensureInitialized() async {
    if (_testOverride != null) {
      available.value = _testOverride!;
      return _testOverride!;
    }
    if (_initialized) return available.value;
    _initialized = true;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      available.value = false;
      return false;
    }
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      final supported = result?['available'] == true;
      available.value = supported;
      return supported;
    } on MissingPluginException {
      available.value = false;
      return false;
    } catch (_) {
      available.value = false;
      return false;
    }
  }

  @visibleForTesting
  static void setAvailableForTest(bool? value) {
    _testOverride = value;
    available.value = value ?? false;
    if (value == null) {
      _initialized = false;
    }
  }
}

class IosNativeDockItem {
  final String label;
  final String symbol;
  final String? selectedSymbol;

  const IosNativeDockItem({
    required this.label,
    required this.symbol,
    this.selectedSymbol,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'label': label,
        'symbol': symbol,
        'selectedSymbol': selectedSymbol ?? symbol,
      };
}

/// Hosts the native iOS 26 floating `UITabBar` + detached circular Liquid Glass
/// search button (`UIButton.Configuration.glass()`).
class IosNativeDockView extends StatefulWidget {
  final int selectedIndex;
  final List<IosNativeDockItem> items;
  final ValueChanged<int> onSelect;
  final VoidCallback? onSearch;
  final bool showSearch;
  final bool hidden;
  final double height;

  const IosNativeDockView({
    super.key,
    required this.selectedIndex,
    required this.items,
    required this.onSelect,
    this.onSearch,
    this.showSearch = true,
    this.hidden = false,
    this.height = 68,
  });

  @override
  State<IosNativeDockView> createState() => _IosNativeDockViewState();
}

class _IosNativeDockViewState extends State<IosNativeDockView> {
  MethodChannel? _channel;

  Map<String, dynamic> _buildParams() => <String, dynamic>{
        'selectedIndex': widget.selectedIndex,
        'showSearch': widget.showSearch && widget.onSearch != null,
        'hidden': widget.hidden,
        'items': [for (final item in widget.items) item.toMap()],
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_dock_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onSelect' && call.arguments is int) {
        widget.onSelect(call.arguments as int);
      } else if (call.method == 'onSearch') {
        widget.onSearch?.call();
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeDockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (oldWidget.hidden != widget.hidden) {
      unawaited(_safeInvoke(ch, 'setHidden', widget.hidden));
    }
    final itemsChanged = oldWidget.items.length != widget.items.length ||
        oldWidget.showSearch != widget.showSearch ||
        (oldWidget.onSearch == null) != (widget.onSearch == null);
    if (itemsChanged) {
      unawaited(_safeInvoke(ch, 'update', _buildParams()));
    } else if (oldWidget.selectedIndex != widget.selectedIndex) {
      unawaited(_safeInvoke(ch, 'setSelectedIndex', widget.selectedIndex));
    }
  }

  Future<void> _safeInvoke(MethodChannel ch, String method, dynamic arg) async {
    try {
      await ch.invokeMethod<void>(method, arg);
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: widget.height,
      child: UiKitView(
        viewType: 'marco_movie/ios26_dock',
        creationParams: _buildParams(),
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onViewCreated,
      ),
    );
  }
}

/// Native iOS 26 Liquid Glass circular icon button or capsule button (leading SF
/// Symbol + label + optional trailing SF Symbol), with automatic fallback when
/// running on iOS < 26 or non-iOS platforms.
class IosNativeGlassButton extends StatefulWidget {
  final String style;
  final String? symbol;
  final String? trailingSymbol;
  final String label;
  final double symbolSize;
  final Color foregroundColor;
  final String? accessibilityLabel;
  final double? width;
  final double maxWidth;
  final double height;
  final VoidCallback onTap;
  final Widget fallback;

  const IosNativeGlassButton({
    super.key,
    this.style = 'circle',
    this.symbol,
    this.trailingSymbol,
    this.label = '',
    this.symbolSize = 17,
    this.foregroundColor = Colors.white,
    this.accessibilityLabel,
    this.width,
    this.maxWidth = 168,
    this.height = 40,
    required this.onTap,
    required this.fallback,
  });

  @override
  State<IosNativeGlassButton> createState() => _IosNativeGlassButtonState();
}

class _IosNativeGlassButtonState extends State<IosNativeGlassButton> {
  MethodChannel? _channel;

  Map<String, dynamic> _buildParams() => <String, dynamic>{
        'style': widget.style,
        if (widget.symbol != null) 'symbol': widget.symbol,
        if (widget.trailingSymbol != null)
          'trailingSymbol': widget.trailingSymbol,
        'label': widget.label,
        'symbolSize': widget.symbolSize,
        'foregroundColor': widget.foregroundColor.toARGB32(),
        'accessibilityLabel': widget.accessibilityLabel ?? widget.label,
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_glass_button_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onTap') {
        widget.onTap();
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeGlassButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (oldWidget.style != widget.style ||
        oldWidget.symbol != widget.symbol ||
        oldWidget.trailingSymbol != widget.trailingSymbol ||
        oldWidget.label != widget.label ||
        oldWidget.symbolSize != widget.symbolSize ||
        oldWidget.foregroundColor != widget.foregroundColor ||
        oldWidget.accessibilityLabel != widget.accessibilityLabel) {
      unawaited(_safeUpdate(ch));
    }
  }

  Future<void> _safeUpdate(MethodChannel ch) async {
    try {
      await ch.invokeMethod<void>('update', _buildParams());
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  double _resolvedWidth(BuildContext context) {
    if (widget.width != null) return widget.width!;
    if (widget.style == 'circle') return widget.height;
    final painter = TextPainter(
      text: TextSpan(
        text: widget.label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: widget.maxWidth);
    double extra = 24.0;
    if (widget.symbol != null && widget.symbol!.isNotEmpty) extra += 22.0;
    if (widget.trailingSymbol != null && widget.trailingSymbol!.isNotEmpty) {
      extra += 18.0;
    }
    return (painter.width + extra).clamp(84.0, widget.maxWidth);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: IosLiquidGlassBridge.available,
      builder: (context, _, __) {
        if (!IosLiquidGlassBridge.isAvailable) {
          return widget.fallback;
        }
        return SizedBox(
          width: _resolvedWidth(context),
          height: widget.height,
          child: UiKitView(
            viewType: 'marco_movie/ios26_glass_button',
            creationParams: _buildParams(),
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onViewCreated,
          ),
        );
      },
    );
  }
}

class IosNativeGlassPillAction {
  final String symbol;
  final Color color;
  final String accessibilityLabel;
  final VoidCallback onTap;

  const IosNativeGlassPillAction({
    required this.symbol,
    this.color = Colors.white,
    required this.accessibilityLabel,
    required this.onTap,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'symbol': symbol,
        'color': color.toARGB32(),
        'accessibilityLabel': accessibilityLabel,
      };
}

/// Native iOS 26 multi-action Liquid Glass capsule pill (e.g. Detail screen
/// top-right `[Netdisk | Download | Favorite]` capsule).
class IosNativeGlassPill extends StatefulWidget {
  final List<IosNativeGlassPillAction> actions;
  final double height;
  final Widget fallback;

  const IosNativeGlassPill({
    super.key,
    required this.actions,
    this.height = 40,
    required this.fallback,
  });

  @override
  State<IosNativeGlassPill> createState() => _IosNativeGlassPillState();
}

class _IosNativeGlassPillState extends State<IosNativeGlassPill> {
  MethodChannel? _channel;

  Map<String, dynamic> _buildParams() => <String, dynamic>{
        'items': [for (final a in widget.actions) a.toMap()],
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_glass_pill_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onAction' && call.arguments is int) {
        final idx = call.arguments as int;
        if (idx >= 0 && idx < widget.actions.length) {
          widget.actions[idx].onTap();
        }
      }
    });
  }

  bool _actionsChanged(List<IosNativeGlassPillAction> oldList) {
    if (oldList.length != widget.actions.length) return true;
    for (var i = 0; i < oldList.length; i++) {
      if (oldList[i].symbol != widget.actions[i].symbol ||
          oldList[i].color != widget.actions[i].color ||
          oldList[i].accessibilityLabel !=
              widget.actions[i].accessibilityLabel) {
        return true;
      }
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant IosNativeGlassPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (_actionsChanged(oldWidget.actions)) {
      unawaited(_safeUpdate(ch));
    }
  }

  Future<void> _safeUpdate(MethodChannel ch) async {
    try {
      await ch.invokeMethod<void>('update', _buildParams());
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: IosLiquidGlassBridge.available,
      builder: (context, _, __) {
        if (!IosLiquidGlassBridge.isAvailable) {
          return widget.fallback;
        }
        final count = widget.actions.length;
        final width = 12.0 + count * 38.0 + math.max(0, count - 1) * 0.6;
        return SizedBox(
          width: width,
          height: widget.height,
          child: UiKitView(
            viewType: 'marco_movie/ios26_glass_pill',
            creationParams: _buildParams(),
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onViewCreated,
          ),
        );
      },
    );
  }
}

/// Native iOS 26 `UISegmentedControl` with authentic Liquid Glass translucent
/// pill track & interactive sliding thumb, falling back to Flutter's
/// `CupertinoSlidingSegmentedControl` on older iOS / non-iOS.
class IosNativeSegmentedControl extends StatefulWidget {
  final List<String> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final double height;
  final Widget fallback;

  const IosNativeSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
    this.height = 36,
    required this.fallback,
  });

  @override
  State<IosNativeSegmentedControl> createState() =>
      _IosNativeSegmentedControlState();
}

class _IosNativeSegmentedControlState extends State<IosNativeSegmentedControl> {
  MethodChannel? _channel;

  Map<String, dynamic> _buildParams() => <String, dynamic>{
        'segments': widget.segments,
        'selectedIndex': widget.selectedIndex,
      };

  void _onViewCreated(int id) {
    _channel?.setMethodCallHandler(null);
    final ch = MethodChannel('marco_movie/ios26_segmented_control_$id');
    _channel = ch;
    ch.setMethodCallHandler((call) async {
      if (!mounted) return;
      if (call.method == 'onChanged' && call.arguments is int) {
        widget.onChanged(call.arguments as int);
      }
    });
  }

  @override
  void didUpdateWidget(covariant IosNativeSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ch = _channel;
    if (ch == null) return;
    if (!listEquals(oldWidget.segments, widget.segments)) {
      unawaited(_safeInvoke(ch, 'update', _buildParams()));
    } else if (oldWidget.selectedIndex != widget.selectedIndex) {
      unawaited(_safeInvoke(ch, 'setSelectedIndex', widget.selectedIndex));
    }
  }

  Future<void> _safeInvoke(MethodChannel ch, String method, dynamic arg) async {
    try {
      await ch.invokeMethod<void>(method, arg);
    } catch (_) {}
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: IosLiquidGlassBridge.available,
      builder: (context, _, __) {
        if (!IosLiquidGlassBridge.isAvailable) {
          return widget.fallback;
        }
        return SizedBox(
          width: double.infinity,
          height: widget.height,
          child: UiKitView(
            viewType: 'marco_movie/ios26_segmented_control',
            creationParams: _buildParams(),
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onViewCreated,
          ),
        );
      },
    );
  }
}

class AppleNativeAlertAction {
  final Key? key;
  final String id;
  final String title;
  final bool isCancel;
  final bool isDestructive;
  final bool isDefault;

  const AppleNativeAlertAction({
    this.key,
    required this.id,
    required this.title,
    this.isCancel = false,
    this.isDestructive = false,
    this.isDefault = false,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'style': isCancel
            ? 'cancel'
            : (isDestructive ? 'destructive' : 'default'),
        'isDefault': isDefault,
      };
}

class AppleNativeSheetOption<T> {
  final T value;
  final String title;
  final bool isDestructive;
  final bool isDefault;

  const AppleNativeSheetOption({
    required this.value,
    required this.title,
    this.isDestructive = false,
    this.isDefault = false,
  });
}

/// Presents a genuine iOS 26 Liquid Glass `UIAlertController(.alert)` on iOS 26+
/// and falls back cleanly to Flutter's `CupertinoAlertDialog` everywhere else.
Future<String?> showAppleNativeAlert(
  BuildContext context, {
  required String title,
  String? message,
  List<AppleNativeAlertAction> actions = const [
    AppleNativeAlertAction(id: 'ok', title: '确定', isDefault: true),
  ],
  bool barrierDismissible = true,
}) async {
  if (IosLiquidGlassBridge.isAvailable) {
    try {
      return await IosLiquidGlassBridge.channel.invokeMethod<String>(
        'showAlert',
        <String, dynamic>{
          'title': title,
          if (message != null && message.isNotEmpty) 'message': message,
          'actions': [for (final a in actions) a.toMap()],
        },
      );
    } on MissingPluginException {
      // Fall through to Flutter CupertinoAlertDialog.
    } catch (_) {
      // Fall through to Flutter CupertinoAlertDialog.
    }
  }
  if (!context.mounted) return null;
  return showCupertinoDialog<String>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: message == null || message.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(message),
            ),
      actions: [
        for (final a in actions)
          CupertinoDialogAction(
            key: a.key,
            isDefaultAction: a.isDefault,
            isDestructiveAction: a.isDestructive,
            onPressed: () => Navigator.of(ctx).pop(a.id),
            child: Text(a.title),
          ),
      ],
    ),
  );
}

/// Presents a genuine iOS 26 Liquid Glass `UIAlertController(.actionSheet)` on
/// iOS 26+ (with iPad popover support) and falls back to `CupertinoActionSheet`
/// on iOS < 26 / other platforms.
Future<T?> showAppleNativeActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<AppleNativeSheetOption<T>> options,
  String cancelLabel = '取消',
}) async {
  if (IosLiquidGlassBridge.isAvailable) {
    try {
      final pickedId = await IosLiquidGlassBridge.channel.invokeMethod<String>(
        'showActionSheet',
        <String, dynamic>{
          if (title != null && title.isNotEmpty) 'title': title,
          if (message != null && message.isNotEmpty) 'message': message,
          'cancelTitle': cancelLabel,
          'actions': [
            for (var i = 0; i < options.length; i++)
              <String, dynamic>{
                'id': '$i',
                'title': options[i].title,
                'style': options[i].isDestructive ? 'destructive' : 'default',
              },
          ],
        },
      );
      if (pickedId == null) return null;
      final idx = int.tryParse(pickedId);
      if (idx != null && idx >= 0 && idx < options.length) {
        return options[idx].value;
      }
      return null;
    } on MissingPluginException {
      // Fall through to Flutter CupertinoActionSheet.
    } catch (_) {
      // Fall through to Flutter CupertinoActionSheet.
    }
  }
  if (!context.mounted) return null;
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetCtx) => CupertinoActionSheet(
      title: title == null || title.isEmpty ? null : Text(title),
      message: message == null || message.isEmpty ? null : Text(message),
      actions: [
        for (final opt in options)
          CupertinoActionSheetAction(
            isDefaultAction: opt.isDefault,
            isDestructiveAction: opt.isDestructive,
            onPressed: () => Navigator.of(sheetCtx).pop(opt.value),
            child: Text(opt.title),
          ),
      ],
      cancelButton: cancelLabel.isEmpty
          ? null
          : CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetCtx).pop(),
              child: Text(cancelLabel),
            ),
    ),
  );
}
