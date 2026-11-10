import 'dart:async';

/// Bounds the wait for actual media progress. A decoder's `playing` flag or
/// duration alone does not mean it has read a playable frame.
class PlaybackStartup {
  PlaybackStartup({this.timeout = const Duration(seconds: 60)});
  final Duration timeout;
  Timer? _timer;

  void waitForProgress(void Function() onTimeout) {
    cancel();
    _timer = Timer(timeout, onTimeout);
  }

  void position(Duration value) {
    if (value > Duration.zero) cancel();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
