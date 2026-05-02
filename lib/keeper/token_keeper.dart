import 'dart:async';

import '../core/clock.dart';
import '../core/events.dart';
import '../core/logger.dart';
import '../core/result.dart';
import '../core/retry_policy.dart';
import '../core/token.dart';
import '../storage/token_storage.dart';

/// A function that exchanges the [current] token for a fresh one.
///
/// Implementations MUST NOT throw — return a [Failure] instead. Use
/// [FailureType.unauthorized] to indicate that the refresh token is no longer
/// valid (which causes [TokenKeeper] to clear storage and emit
/// [TokenClearedEvent]); use [FailureType.network] for transient errors that
/// the [RefreshRetryPolicy] may retry.
typedef TokenRefresher = Future<Result<Token>> Function(Token current);

/// Coordinates access-token retrieval, proactive refresh, single-flight
/// refresh, and authenticated operation retry.
///
/// `TokenKeeper` is the single source of truth for "do I have a valid token
/// right now?". It guarantees that:
///
/// * exactly one refresh runs at a time, even under 50+ concurrent calls,
/// * no method on the public surface throws,
/// * lifecycle events are observable through [events].
///
/// Construct one per authenticated session and dispose with [dispose] when
/// you tear the session down.
class TokenKeeper {
  /// Creates a keeper.
  ///
  /// * [storage] persists the current token between calls.
  /// * [refresher] performs the actual refresh API call.
  /// * [proactiveWindow] — refresh ahead of expiry by this much time. Set to
  ///   [Duration.zero] (default) to refresh only after expiry.
  /// * [clock] — injectable for tests.
  /// * [retryPolicy] — controls retries inside a single refresh attempt.
  /// * [logger] — observability hook.
  TokenKeeper({
    required TokenStorage storage,
    required TokenRefresher refresher,
    Duration proactiveWindow = Duration.zero,
    Clock clock = const Clock(),
    RefreshRetryPolicy retryPolicy = const RefreshRetryPolicy(),
    TokenKeeperLogger logger = noopLogger,
  })  : _storage = storage,
        _refresher = refresher,
        _proactiveWindow = proactiveWindow,
        _clock = clock,
        _retryPolicy = retryPolicy,
        _log = logger;

  final TokenStorage _storage;
  final TokenRefresher _refresher;
  final Duration _proactiveWindow;
  final Clock _clock;
  final RefreshRetryPolicy _retryPolicy;
  final TokenKeeperLogger _log;

  final StreamController<TokenEvent> _eventsController =
      StreamController<TokenEvent>.broadcast();

  /// In-flight refresh, or `null` when no refresh is running.
  ///
  /// Only mutated synchronously; see the comments on [_runRefresh] for the
  /// invariants we rely on.
  Completer<Result<Token>>? _refreshCompleter;

  bool _disposed = false;

  /// Lifecycle events. Use this to drive logout flows or UI feedback.
  Stream<TokenEvent> get events => _eventsController.stream;

  /// Returns the stored token without touching the network.
  ///
  /// Useful for UI bootstrapping (e.g. "are we logged in at all?"). Does NOT
  /// trigger a refresh even if the token is expired.
  Future<Token?> peek() => _storage.read();

  /// Persists [token]. Emits [TokenRefreshedEvent].
  Future<void> setTokens(Token token) async {
    _checkNotDisposed();
    await _storage.write(token);
    _emit(TokenRefreshedEvent(token));
  }

  /// Wipes stored credentials and emits [TokenClearedEvent].
  ///
  /// This is the canonical "log the user out" call. Safe to call multiple
  /// times.
  Future<void> clear() async {
    _checkNotDisposed();
    await _storage.delete();
    _emit(const TokenClearedEvent());
  }

  /// Returns a token that is currently valid, refreshing if needed.
  ///
  /// Returns [Failure] with [FailureType.unauthorized] if there is no token
  /// at all, or if the refresh fails because the refresh token was rejected.
  Future<Result<Token>> getValidToken() async {
    _checkNotDisposed();
    final current = await _storage.read();
    if (current == null) {
      return const Failure<Token>(
        message: 'No token in storage',
        type: FailureType.unauthorized,
      );
    }
    if (!_needsRefresh(current)) return Success<Token>(current);
    return _runRefresh(current);
  }

  /// Forces a refresh, regardless of expiry.
  ///
  /// If a refresh is already in flight, the existing one is reused — this
  /// preserves the single-flight guarantee.
  Future<Result<Token>> forceRefresh() async {
    _checkNotDisposed();
    final current = await _storage.read();
    if (current == null) {
      return const Failure<Token>(
        message: 'No token to refresh',
        type: FailureType.unauthorized,
      );
    }
    return _runRefresh(current);
  }

