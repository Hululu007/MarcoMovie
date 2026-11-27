// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/anime4k_controller.dart';
import 'package:marco_movie/core/ohos_runtime.dart';
import 'package:marco_movie/core/windows_video_quality.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

Directory _resolveRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}${Platform.pathSeparator}THIRD_PARTY_NOTICES.md')
        .existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  throw StateError(
    'Unable to locate repository root from ${Directory.current.path}',
  );
}

Future<ByteData> _loadDiskShader(String assetKey) async {
  final root = _resolveRepoRoot();
  final rel = assetKey.replaceAll('/', Platform.pathSeparator);
  final file = File(
    '${root.path}${Platform.pathSeparator}flutter${Platform.pathSeparator}$rel',
  );
  final bytes = await file.readAsBytes();
  return ByteData.sublistView(bytes);
}

class _FakeQualityPlayer extends Fake implements Player {
  @override
  PlatformPlayer? get platform => null;
}

class _FakeStreamingQualityPlayer extends Fake implements Player {
  final StreamController<Track> trackCtrl = StreamController<Track>.broadcast();
  final StreamController<PlayerLog> logCtrl =
      StreamController<PlayerLog>.broadcast();
  Track currentTrack;
  Tracks currentTracks;

  _FakeStreamingQualityPlayer({
    Track? initialTrack,
    Tracks? initialTracks,
  })  : currentTrack = initialTrack ??
            Track(
              audio: AudioTrack.auto(),
              video: VideoTrack.auto(),
              subtitle: SubtitleTrack.auto(),
            ),
        currentTracks = initialTracks ?? const Tracks();

  @override
  PlatformPlayer? get platform => null;

  @override
  PlayerState get state => PlayerState(
        track: currentTrack,
        tracks: currentTracks,
      );

  @override
  PlayerStream get stream => _FakeQualityPlayerStream(this);

  Future<void> disposeFake() async {
    await trackCtrl.close();
    await logCtrl.close();
  }
}

class _FakeQualityPlayerStream extends Fake implements PlayerStream {
  final _FakeStreamingQualityPlayer owner;
  _FakeQualityPlayerStream(this.owner);

  @override
  Stream<Track> get track => owner.trackCtrl.stream;

