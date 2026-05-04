import 'dart:async';

import 'package:resilify/resilify.dart';

import '../core/clock.dart';
import '../core/logger.dart';
import 'token_keeper.dart';

/// Periodically calls [TokenKeeper.getValidToken] to keep the stored token
/// warm before it expires.
///
/// Primarily useful in **background services**, daemon processes, or any
/// context where HTTP requests may not fire frequently enough to trigger the
/// on-demand refresh in [TokenKeeper.getValidToken].
///
/// For on-demand apps (regular Flutter UI), the proactive refresh window on
/// [TokenKeeper] is usually sufficient and you don't need this class.
///
/// ### Usage
///
/// ```dart
/// final timer = TokenRefreshTimer(
///   keeper: keeper,
///   checkInterval: const Duration(minutes: 5),
/// );
/// timer.start();
///
/// // When you're done (e.g. the user logs out):
/// timer.dispose();
/// ```
///
/// Configure the keeper with a `proactiveWindow` larger than `checkInterval`
/// so the periodic tick has a chance to refresh before actual expiry:
///
/// ```dart
/// TokenKeeper(proactiveWindow: const Duration(minutes: 10), ...);
/// TokenRefreshTimer(keeper: keeper, checkInterval: const Duration(minutes: 5));
/// ```
class TokenRefreshTimer {
  /// Creates a timer. Call [start] to begin periodic checks.
  TokenRefreshTimer({
    required TokenKeeper keeper,
    this.checkInterval = const Duration(minutes: 1),
    Clock clock = const Clock(),
    TokenKeeperLogger logger = noopLogger,
  })  : _keeper = keeper,
        _clock = clock,
        _log = logger;

  /// How often to call [TokenKeeper.getValidToken]. Defaults to 1 minute.
  final Duration checkInterval;

  final TokenKeeper _keeper;
  final Clock _clock;
  final TokenKeeperLogger _log;

  Timer? _timer;
  bool _disposed = false;

  /// Whether the timer is currently running.
  bool get isRunning => _timer != null && !_disposed;

  /// Starts periodic token checks. A no-op if already running or disposed.
  void start() {
    if (_disposed || _timer != null) return;
    _log(
      LogLevel.debug,
      'TokenRefreshTimer started (interval: $checkInterval)',
    );
    _timer = Timer.periodic(checkInterval, (_) => unawaited(_tick()));
  }

  /// Stops the timer without disposing the keeper. Safe to call multiple
  /// times. Call [start] to resume.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _log(LogLevel.debug, 'TokenRefreshTimer stopped');
  }

  /// Stops the timer permanently. The [TokenRefreshTimer] cannot be restarted
  /// after this.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
  }

  Future<void> _tick() async {
    if (_disposed) return;
    _log(LogLevel.debug, 'TokenRefreshTimer tick at ${_clock.now()}');
    // getValidToken is a no-op when the token is healthy; it only refreshes
    // when expired or within the proactive window. Cheap call.
    final result = await _keeper.getValidToken();
    final failure = result.errorOrNull;
    if (failure != null) {
      _log(
        LogLevel.warning,
        'TokenRefreshTimer: background refresh check failed — '
        '${failure.message}',
        error: failure.cause,
      );
    }
  }
}
