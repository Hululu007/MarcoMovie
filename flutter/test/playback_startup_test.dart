import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/playback_startup.dart';

void main() {
  testWidgets('00:00 expires even when a decoder has accepted the URL',
      (tester) async {
    final startup = PlaybackStartup();
    var failed = false;
    startup.waitForProgress(() => failed = true);
    startup.position(Duration.zero);
    await tester.pump(const Duration(seconds: 59));
    expect(failed, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(failed, isTrue);
  });

  testWidgets('media progress prevents a timeout during later pauses',
      (tester) async {
    final startup = PlaybackStartup();
    var failures = 0;
    startup.waitForProgress(() => failures++);
    await tester.pump(const Duration(seconds: 5));
    startup.position(const Duration(milliseconds: 300));
    await tester.pump(const Duration(minutes: 6));
    expect(failures, 0);
  });

  testWidgets('switching and disposing cancel the previous startup deadline',
      (tester) async {
    final startup = PlaybackStartup();
    var failures = 0;
    startup.waitForProgress(() => failures += 100);
    await tester.pump(const Duration(seconds: 30));
    startup.waitForProgress(() => failures++);
    await tester.pump(const Duration(seconds: 30));
    expect(failures, 0);
    startup.cancel();
    await tester.pump(const Duration(minutes: 2));
    expect(failures, 0);
  });

  testWidgets(
      'single initial decoded frame at 00:00 with paused-for-cache still triggers quality fallback',
      (tester) async {
    final startup = PlaybackStartup();
    var timedOut = false;
    startup.waitForProgress(() => timedOut = true, hasFallback: true);
    // libmpv emits a single 40ms frame timestamp when Frame 0 decodes, then
    // enters paused-for-cache (buffering = true) while still at 00:00.
    startup.position(const Duration(milliseconds: 40));
    startup.updateState(playing: true, buffering: true);
    await tester.pump(const Duration(seconds: 11));
    expect(timedOut, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(timedOut, isTrue);
    expect(startup.isPastStartupWindow, isFalse);
  });

  testWidgets(
      'resuming mid-episode ignores Frame-0 seek prime until real playback advances',
      (tester) async {
    final startup = PlaybackStartup();
    var timedOut = false;
    const resumeAt = Duration(minutes: 8, seconds: 20);
    startup.waitForProgress(
      () => timedOut = true,
      hasFallback: true,
      startOffset: resumeAt,
    );
    startup.position(resumeAt + const Duration(milliseconds: 40));
    startup.updateState(playing: true, buffering: true);
    await tester.pump(const Duration(seconds: 12));
    expect(timedOut, isTrue);

    timedOut = false;
    startup.waitForProgress(
      () => timedOut = true,
      hasFallback: true,
      startOffset: resumeAt,
    );
    startup.position(resumeAt + const Duration(milliseconds: 400));
    startup.position(resumeAt + const Duration(seconds: 4));
    expect(startup.isPastStartupWindow, isTrue);
    startup.updateState(playing: true, buffering: true);
    await tester.pump(const Duration(minutes: 2));
    expect(timedOut, isFalse);
  });
}
