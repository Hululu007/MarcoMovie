import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cms_client.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/adaptive_shell.dart';
import 'package:marco_movie/ui/detail_screen.dart';
import 'package:marco_movie/ui/windows_appearance.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'test_storage_helper.dart';

const fixtureSite = CmsSite(
    key: 'owned', name: '测试片源', type: 1, api: 'https://owned.invalid/api');
const fixtureVideo = CmsVideo(
    id: 'one',
    title: '海边的光',
    year: '2026',
    remarks: '更新至 2 集',
    description: '海风与晨光，记录城市里平静的一天。',
    lines: [
      CmsLine(name: '主线路', episodes: [
        CmsEpisode(name: '第 1 集', url: 'https://owned.invalid/1.mp4'),
        CmsEpisode(name: '第 2 集', url: 'https://owned.invalid/2.mp4'),
      ]),
      CmsLine(name: '备用线路', episodes: [
        CmsEpisode(name: '第 1 集', url: 'https://owned.invalid/3.mp4'),
      ]),
    ]);

class WindowsFixtureClient extends CmsClient {
  final categoryRequests = <String>[];
  @override
  Future<(List<CmsCategory>, CmsListing)> fetchHome(CmsSite site) async => (
        const [
          CmsCategory(id: '1', name: '电影'),
          CmsCategory(id: '2', name: '电视剧')
        ],
        const CmsListing(
            videos: [fixtureVideo, CmsVideo(id: 'two', title: '山间来信')]),
      );
  @override
  Future<CmsListing> fetchCategory(CmsSite site, String id, int page,
      {List<String> childIds = const [], CmsFilter? filter}) async {
    categoryRequests.add(id);
    return const CmsListing(videos: [fixtureVideo], sourceFiltered: true);
  }

  @override
  Future<(CmsSite, CmsVideo)> playableDetail(
          CmsSite source, CmsVideo item, Iterable<CmsSite> candidates) async =>
      (source, fixtureVideo);
  @override
  Future<CmsListing> fetchSearch(CmsSite site, String keyword,
          {int page = 1}) async =>
      const CmsListing(videos: [fixtureVideo]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('appearance survives restart without touching existing app preferences',
      () async {
    SharedPreferences.setMockInitialValues({
      'selected_site_key': 'keep',
      'windows_v4_brightness': .83,
      'windows_v4_preset': 'sea'
    });
    final a = WindowsAppearance(Directory.systemTemp);
    await a.load();
    expect(a.presetId, 'sea');
    expect(a.brightness, .83);
    a.preview(theme: 'dark', softness: 18, alignment: 'top');
    await a.save();
    final restored = WindowsAppearance(Directory.systemTemp);
    await restored.load();
    expect(restored.dark, isTrue);
    expect(restored.blur, 18);
    expect(restored.position, 'top');
    expect(
        (await SharedPreferences.getInstance()).getString('selected_site_key'),
        'keep');
    a.dispose();
    restored.dispose();
  });

  test('invalid saved appearance and missing wallpaper fall back safely',
      () async {
    SharedPreferences.setMockInitialValues({
      'windows_v4_preset': 'missing',
      'windows_v4_mode': 7,
      'windows_v4_position': 'bad',
      'windows_v4_blur': 900,
      'windows_v4_brightness': 'bad',
      'windows_v4_image': 'Z:/not-present.png'
    });
    final a = WindowsAppearance(Directory.systemTemp);
    await a.load();
    expect(a.presetId, 'dusk');
    expect(a.mode, 'auto');
    expect(a.position, 'center');
    expect(a.blur, 40);
    expect(a.brightness, 1);
    expect(a.hasImage, isFalse);
    a.dispose();
  });

  test('loading preferences after disposal does not notify a dead widget',
      () async {
    SharedPreferences.setMockInitialValues({});
    final a = WindowsAppearance(Directory.systemTemp);
    final pending = a.load();
    a.dispose();
    await pending;
  });

  testWidgets(
      'wallpaper import copies the original, rejects invalid images and removes only its copy',
      (tester) async {
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      final temp =
          await Directory.systemTemp.createTemp('marco-wallpaper-test-');
      final a = WindowsAppearance(temp);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 24, 24), Paint()..color = Colors.blue);
      final pic = recorder.endRecording();
      final img = await pic.toImage(24, 24);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      final original = File('${temp.path}/original.png');
      await original.writeAsBytes(bytes!.buffer.asUint8List());
      img.dispose();
      pic.dispose();
      await a.load();
      await a.importImage(original.path);
      final managed = a.imagePath;
      expect(managed, isNot(original.path));
      expect(await File(managed).exists(), isTrue);
      final invalid = File('${temp.path}/invalid.png');
      await invalid.writeAsString('bad image');
      await expectLater(a.importImage(invalid.path), throwsA(anything));
      expect(a.imagePath, managed);
      expect(a.importing, isFalse);
      final restored = WindowsAppearance(temp);
      await restored.load();
      expect(restored.imagePath, managed);
      restored.dispose();
      await a.selectPreset('midnight');
      expect(a.dark, isTrue);
      expect(await original.exists(), isTrue);
      expect(await File(managed).exists(), isFalse);
      a.dispose();
      await temp.delete(recursive: true);
    });
  });

  for (final size in [const Size(720, 600), const Size(1280, 800)]) {
    testWidgets('Windows navigation and all settings fit $size',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = await initTestStorage();
      await tester.runAsync(() => storage.saveConfig(jsonEncode({
            'sites': [
              {
                'key': 'owned',
                'name': '测试片源',
                'type': 1,
                'api': 'https://owned.invalid/api'
              }
            ]
          })));
      final client = WindowsFixtureClient();
      final appearance = WindowsAppearance(Directory.systemTemp);
      addTearDown(appearance.dispose);
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) =>
              WindowsAppearanceScope(controller: appearance, child: child!),
          home: RepaintBoundary(
              key: const ValueKey('capture'),
              child: AdaptiveShell(
                  storage: storage,
                  client: client,
                  onSetPreventCloseForTest: (_) async {}))));
      await tester.pumpAndSettle();
      expect(find.text('影片详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('发现').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      expect(client.categoryRequests, contains('1'));
      await tester.tap(find.text('筛选'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('我的').first);
      await tester.pumpAndSettle();
      for (final segment in ['继续观看', '收藏', '下载']) {
        await tester.tap(find.text(segment).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('直播').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('渐变柔光'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['MARCO_CAPTURE_DIR'] case final String output) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')));
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File('$output/settings-${size.width.toInt()}.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      for (final tab in ['播放', '内容来源', '账号', '同步与备份', '更多设置']) {
        await tester.tap(find.widgetWithText(WinButton, tab).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Settings: $tab');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets(
      'Windows details preserve favorites, line switching, episode ordering and all-episode picker',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = await initTestStorage();
    final appearance = WindowsAppearance(Directory.systemTemp);
    addTearDown(appearance.dispose);
    await tester.pumpWidget(MaterialApp(
        builder: (_, child) =>
            WindowsAppearanceScope(controller: appearance, child: child!),
        home: DetailScreen(
            site: fixtureSite,
            initialVideo: fixtureVideo,
            storage: storage,
            client: WindowsFixtureClient())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(storage.getFavorites().length, 1);
    await tester.tap(find.text('备用线路'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ep_card_1_0')), findsOneWidget);
    await tester.tap(find.text('主线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正序'));
    await tester.pumpAndSettle();
    expect(storage.episodesDescending, isTrue);
    await tester.tap(find.text('全部剧集'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