  /// Runs [operation] with a valid token, retrying once if the operation
  /// returns [FailureType.unauthorized] (e.g. a 401 from the server).
  ///
  /// The retry is bounded to a single additional attempt to avoid loops; if
  /// the second call also fails, that failure is returned to the caller.
  Future<Result<R>> withValidToken<R>(
    Future<Result<R>> Function(Token token) operation,
  ) async {
    _checkNotDisposed();
    final initial = await getValidToken();
    if (initial is Failure<Token>) return initial.cast<R>();
    final firstToken = (initial as Success<Token>).value;

    final firstAttempt = await operation(firstToken);
    if (firstAttempt is! Failure<R>) return firstAttempt;
    if (firstAttempt.type != FailureType.unauthorized) return firstAttempt;

    _log(LogLevel.debug, 'operation returned 401; refreshing and retrying');

    final refreshed = await forceRefresh();
    if (refreshed is Failure<Token>) return refreshed.cast<R>();
    return operation((refreshed as Success<Token>).value);
  }

  /// Closes the events stream and releases internal state.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventsController.close();
  }

  // ---- internals ----------------------------------------------------------

  bool _needsRefresh(Token token) {
    final now = _clock.now();
    if (token.isExpired(now)) return true;
    if (_proactiveWindow == Duration.zero) return false;
    return token.willExpireWithin(_proactiveWindow, now);
  }

  /// Single-flight gate around [_doRefresh].
  ///
  /// Invariant: setting `_refreshCompleter = null` happens *before*
  /// `completer.complete(...)`. Because Dart resumes awaiters on microtasks
  /// scheduled by `complete`, every awaiter observes a cleared field in its
  /// continuation. Concurrent callers that arrive while a flight is active
  /// see a non-null completer and join it.
  Future<Result<Token>> _runRefresh(Token current) {
    final inflight = _refreshCompleter;
    if (inflight != null) {
      _log(LogLevel.debug, 'refresh already in flight; joining');
      return inflight.future;
    }
    final completer = Completer<Result<Token>>();
    _refreshCompleter = completer;

    // Kick off the actual work without awaiting it here — we want to return
    // `completer.future` synchronously so the next caller can join.
    unawaited(_executeFlight(current, completer));
    return completer.future;
  }

  Future<void> _executeFlight(
    Token current,
    Completer<Result<Token>> completer,
  ) async {
    Result<Token> result;
    try {
      result = await _doRefreshWithRetries(current);
    } catch (error, stackTrace) {
      // Defensive: refreshers should not throw, but if one does we surface
      // it as a Failure rather than letting it escape into awaiter futures.
      _log(
        LogLevel.error,
        'refresher threw',
        error: error,
        stackTrace: stackTrace,
      );
      result = Failure<Token>(
        message: 'Refresher threw: $error',
        type: FailureType.unknown,
        cause: error,
      );
    }

    // Side-effects BEFORE completing the completer so that observers and
    // awaiters always see a consistent storage state.
    if (result is Success<Token>) {
      await _storage.write(result.value);
      _emit(TokenRefreshedEvent(result.value));
    } else if (result is Failure<Token>) {
      _emit(RefreshFailedEvent(result));
      if (result.type == FailureType.unauthorized) {
        await _storage.delete();
        _emit(const TokenClearedEvent());
      }
    }

    // Clear BEFORE completing so awaiter continuations see a fresh state.
    _refreshCompleter = null;
    completer.complete(result);
  }

  Future<Result<Token>> _doRefreshWithRetries(Token current) async {
    var attempt = 0;
    Failure<Token>? lastFailure;
    while (attempt < _retryPolicy.maxAttempts) {
      attempt++;
      _log(LogLevel.debug, 'refresh attempt $attempt');
      final result = await _refresher(current);
      if (result is Success<Token>) {
        _log(LogLevel.info, 'refresh succeeded on attempt $attempt');
        return result;
      }
      lastFailure = result as Failure<Token>;
      _log(
        LogLevel.warning,
        'refresh attempt $attempt failed: ${lastFailure.message} '
        '(${lastFailure.type.name})',
        error: lastFailure.cause,
      );
      if (attempt >= _retryPolicy.maxAttempts) break;
      if (!_retryPolicy.shouldRetry(lastFailure)) break;
      final delay = _retryPolicy.delayFor(attempt);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
    }
    return lastFailure ??
        const Failure<Token>(
          message: 'Refresh failed with no result',
          type: FailureType.unknown,
        );
  }

  void _emit(TokenEvent event) {
    if (_eventsController.isClosed) return;
    _eventsController.add(event);
  }

  void _checkNotDisposed() {
    assert(!_disposed, 'TokenKeeper has been disposed');
  }
}
