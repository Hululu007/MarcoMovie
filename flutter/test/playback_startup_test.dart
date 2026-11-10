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
}
