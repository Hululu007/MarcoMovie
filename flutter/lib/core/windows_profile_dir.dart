// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

class _WindowsDataDirPathProvider extends PathProviderWindows {
  final String _root;

  _WindowsDataDirPathProvider(this._root);

  String _sub(String name) {
    final dir = Directory('$_root${Platform.pathSeparator}$name');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    final dir = Directory(_root);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir.path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => _sub('documents');

  @override
  Future<String?> getApplicationCachePath() async => _sub('cache');

  @override
  Future<String?> getDownloadsPath() async => _sub('downloads');
}

/// Optional Windows desktop profile directory override via `--data-dir=<path>`
/// or `MARCOMOVIE_DATA_DIR=<path>`. No-op when unset (default behavior unchanged).
void configureWindowsDataDirOverride(List<String> args) {
  if (kIsWeb ||
      !Platform.isWindows ||
      Platform.environment.containsKey('FLUTTER_TEST')) {
    return;
  }
  String raw = '';
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--data-dir=')) {
      raw = a.substring('--data-dir='.length).trim();
      break;
    }
    if (a == '--data-dir' && i + 1 < args.length) {
      raw = args[i + 1].trim();
      break;
    }
  }
  if (raw.isEmpty) {
    raw = (Platform.environment['MARCOMOVIE_DATA_DIR'] ?? '').trim();
  }
  if (raw.isEmpty) return;

  final dir = Directory(raw);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final provider = _WindowsDataDirPathProvider(dir.absolute.path);
  PathProviderPlatform.instance = provider;
  final spStore = SharedPreferencesStorePlatform.instance;
  if (spStore is SharedPreferencesWindows) {
    spStore.pathProvider = provider;
  }
}
