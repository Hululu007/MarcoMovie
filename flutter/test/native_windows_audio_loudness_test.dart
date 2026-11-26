// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Run with MARCOMOVIE_TEST_MPV pointing at the bundled libmpv-2.dll.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/windows_video_quality.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Writes a valid uncompressed PCM 16-bit WAV file (stereo 2ch or 5.1 6ch)
/// containing 85 Hz bass + 1400 Hz center-dialogue tone + 3200 Hz harmonics.
Future<File> _writeSynthWav(
  Directory dir,
  String name, {
  required int channels,
  int sampleRate = 48000,
  double durationSec = 2.0,
}) async {
  final numFrames = (sampleRate * durationSec).round();
  final dataBytes = numFrames * channels * 2;
  final bytes = ByteData(44 + dataBytes);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little); // PCM header size
  bytes.setUint16(20, 1, Endian.little); // PCM format
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);

  var offset = 44;
  for (var i = 0; i < numFrames; i++) {
    final t = i / sampleRate;
    final bass = math.sin(2 * math.pi * 85.0 * t);
    final vocal = math.sin(2 * math.pi * 1400.0 * t);
    final harmonic = math.sin(2 * math.pi * 3200.0 * t);
    if (channels == 2) {
      final sample = ((0.22 * bass + 0.18 * vocal + 0.10 * harmonic) * 32767)
          .round()
          .clamp(-32768, 32767);
      bytes.setInt16(offset, sample, Endian.little);
      bytes.setInt16(offset + 2, sample, Endian.little);
      offset += 4;
    } else {
      // 5.1 layout: FL, FR, FC (dialogue), LFE (bass), BL, BR
      final fl = (0.20 * bass * 32767).round().clamp(-32768, 32767);
      final fr = (0.20 * bass * 32767).round().clamp(-32768, 32767);
      final fc = ((0.26 * vocal + 0.12 * harmonic) * 32767)
          .round()
          .clamp(-32768, 32767);
      final lfe = (0.28 * bass * 32767).round().clamp(-32768, 32767);
      final bl = (0.08 * bass * 32767).round().clamp(-32768, 32767);
      final br = (0.08 * bass * 32767).round().clamp(-32768, 32767);
      bytes.setInt16(offset, fl, Endian.little);
      bytes.setInt16(offset + 2, fr, Endian.little);
      bytes.setInt16(offset + 4, fc, Endian.little);
      bytes.setInt16(offset + 6, lfe, Endian.little);
      bytes.setInt16(offset + 8, bl, Endian.little);
      bytes.setInt16(offset + 10, br, Endian.little);
      offset += 12;
    }
  }

  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  return file;
}

