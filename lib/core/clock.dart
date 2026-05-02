/// A pluggable clock used by [TokenKeeper] so tests can control time.
///
/// In production the default [Clock] reads `DateTime.now()`. Tests can pass a
/// [FixedClock] to advance time deterministically.
class Clock {
  /// Creates a real clock backed by `DateTime.now()`.
  const Clock();

  /// Returns the current wall-clock time.
  DateTime now() => DateTime.now();
}

/// A test-only clock whose time is set explicitly.
///
/// ```dart
/// final clock = FixedClock(DateTime.utc(2025));
/// clock.advance(const Duration(minutes: 5));
/// ```
class FixedClock implements Clock {
  /// Creates a clock pinned to [_now].
  FixedClock(this._now);

  DateTime _now;

  @override
  DateTime now() => _now;

  /// Moves the clock forward by [duration].
  void advance(Duration duration) => _now = _now.add(duration);

  /// Replaces the current time with [time].
  void setTime(DateTime time) => _now = time;
}