  @override
  Stream<PlayerLog> get log => owner.logCtrl.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    OhosRuntime.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    OhosRuntime.resetForTesting();
  });

  group('WindowsVideoQualityController presets & property tables', () {
    test('defaults to balancedHq and off loudness; fromId handles aliases', () {
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      expect(ctrl.qualityPreset, WindowsQualityPreset.balancedHq);
      expect(ctrl.loudnessPreset, AudioLoudnessPreset.off);
      expect(ctrl.activeBaseScalers, (scale: 'spline36', cscale: 'spline36'));

      expect(WindowsQualityPreset.fromId(null), WindowsQualityPreset.balancedHq);
      expect(WindowsQualityPreset.fromId('eco'), WindowsQualityPreset.ecoCompat);
      expect(
        WindowsQualityPreset.fromId('eco_compat'),
        WindowsQualityPreset.ecoCompat,
      );
      expect(
        WindowsQualityPreset.fromId('cinemaUltra'),
        WindowsQualityPreset.cinemaUltra,
      );
      expect(
        WindowsQualityPreset.fromId('ultra'),
        WindowsQualityPreset.cinemaUltra,
      );
      expect(
        WindowsQualityPreset.fromId('unknown'),
        WindowsQualityPreset.balancedHq,
      );

      expect(AudioLoudnessPreset.fromId(null), AudioLoudnessPreset.off);
      expect(AudioLoudnessPreset.fromId('light'), AudioLoudnessPreset.light);
      expect(
        AudioLoudnessPreset.fromId('standard'),
        AudioLoudnessPreset.standard,
      );
      expect(
        AudioLoudnessPreset.fromId('cinema_vocal'),
        AudioLoudnessPreset.cinemaVocal,
      );
    });

    test('applies ecoCompat, balancedHq, and cinemaUltra property tables', () async {
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async => props.add((k, v)),
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      // 1. ecoCompat
      expect(
        await ctrl.applyQualityPreset(player, WindowsQualityPreset.ecoCompat),
        isTrue,
      );
      expect(
        props,
        containsAll(const [
          ('hwdec', 'd3d11va'),
          ('scale', 'bilinear'),
          ('cscale', 'bilinear'),
          ('dscale', 'bilinear'),
          ('correct-downscaling', 'no'),
          ('linear-downscaling', 'no'),
          ('sigmoid-upscaling', 'no'),
          ('dither-depth', 'no'),
          ('hdr-compute-peak', 'no'),
          ('deband', 'no'),
        ]),
      );

      // 2. balancedHq (default recommended HDR tone-mapping preset)
      props.clear();
      expect(
        await ctrl.applyQualityPreset(player, WindowsQualityPreset.balancedHq),
        isTrue,
      );
      expect(ctrl.effectiveToneMapping, 'bt.2446a');
      expect(
        props,
        containsAll(const [
          ('hwdec', 'auto-safe'),
          ('scale', 'spline36'),
          ('cscale', 'spline36'),
          ('dscale', 'mitchell'),
          ('correct-downscaling', 'yes'),
          ('linear-downscaling', 'yes'),
          ('sigmoid-upscaling', 'yes'),
          ('dither-depth', 'auto'),
          ('hdr-compute-peak', 'yes'),
          ('deband', 'no'),
          ('gamut-mapping-mode', 'perceptual'),
          ('tone-mapping', 'bt.2446a'),
        ]),
      );

      // 3. cinemaUltra
      props.clear();
      expect(
        await ctrl.applyQualityPreset(player, WindowsQualityPreset.cinemaUltra),
        isTrue,
      );
      expect(ctrl.effectiveScale, 'ewa_lanczossharp');
      expect(
        props,
        containsAll(const [
          ('hwdec', 'auto-safe'),
          ('scale', 'ewa_lanczossharp'),
          ('cscale', 'spline36'),
          ('dscale', 'mitchell'),
          ('correct-downscaling', 'yes'),
          ('linear-downscaling', 'yes'),
          ('sigmoid-upscaling', 'yes'),
          ('dither-depth', 'auto'),
          ('hdr-compute-peak', 'yes'),
          ('deband', 'yes'),
          ('gamut-mapping-mode', 'perceptual'),
          ('tone-mapping', 'bt.2446a'),
          ('target-colorspace-hint', 'yes'),
        ]),
      );
    });

    test(
      'tone-mapping gracefully falls back bt.2446a -> bt.2390 -> spline and survives unsupported optional props',
      () async {
        final accepted = <(String, String)>[];
        final attemptedToneMappings = <String>[];
        final player = _FakeQualityPlayer();

        final ctrl = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          persistLocally: false,
          propertySetterOverride: (k, v) async {
            if (k == 'gamut-mapping-mode' || k == 'target-colorspace-hint') {
              throw StateError('unsupported property $k');
            }
            if (k == 'tone-mapping') {
              attemptedToneMappings.add(v);
              if (v == 'bt.2446a' || v == 'bt.2390') {
                throw ArgumentError('unsupported tone-mapping $v');
              }
            }
            if (k == 'scale' && v == 'ewa_lanczossharp') {
              throw ArgumentError('unsupported scaler $v');
            }
            accepted.add((k, v));
          },
        );
        addTearDown(ctrl.dispose);

        final ok = await ctrl.applyQualityPreset(
          player,
          WindowsQualityPreset.cinemaUltra,
        );
        expect(ok, isTrue);
        expect(attemptedToneMappings, equals(const ['bt.2446a', 'bt.2390', 'spline']));
        expect(ctrl.effectiveToneMapping, 'spline');
        expect(ctrl.effectiveScale, 'spline36');
        expect(ctrl.activeBaseScalers, (scale: 'spline36', cscale: 'spline36'));
        expect(accepted, contains(('scale', 'spline36')));
        expect(accepted, contains(('tone-mapping', 'spline')));
        expect(accepted, contains(('deband', 'yes')));

        // Also test stopping at bt.2390 when only bt.2446a fails.
        attemptedToneMappings.clear();
        final ctrl2 = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          persistLocally: false,
          propertySetterOverride: (k, v) async {
            if (k == 'tone-mapping') {
              attemptedToneMappings.add(v);
              if (v == 'bt.2446a') {
                throw ArgumentError('unsupported $v');
              }
            }
          },
        );
        addTearDown(ctrl2.dispose);
        expect(
          await ctrl2.applyQualityPreset(player, WindowsQualityPreset.balancedHq),
          isTrue,
        );
        expect(attemptedToneMappings, equals(const ['bt.2446a', 'bt.2390']));
        expect(ctrl2.effectiveToneMapping, 'bt.2390');
      },
    );
  });

  group('Smart hwdec linkage & 4-tier audio loudness', () {
    test('switches hwdec to d3d11va-copy for Anime4K, soft filters, and compat kernel', () async {
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async => props.add((k, v)),
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      // Default balancedHq without Anime4K / soft filters / ijk -> auto-safe
      expect(
        WindowsVideoQualityController.resolveHardwareDecoder(
          qualityPreset: WindowsQualityPreset.balancedHq,
        ),
        'auto-safe',
      );
      expect(
        WindowsVideoQualityController.resolveHardwareDecoder(
          qualityPreset: WindowsQualityPreset.balancedHq,
          preferZeroCopyD3d11: true,
        ),
        'd3d11va',
      );
      expect(
        WindowsVideoQualityController.resolveHardwareDecoder(
          qualityPreset: WindowsQualityPreset.ecoCompat,
        ),
        'd3d11va',
      );

      // Anime4K enabled -> d3d11va-copy, and applyQualityPreset does not overwrite Anime4K spline36
      await ctrl.applyQualityPreset(
        player,
        WindowsQualityPreset.ecoCompat,
        anime4kActive: true,
      );
      expect(ctrl.effectiveHwdec, 'd3d11va-copy');
      expect(props, contains(('hwdec', 'd3d11va-copy')));
      expect(props.any((e) => e.$1 == 'scale' && e.$2 == 'bilinear'), isFalse);

      // Compat kernel ('ijk') -> d3d11va-copy
      props.clear();
      expect(
        await ctrl.syncHardwareDecoder(player, playerKernel: 'ijk'),
        'd3d11va-copy',
      );
      expect(props, equals(const [('hwdec', 'd3d11va-copy')]));

      // Soft filter active -> d3d11va-copy
      props.clear();
      expect(
        await ctrl.syncHardwareDecoder(player, softFilterActive: true),
        'd3d11va-copy',
      );
      expect(props, equals(const [('hwdec', 'd3d11va-copy')]));

      // Disabling Anime4K/soft filter on balancedHq restores auto-safe
      await ctrl.applyQualityPreset(player, WindowsQualityPreset.balancedHq);
      expect(ctrl.effectiveHwdec, 'auto-safe');
    });

    test('applies 4-tier AudioLoudnessPreset with parametric EQ, volume-max=100, and fallback', () async {
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async => props.add((k, v)),
        persistLocally: false,
      );
      addTearDown(ctrl.dispose);

      // Verify none of the presets rely on dynaudnorm or volume boosting.
      for (final preset in AudioLoudnessPreset.values) {
        expect(preset.volumeMax, '100');
        expect(preset.audioFilter.contains('dynaudnorm'), isFalse);
        if (preset != AudioLoudnessPreset.off) {
          expect(
            preset.audioFilter.startsWith('format=format=floatp,lavfi=[equalizer='),
            isTrue,
          );
        }
      }

      // light
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.light),
        isTrue,
      );
      expect(
        props,
        equals([
          ('volume-max', '100'),
          ('af', AudioLoudnessPreset.light.audioFilter),
        ]),
      );

      // standard
      props.clear();
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.standard),
        isTrue,
      );
      expect(
        props,
        equals([
          ('volume-max', '100'),
          ('af', AudioLoudnessPreset.standard.audioFilter),
        ]),
      );

      // cinemaVocal
      props.clear();
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.cinemaVocal),
        isTrue,
      );
      expect(
        props,
        equals([
          ('volume-max', '100'),
          ('af', AudioLoudnessPreset.cinemaVocal.audioFilter),
        ]),
      );

      // off clears af and keeps volume-max=100
      props.clear();
      expect(
        await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.off),
        isTrue,
      );
      expect(
        props,
        equals(const [
          ('volume-max', '100'),
          ('af', ''),
        ]),
      );

      // Fallback when extended equalizer chain fails synchronously
      final fallbackProps = <(String, String)>[];
      final fallbackCtrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        persistLocally: false,
        propertySetterOverride: (k, v) async {
          if (k == 'af' && v.contains('f=9000')) {
            throw StateError('unsupported multi-band equalizer');
          }
          fallbackProps.add((k, v));
        },
      );
      addTearDown(fallbackCtrl.dispose);

      expect(
        await fallbackCtrl.applyLoudnessPreset(
          player,
          AudioLoudnessPreset.cinemaVocal,
        ),
        isTrue,
      );
      expect(
        fallbackProps,
        equals(const [
          ('volume-max', '100'),
          ('af', WindowsVideoQualityController.fallbackAudioFilter),
        ]),
      );
    });

    test('滤镜不可用时，当前影片自动恢复原声', () async {
      // 1. Pre-seed legacy saved preference (`cinemaVocal`) to simulate an
      // existing user upgrading and opening a video where mpv accepts `af`
      // synchronously, then fails at audio filter initialization.
      SharedPreferences.setMockInitialValues(<String, Object>{
        WindowsVideoQualityController.prefKeyLoudnessPreset: 'cinemaVocal',
      });
      final props = <(String, String)>[];
      final track2 = AudioTrack('2', 'zh', 'Chinese 5.1');
      final player = _FakeStreamingQualityPlayer(
        initialTrack: Track(
          audio: track2,
          video: VideoTrack.auto(),
          subtitle: SubtitleTrack.auto(),
        ),
        initialTracks: Tracks(
          audio: <AudioTrack>[
            AudioTrack.auto(),
            AudioTrack.no(),
            AudioTrack('1', 'en', 'English'),
            track2,
          ],
        ),
      );
      addTearDown(player.disposeFake);

      var fallbackCallbackCount = 0;
      var notifyCount = 0;
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        recoverySettleDelayOverride: Duration.zero,
        propertySetterOverride: (k, v) async => props.add((k, v)),
      );
      ctrl.addListener(() => notifyCount++);
      addTearDown(ctrl.dispose);

      ctrl.attachPlayer(
        player,
        onLoudnessFallbackToOff: () => fallbackCallbackCount++,
      );
      await ctrl.loadSaved();
      expect(ctrl.loudnessPreset, AudioLoudnessPreset.cinemaVocal);

      // Apply saved preset on first open (mpv setProperty returns OK).
      expect(
        await ctrl.applyLoudnessPreset(
          player,
          ctrl.loudnessPreset,
          persist: false,
        ),
        isTrue,
      );
      expect(ctrl.loudnessPreset, AudioLoudnessPreset.cinemaVocal);
      props.clear();

      // Simulate mpv reporting missing filter & deselecting audio track at playback open.
      player.currentTrack = Track(
        audio: AudioTrack.no(),
        video: VideoTrack.auto(),
        subtitle: SubtitleTrack.auto(),
      );
      player.logCtrl.add(
        const PlayerLog(
          prefix: 'lavfi',
          level: 'error',
          text: "No such filter: 'dynaudnorm'",
        ),
      );
      player.logCtrl.add(
        const PlayerLog(
          prefix: 'cplayer',
          level: 'error',
          text: 'Audio filter initialized failed!',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Verify current movie's audio track is restored without filter, UI state
      // syncs to `off`, and `off` is persisted so next open also has sound.
      expect(
        props,
        equals(const [
          ('af', ''),
          ('volume-max', '100'),
          ('aid', 'no'),
          ('aid', '2'),
        ]),
      );
      expect(ctrl.loudnessPreset, AudioLoudnessPreset.off);
      expect(ctrl.activeAppliedAudioFilter, isEmpty);
      expect(ctrl.lastWarning, contains('自动恢复原声'));
      expect(fallbackCallbackCount, 1);
      expect(notifyCount, greaterThanOrEqualTo(2));
      expect(
        await WindowsVideoQualityController.readSavedLoudnessPreset(),
        AudioLoudnessPreset.off,
      );

      // 2. Also verify synchronous rejection of all audio filters resets to off.
      final syncProps = <(String, String)>[];
      var syncFallbackCalls = 0;
      final syncCtrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async {
          if (k == 'af' && v.isNotEmpty) {
            throw StateError('filter unavailable');
          }
          syncProps.add((k, v));
        },
      );
      addTearDown(syncCtrl.dispose);
      syncCtrl.attachPlayer(
        player,
        onLoudnessFallbackToOff: () => syncFallbackCalls++,
      );
      expect(
        await syncCtrl.applyLoudnessPreset(player, AudioLoudnessPreset.standard),
        isFalse,
      );
      expect(syncCtrl.loudnessPreset, AudioLoudnessPreset.off);
      expect(syncProps, contains(('af', '')));
      expect(syncFallbackCalls, 1);
      expect(
        await WindowsVideoQualityController.readSavedLoudnessPreset(),
        AudioLoudnessPreset.off,
      );
    });
  });

  group('Anime4K decoupling & SharedPreferences persistence', () {
    test(
      'enabling and disabling Anime4K restores balancedHq spline36 (or cinemaUltra ewa_lanczossharp) instead of forcing bilinear',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('win_q_a4k_');
        addTearDown(() => tempDir.delete(recursive: true));
        final props = <(String, String)>[];
        final player = _FakeQualityPlayer();

        final quality = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          persistLocally: false,
        );
        addTearDown(quality.dispose);

        final a4k = Anime4kController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          cacheDirResolver: () async => tempDir,
          assetLoader: _loadDiskShader,
          propertySetterOverride: (k, v) async => props.add((k, v)),
          windowsBaseScalerResolver: () => quality.activeBaseScalers,
          persistLocally: false,
        );
        addTearDown(a4k.dispose);

        // Apply balancedHq first
        await quality.applyQualityPreset(player, WindowsQualityPreset.balancedHq);
        props.clear();

        // Enable Anime4K then disable Anime4K -> MUST restore spline36, NOT bilinear!
        expect(await a4k.applyPreset(player, Anime4kPreset.balanced), isTrue);
        props.clear();
        expect(await a4k.applyPreset(player, Anime4kPreset.off), isTrue);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'spline36'),
            ('cscale', 'spline36'),
          ]),
        );
        expect(props.any((e) => e.$2 == 'bilinear'), isFalse);

        // Switch quality to cinemaUltra, enable Anime4K, then resetSession -> restores ewa_lanczossharp + spline36!
        await quality.applyQualityPreset(player, WindowsQualityPreset.cinemaUltra);
        expect(await a4k.applyPreset(player, Anime4kPreset.performance), isTrue);
        props.clear();
        await a4k.resetSession(player);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'ewa_lanczossharp'),
            ('cscale', 'spline36'),
          ]),
        );

        // Switch quality to ecoCompat, enable Anime4K, then disable -> restores bilinear
        await quality.applyQualityPreset(player, WindowsQualityPreset.ecoCompat);
        expect(await a4k.applyPreset(player, Anime4kPreset.performance), isTrue);
        props.clear();
        expect(await a4k.applyPreset(player, Anime4kPreset.off), isTrue);
        expect(
          props,
          equals(const [
            ('glsl-shaders', ''),
            ('scale', 'bilinear'),
            ('cscale', 'bilinear'),
          ]),
        );
      },
    );

    test('persists quality & loudness presets via SharedPreferences and guards non-Windows platforms', () async {
      final player = _FakeQualityPlayer();
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async {},
      );
      addTearDown(ctrl.dispose);

      await ctrl.applyQualityPreset(player, WindowsQualityPreset.cinemaUltra);
      await ctrl.applyLoudnessPreset(player, AudioLoudnessPreset.cinemaVocal);

      final reloaded = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
      );
      addTearDown(reloaded.dispose);
      await reloaded.loadSaved();
      expect(reloaded.qualityPreset, WindowsQualityPreset.cinemaUltra);
      expect(reloaded.loudnessPreset, AudioLoudnessPreset.cinemaVocal);
      expect(
        await WindowsVideoQualityController.readSavedQualityPreset(),
        WindowsQualityPreset.cinemaUltra,
      );
      expect(
        await WindowsVideoQualityController.readSavedLoudnessPreset(),
        AudioLoudnessPreset.cinemaVocal,
      );

      // Platform guards: strictly Windows-only (non-OHOS, non-Web)
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.iOS,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.macOS,
          isOhosOverride: false,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: true,
          isWebOverride: false,
        ),
        isFalse,
      );
      expect(
        WindowsVideoQualityController.isSupportedPlatform(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: true,
        ),
        isFalse,
      );

      final iosCtrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.iOS,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        propertySetterOverride: (k, v) async {},
      );
      addTearDown(iosCtrl.dispose);
      expect(iosCtrl.isAvailableForPlayer(player), isFalse);
      expect(
        await iosCtrl.applyQualityPreset(player, WindowsQualityPreset.ecoCompat),
        isFalse,
      );
    });

    test('concurrent quality preset race cancels stale operation cleanly', () async {
      final gate = Completer<void>();
      var delayedOnce = false;
      final props = <(String, String)>[];
      final player = _FakeQualityPlayer();

      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
        isNativePlayerOverride: true,
        persistLocally: false,
        propertySetterOverride: (k, v) async {
          props.add((k, v));
          if (!delayedOnce && k == 'hwdec') {
            delayedOnce = true;
            await gate.future;
          }
        },
      );
      addTearDown(ctrl.dispose);

      final staleFuture = ctrl.applyQualityPreset(
        player,
        WindowsQualityPreset.ecoCompat,
      );
      await Future<void>.delayed(Duration.zero);

      final latestOk = await ctrl.applyQualityPreset(
        player,
        WindowsQualityPreset.cinemaUltra,
      );
      expect(latestOk, isTrue);
      expect(ctrl.qualityPreset, WindowsQualityPreset.cinemaUltra);
      expect(ctrl.effectiveHwdec, 'auto-safe');

      props.clear();
      gate.complete();
      expect(await staleFuture, isFalse);
      expect(ctrl.qualityPreset, WindowsQualityPreset.cinemaUltra);
      expect(ctrl.effectiveHwdec, 'auto-safe');
      expect(props, isEmpty);
    });

    test(
      'delayed or in-flight audio filter error after episode switch does not overwrite new episode session',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          WindowsVideoQualityController.prefKeyLoudnessPreset: 'cinemaVocal',
        });
        final props = <(String, String)>[];
        final player = _FakeStreamingQualityPlayer(
          initialTrack: Track(
            audio: AudioTrack('1', 'zh', 'Chinese'),
            video: VideoTrack.auto(),
            subtitle: SubtitleTrack.auto(),
          ),
        );
        addTearDown(player.disposeFake);

        var fallbackCount = 0;
        final ctrl = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          recoverySettleDelayOverride: const Duration(milliseconds: 60),
          propertySetterOverride: (k, v) async => props.add((k, v)),
        );
        addTearDown(ctrl.dispose);

        ctrl.attachPlayer(
          player,
          onLoudnessFallbackToOff: () => fallbackCount++,
        );
        await ctrl.loadSaved();
        await ctrl.applyLoudnessPreset(
          player,
          AudioLoudnessPreset.cinemaVocal,
          persist: false,
        );
        props.clear();

        // 1. Episode 1 emits a non-immediate lavfi error (starts debounce timer),
        // then user immediately switches to Episode 2 before timer fires.
        player.logCtrl.add(
          const PlayerLog(
            prefix: 'lavfi',
            level: 'error',
            text: "No such filter: 'dynaudnorm'",
          ),
        );
        ctrl.onMediaChanged(suspendRecoveryUntilOpen: true);

        // 2. Late error from Episode 1 while Episode 2 is still stopping/resolving
        // must also be ignored.
        player.logCtrl.add(
          const PlayerLog(
            prefix: 'cplayer',
            level: 'error',
            text: 'Audio filter initialized failed!',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(ctrl.loudnessPreset, AudioLoudnessPreset.cinemaVocal);
        expect(fallbackCount, 0);
        expect(props, isEmpty);
        expect(
          await WindowsVideoQualityController.readSavedLoudnessPreset(),
          AudioLoudnessPreset.cinemaVocal,
        );

        // 3. Episode 2 opens -> resume recovery -> in-flight failure starts awaiting
        // settleDelay, then Episode 3 switch happens before settleDelay finishes.
        ctrl.resumeAudioFilterRecovery();
        final inFlight = ctrl.handleRuntimeAudioFilterFailure(
          player,
          reason: 'Audio filter initialized failed!',
          immediate: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        ctrl.onMediaChanged();
        expect(await inFlight, isFalse);

        expect(ctrl.loudnessPreset, AudioLoudnessPreset.cinemaVocal);
        expect(fallbackCount, 0);
        expect(props, isEmpty);
        expect(
          await WindowsVideoQualityController.readSavedLoudnessPreset(),
          AudioLoudnessPreset.cinemaVocal,
        );
      },
    );

    test(
      'delayed or in-flight audio filter error after engine switch (MPV -> MDK) does not overwrite saved preset or new player',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          WindowsVideoQualityController.prefKeyLoudnessPreset: 'standard',
        });
        final props = <(String, String)>[];
        final oldMpvPlayer = _FakeStreamingQualityPlayer();
        final newMpvPlayer = _FakeStreamingQualityPlayer();
        addTearDown(oldMpvPlayer.disposeFake);
        addTearDown(newMpvPlayer.disposeFake);

        var fallbackCount = 0;
        final ctrl = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          recoverySettleDelayOverride: const Duration(milliseconds: 60),
          propertySetterOverride: (k, v) async => props.add((k, v)),
        );
        addTearDown(ctrl.dispose);

        ctrl.attachPlayer(
          oldMpvPlayer,
          onLoudnessFallbackToOff: () => fallbackCount++,
        );
        await ctrl.loadSaved();
        await ctrl.applyLoudnessPreset(
          oldMpvPlayer,
          AudioLoudnessPreset.standard,
          persist: false,
        );
        props.clear();

        // Start in-flight failure on old MPV player, then switch to MDK (detachPlayer).
        final inFlight = ctrl.handleRuntimeAudioFilterFailure(
          oldMpvPlayer,
          reason: 'Audio filter initialized failed!',
          immediate: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        ctrl.detachPlayer();
        expect(await inFlight, isFalse);

        // Late error delivered directly for oldMpvPlayer after switching to MDK or a new MPV player.
        expect(
          await ctrl.handleRuntimeAudioFilterFailure(
            oldMpvPlayer,
            reason: 'Audio filter initialized failed!',
            immediate: true,
          ),
          isFalse,
        );

        ctrl.attachPlayer(
          newMpvPlayer,
          onLoudnessFallbackToOff: () => fallbackCount++,
        );
        expect(
          await ctrl.handleRuntimeAudioFilterFailure(
            oldMpvPlayer,
            reason: 'Audio filter initialized failed!',
            immediate: true,
          ),
          isFalse,
        );

        expect(ctrl.loudnessPreset, AudioLoudnessPreset.standard);
        expect(fallbackCount, 0);
        expect(props, isEmpty);
        expect(
          await WindowsVideoQualityController.readSavedLoudnessPreset(),
          AudioLoudnessPreset.standard,
        );
      },
    );

    test(
      'P1-1 & P2: fast adjacent double-failure recovers new episode B, queued log from outgoing A is dropped, and video-only vf/lavfi errors never disable audio',
      () async {
        // 1) Queued log from outgoing episode A dropped across episode switch.
        SharedPreferences.setMockInitialValues({});
        final playerA = _FakeStreamingQualityPlayer();
        final propsA = <String>[];
        var fallbackA = 0;
        final ctrlA = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          recoverySettleDelayOverride: const Duration(milliseconds: 80),
          propertySetterOverride: (k, v) async => propsA.add('$k=$v'),
        );
        addTearDown(playerA.disposeFake);
        addTearDown(ctrlA.dispose);
        ctrlA.attachPlayer(playerA, onLoudnessFallbackToOff: () => fallbackA++);
        await ctrlA.applyLoudnessPreset(playerA, AudioLoudnessPreset.cinemaVocal);
        propsA.clear();
        const audioErr = PlayerLog(
          prefix: 'cplayer',
          level: 'error',
          text: 'Audio filter initialized failed!',
        );
        playerA.logCtrl.add(audioErr); // queued before onMediaChanged
        ctrlA.onMediaChanged(suspendRecoveryUntilOpen: true);
        ctrlA.resumeAudioFilterRecovery();
        await Future<void>.delayed(const Duration(milliseconds: 160));
        expect(ctrlA.loudnessPreset, AudioLoudnessPreset.cinemaVocal);
        expect(fallbackA, 0);
        expect(propsA, isEmpty);

        // 2) Fast consecutive failures: A starts settling, switch to B, B fails
        //    while A's stale task is still sleeping -> B recovers once.
        SharedPreferences.setMockInitialValues({});
        final playerB = _FakeStreamingQualityPlayer();
        final propsB = <String>[];
        var fallbackB = 0;
        final ctrlB = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          recoverySettleDelayOverride: const Duration(milliseconds: 80),
          propertySetterOverride: (k, v) async => propsB.add('$k=$v'),
        );
        addTearDown(playerB.disposeFake);
        addTearDown(ctrlB.dispose);
        ctrlB.attachPlayer(playerB, onLoudnessFallbackToOff: () => fallbackB++);
        await ctrlB.applyLoudnessPreset(playerB, AudioLoudnessPreset.cinemaVocal);
        propsB.clear();
        playerB.logCtrl.add(audioErr);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        ctrlB.onMediaChanged(suspendRecoveryUntilOpen: true);
        ctrlB.resumeAudioFilterRecovery();
        playerB.logCtrl.add(audioErr);
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(fallbackB, 1);
        expect(ctrlB.loudnessPreset, AudioLoudnessPreset.off);
        expect(propsB, equals(['af=', 'volume-max=100', 'aid=no', 'aid=auto']));

        // 3) Video-only vf / generic lavfi errors must NOT disable audio.
        expect(
          WindowsVideoQualityController.isAudioFilterFailureLog(
            const PlayerLog(
              prefix: 'vf',
              level: 'error',
              text: 'Disabling filter my_video_filter because it has failed.',
            ),
          ),
          isFalse,
        );
        expect(
          WindowsVideoQualityController.isAudioFilterFailureLog(
            const PlayerLog(
              prefix: 'lavfi',
              level: 'fatal',
              text: 'parsing the filter graph failed',
            ),
          ),
          isFalse,
        );
        expect(
          WindowsVideoQualityController.isAudioFilterFailureLog(
            const PlayerLog(
              prefix: 'ffmpeg',
              level: 'error',
              text: "AVFilterGraph: No such filter: 'hflip'",
            ),
          ),
          isFalse,
        );
        expect(
          WindowsVideoQualityController.isAudioFilterFailureLog(
            const PlayerLog(
              prefix: 'af',
              level: 'error',
              text: 'Disabling filter lavfi because it has failed.',
            ),
          ),
          isTrue,
        );

        // 4) P2-track: queued outgoing track-2 selection from Ep1 must NOT
        //    pollute Ep2's recovery, while user selecting track 2 in Ep2 MUST
        //    be preserved on Ep2 recovery.
        SharedPreferences.setMockInitialValues({});
        final playerT = _FakeStreamingQualityPlayer(
          initialTracks: Tracks(
            audio: [
              AudioTrack.auto(),
              const AudioTrack('1', 'Main', 'eng'),
              const AudioTrack('2', 'Commentary', 'eng'),
            ],
          ),
        );
        final propsT = <String>[];
        final ctrlT = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          isNativePlayerOverride: true,
          propertySetterOverride: (k, v) async => propsT.add('$k=$v'),
        );
        addTearDown(playerT.disposeFake);
        addTearDown(ctrlT.dispose);
        ctrlT.attachPlayer(playerT);
        await ctrlT.applyLoudnessPreset(playerT, AudioLoudnessPreset.cinemaVocal);
        propsT.clear();
        // Queued outgoing track-2 event from Ep1 right as Ep2 transition begins
        playerT.trackCtrl.add(
          Track(
            audio: const AudioTrack('2', 'Commentary', 'eng'),
            video: VideoTrack.auto(),
            subtitle: SubtitleTrack.auto(),
          ),
        );
        ctrlT.onMediaChanged(suspendRecoveryUntilOpen: true);
        ctrlT.resumeAudioFilterRecovery();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ctrlT.lastActiveAudioTrackId, isNull);
        playerT.logCtrl.add(audioErr);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(propsT, equals(['af=', 'volume-max=100', 'aid=no', 'aid=auto']));

        // Now re-enable cinemaVocal on current Ep2, manually select Commentary track 2,
        // then trigger audio filter failure -> must restore track 2!
        await ctrlT.applyLoudnessPreset(playerT, AudioLoudnessPreset.cinemaVocal);
        propsT.clear();
        playerT.trackCtrl.add(
          Track(
            audio: const AudioTrack('2', 'Commentary', 'eng'),
            video: VideoTrack.auto(),
            subtitle: SubtitleTrack.auto(),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(ctrlT.lastActiveAudioTrackId, '2');
        playerT.currentTrack = Track(
          audio: AudioTrack.no(),
          video: VideoTrack.auto(),
          subtitle: SubtitleTrack.auto(),
        );
        playerT.logCtrl.add(audioErr);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(propsT, equals(['af=', 'volume-max=100', 'aid=no', 'aid=2']));
      },
    );
  });
}