({int frames, double rms}) _measureWavPcm(File wavFile) {
  if (!wavFile.existsSync()) return (frames: 0, rms: 0.0);
  final raw = wavFile.readAsBytesSync();
  if (raw.length <= 44) return (frames: 0, rms: 0.0);
  // Find 'data' chunk robustly
  var dataStart = 44;
  for (var i = 12; i < raw.length - 8; i++) {
    if (raw[i] == 0x64 &&
        raw[i + 1] == 0x61 &&
        raw[i + 2] == 0x74 &&
        raw[i + 3] == 0x61) {
      dataStart = i + 8;
      break;
    }
  }
  final bd = ByteData.sublistView(raw);
  final sampleCount = (raw.length - dataStart) ~/ 2;
  if (sampleCount <= 0) return (frames: 0, rms: 0.0);
  var sumSq = 0.0;
  for (var i = 0; i < sampleCount; i++) {
    final v = bd.getInt16(dataStart + i * 2, Endian.little).toDouble();
    sumSq += v * v;
  }
  return (frames: sampleCount ~/ 2, rms: math.sqrt(sumSq / sampleCount));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['MARCOMOVIE_TEST_MPV'];
  final skipReason = (library == null || library.isEmpty)
      ? 'Set MARCOMOVIE_TEST_MPV to the bundled libmpv-2.dll to run native audio tests'
      : null;

  test(
    'real libmpv-2.dll outputs audio across all vocal presets (stereo + 5.1, cold start, live switch, ep switch, restart)',
    skip: skipReason,
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      SharedPreferences.setMockInitialValues(<String, Object>{
        WindowsVideoQualityController.prefKeyLoudnessPreset: 'cinemaVocal',
      });
      final tmp = await Directory.systemTemp.createTemp('marco_native_aud_');
      addTearDown(() => tmp.delete(recursive: true));

      final stereoWav = await _writeSynthWav(tmp, 'stereo.wav', channels: 2, durationSec: 2.0);
      final surround51Wav = await _writeSynthWav(tmp, 'surround51.wav', channels: 6, durationSec: 2.0);
      final pcmOut1 = File('${tmp.path}${Platform.pathSeparator}out_live.wav');
      final pcmOut2 = File('${tmp.path}${Platform.pathSeparator}out_restart.wav');

      final errors = <String>[];
      final player = Player(
        configuration: const PlayerConfiguration(
          vo: 'null',
          logLevel: MPVLogLevel.error,
        ),
      );
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
      );
      try {
        final dyn = player.platform as dynamic;
        await dyn.setProperty('ao', 'pcm');
        await dyn.setProperty('ao-pcm-file', pcmOut1.path);
        await dyn.setProperty('ao-pcm-waveheader', 'yes');
        await dyn.setProperty('audio-channels', 'stereo');

        final errSub = player.stream.error.listen((e) {
          if (e.trim().isNotEmpty) errors.add(e);
        });
        addTearDown(errSub.cancel);

        ctrl.attachPlayer(player);
        await ctrl.loadSaved();
        expect(ctrl.loudnessPreset, AudioLoudnessPreset.cinemaVocal);

        // Cold start with saved legacy `cinemaVocal` on 5.1 center-dialogue fixture
        expect(
          await ctrl.applyLoudnessPreset(player, ctrl.loudnessPreset, persist: false),
          isTrue,
        );
        await player.open(Media(surround51Wav.path));
        await player.stream.position
            .firstWhere((p) => p.inMilliseconds >= 350)
            .timeout(const Duration(seconds: 10));
        expect(player.state.track.audio.id, isNot('no'));

        // Live mid-playback preset cycling: light -> standard -> cinemaVocal -> off
        for (final preset in const [
          AudioLoudnessPreset.light,
          AudioLoudnessPreset.standard,
          AudioLoudnessPreset.cinemaVocal,
          AudioLoudnessPreset.off,
          AudioLoudnessPreset.standard,
        ]) {
          expect(await ctrl.applyLoudnessPreset(player, preset), isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 160));
          expect(ctrl.loudnessPreset, preset);
          expect(player.state.track.audio.id, isNot('no'));
        }

        // Episode switch (5.1 -> stereo) while `standard` preset is active
        ctrl.onMediaChanged();
        await player.open(Media(stereoWav.path));
        await player.stream.position
            .firstWhere((p) => p.inMilliseconds >= 350)
            .timeout(const Duration(seconds: 10));
        expect(player.state.track.audio.id, isNot('no'));

        await player.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      } finally {
        ctrl.dispose();
        await player.dispose();
      }

      expect(errors, isEmpty);
      final m1 = _measureWavPcm(pcmOut1);
      expect(m1.frames, greaterThan(16000));
      expect(m1.rms, greaterThan(1000.0));

      // Restart: brand new Player + reloaded controller restores saved `standard`
      final player2 = Player(
        configuration: const PlayerConfiguration(
          vo: 'null',
          logLevel: MPVLogLevel.error,
        ),
      );
      final ctrl2 = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
      );
      try {
        final dyn2 = player2.platform as dynamic;
        await dyn2.setProperty('ao', 'pcm');
        await dyn2.setProperty('ao-pcm-file', pcmOut2.path);
        await dyn2.setProperty('ao-pcm-waveheader', 'yes');
        await dyn2.setProperty('audio-channels', 'stereo');

        ctrl2.attachPlayer(player2);
        await ctrl2.loadSaved();
        expect(ctrl2.loudnessPreset, AudioLoudnessPreset.standard);
        expect(
          await ctrl2.applyLoudnessPreset(player2, ctrl2.loudnessPreset, persist: false),
          isTrue,
        );
        await player2.open(Media(surround51Wav.path));
        await player2.stream.position
            .firstWhere((p) => p.inMilliseconds >= 500)
            .timeout(const Duration(seconds: 10));
        expect(player2.state.track.audio.id, isNot('no'));
        await player2.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      } finally {
        ctrl2.dispose();
        await player2.dispose();
      }

      final m2 = _measureWavPcm(pcmOut2);
      expect(m2.frames, greaterThan(16000));
      expect(m2.rms, greaterThan(1000.0));
    },
  );

  test(
    'real libmpv-2.dll regression: 滤镜不可用时，当前影片自动恢复原声',
    skip: skipReason,
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      SharedPreferences.setMockInitialValues(<String, Object>{
        WindowsVideoQualityController.prefKeyLoudnessPreset: 'cinemaVocal',
      });
      final tmp = await Directory.systemTemp.createTemp('marco_native_rec_');
      addTearDown(() => tmp.delete(recursive: true));

      final movieFile = File('test/fixtures/cloud-playback.mkv');
      final pcmOut = File('${tmp.path}${Platform.pathSeparator}out_recovered.wav');

      final fallbackFired = Completer<void>();
      final player = Player(
        configuration: const PlayerConfiguration(
          vo: 'null',
          logLevel: MPVLogLevel.error,
        ),
      );
      final ctrl = WindowsVideoQualityController(
        platformOverride: TargetPlatform.windows,
        isOhosOverride: false,
        isWebOverride: false,
      );
      try {
        final dyn = player.platform as dynamic;
        await dyn.setProperty('vid', 'auto');
        await dyn.setProperty('ao', 'pcm');
        await dyn.setProperty('ao-pcm-file', pcmOut.path);
        await dyn.setProperty('ao-pcm-waveheader', 'yes');
        await dyn.setProperty('audio-format', 's16');
        await dyn.setProperty('audio-channels', 'stereo');

        final logs = <String>[];
        final logSub = player.stream.log.listen((e) {
          logs.add('[${e.prefix}/${e.level}] ${e.text.trim()}');
        });
        addTearDown(logSub.cancel);

        ctrl.attachPlayer(
          player,
          onLoudnessFallbackToOff: () {
            if (!fallbackFired.isCompleted) fallbackFired.complete();
          },
        );
        // Forward error stream just like PlayerScreen does.
        final errSub = player.stream.error.listen((msg) {
          logs.add('[ERR] $msg');
          if (WindowsVideoQualityController.isAudioFilterFailureMessage(msg)) {
            unawaited(
              ctrl.handleRuntimeAudioFilterFailure(
                player,
                reason: msg,
                immediate: true,
              ),
            );
          }
        });
        addTearDown(errSub.cancel);

        // Inject an unavailable filter (`dynaudnorm`) into real libmpv-2.dll!
        ctrl.debugAudioFilterOverride = 'lavfi=[dynaudnorm=f=150:g=15:p=0.95]';
        await ctrl.loadSaved();
        await ctrl.applyLoudnessPreset(
          player,
          AudioLoudnessPreset.cinemaVocal,
          persist: false,
        );

        await player.open(Media(movieFile.absolute.path));
        await fallbackFired.future.timeout(const Duration(seconds: 8));
        // Wait for recovered playback to advance and write PCM frames.
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        // ignore: avoid_print
        print('RECOVERY_DIAG: pos=${player.state.position}, dur=${player.state.duration}, completed=${player.state.completed}, aid=${player.state.track.audio.id}, logs=$logs');

        expect(ctrl.loudnessPreset, AudioLoudnessPreset.off);
        expect(player.state.track.audio.id, isNot('no'));
        expect(
          await WindowsVideoQualityController.readSavedLoudnessPreset(),
          AudioLoudnessPreset.off,
        );
        await player.stop();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      } finally {
        ctrl.dispose();
        await player.dispose();
      }

      final recovered = _measureWavPcm(pcmOut);
      // ignore: avoid_print
      print(
        'NATIVE_AUDIO_RECOVERY_PCM: frames=${recovered.frames}, rms=${recovered.rms.toStringAsFixed(1)}',
      );
      expect(recovered.frames, greaterThan(16000));
      expect(recovered.rms, greaterThan(100.0));
    },
  );

  test(
    'real libmpv-2.dll headroom guard: 0.85 FS high-level 1400 Hz signal has zero digital rail clipping across all vocal presets',
    skip: skipReason,
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final tmp = await Directory.systemTemp.createTemp('marco_native_headroom_');
      addTearDown(() => tmp.delete(recursive: true));

      // Generate a 1.5s stereo 1400 Hz sine at 0.85 full scale (-1.41 dBFS).
      const sampleRate = 48000;
      const numFrames = 72000;
      const dataBytes = numFrames * 2 * 2;
      final bytes = ByteData(44 + dataBytes);
      void writeAscii(int offset, String s) {
        for (var i = 0; i < s.length; i++) {
          bytes.setUint8(offset + i, s.codeUnitAt(i));
        }
      }
      writeAscii(0, 'RIFF');
      bytes.setUint32(4, 36 + dataBytes, Endian.little);
      writeAscii(8, 'WAVE');
      writeAscii(12, 'fmt ');
      bytes.setUint32(16, 16, Endian.little);
      bytes.setUint16(20, 1, Endian.little);
      bytes.setUint16(22, 2, Endian.little);
      bytes.setUint32(24, sampleRate, Endian.little);
      bytes.setUint32(28, sampleRate * 4, Endian.little);
      bytes.setUint16(32, 4, Endian.little);
      bytes.setUint16(34, 16, Endian.little);
      writeAscii(36, 'data');
      bytes.setUint32(40, dataBytes, Endian.little);
      var offset = 44;
      for (var i = 0; i < numFrames; i++) {
        final v = (0.85 * math.sin(2 * math.pi * 1400.0 * i / sampleRate) * 32767)
            .round()
            .clamp(-32768, 32767);
        bytes.setInt16(offset, v, Endian.little);
        bytes.setInt16(offset + 2, v, Endian.little);
        offset += 4;
      }
      final hotWav = File('${tmp.path}${Platform.pathSeparator}hot.wav');
      await hotWav.writeAsBytes(bytes.buffer.asUint8List(), flush: true);

      for (final preset in AudioLoudnessPreset.values) {
        final outWav = File('${tmp.path}${Platform.pathSeparator}hot_${preset.id}.wav');
        final player = Player(
          configuration: const PlayerConfiguration(
            vo: 'null',
            logLevel: MPVLogLevel.error,
          ),
        );
        final ctrl = WindowsVideoQualityController(
          platformOverride: TargetPlatform.windows,
          isOhosOverride: false,
          isWebOverride: false,
          persistLocally: false,
        );
        try {
          final dyn = player.platform as dynamic;
          await dyn.setProperty('ao', 'pcm');
          await dyn.setProperty('ao-pcm-file', outWav.path);
          await dyn.setProperty('ao-pcm-waveheader', 'yes');
          await dyn.setProperty('audio-format', 's16');
          await dyn.setProperty('audio-channels', 'stereo');
          ctrl.attachPlayer(player);
          expect(
            await ctrl.applyLoudnessPreset(player, preset, persist: false),
            isTrue,
          );
          final done = player.stream.completed
              .firstWhere((c) => c)
              .timeout(const Duration(seconds: 10));
          await player.open(Media(hotWav.path));
          await done;
          await player.stop();
        } finally {
          ctrl.dispose();
          await player.dispose();
        }

        final raw = outWav.readAsBytesSync();
        var dataStart = 44;
        for (var i = 12; i < raw.length - 8; i++) {
          if (raw[i] == 0x64 && raw[i + 1] == 0x61 && raw[i + 2] == 0x74 && raw[i + 3] == 0x61) {
            dataStart = i + 8;
            break;
          }
        }
        final bd = ByteData.sublistView(raw);
        final sampleCount = (raw.length - dataStart) ~/ 2;
        var rails = 0;
        var peak = 0;
        for (var i = 0; i < sampleCount; i++) {
          final s = bd.getInt16(dataStart + i * 2, Endian.little);
          if (s == -32768 || s == 32767) rails++;
          if (s.abs() > peak) peak = s.abs();
        }
        expect(rails, 0, reason: 'Preset ${preset.id} clipped $rails samples (peak=$peak)');
        expect(peak, greaterThan(25000));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
