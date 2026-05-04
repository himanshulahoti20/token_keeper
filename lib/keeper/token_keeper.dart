import 'dart:async';

import 'package:resilify/resilify.dart';

import '../core/clock.dart';
import '../core/events.dart';
import '../core/logger.dart';
import '../core/retry_policy.dart';
import '../core/token.dart';
import '../storage/token_storage.dart';

/// A function that exchanges the [current] token for a fresh one.
///
/// Implementations MUST NOT throw — return `Error(Failure.unauthorized(...))`
/// or `Error(Failure.network(...))` instead. Use [Failure.unauthorized] (or
/// any 401-coded failure) to indicate that the refresh token is no longer
/// valid: this triggers [TokenKeeper] to clear storage and emit a
/// [TokenClearedEvent]. Other failures are surfaced via [RefreshFailedEvent]
/// without clearing storage so the caller can retry later.
typedef TokenRefresher = Future<Result<Token>> Function(Token current);

/// Coordinates access-token retrieval, proactive refresh, single-flight
/// refresh, and authenticated operation retry — built on top of
/// [`resilify`](https://pub.dev/packages/resilify) so failure handling is
/// unified with the rest of your networking stack.
///
/// Guarantees:
/// * exactly one refresh runs at a time, even under 50+ concurrent calls,
/// * no method on the public surface throws,
/// * lifecycle events are observable through [events] and [tokenStream].
class TokenKeeper {
  /// Creates a keeper.
  ///
  /// * [storage] persists the current token between calls.
  /// * [refresher] performs the actual refresh API call.
  /// * [proactiveWindow] — refresh ahead of expiry by this much time. Set to
  ///   [Duration.zero] (default) to refresh only after expiry.
  /// * [clock] — injectable for tests.
  /// * [retryConfig] — controls retries inside a single refresh attempt.
  /// * [logger] — observability hook.
  TokenKeeper({
    required TokenStorage storage,
    required TokenRefresher refresher,
    Duration proactiveWindow = Duration.zero,
    Clock clock = const Clock(),
    RefreshRetryConfig retryConfig = const RefreshRetryConfig(),
    TokenKeeperLogger logger = noopLogger,
  })  : _storage = storage,
        _refresher = refresher,
        _proactiveWindow = proactiveWindow,
        _clock = clock,
        _retry = retryConfig,
        _log = logger;

  final TokenStorage _storage;
  final TokenRefresher _refresher;
  final Duration _proactiveWindow;
  final Clock _clock;
  final RefreshRetryConfig _retry;
  final TokenKeeperLogger _log;

  final StreamController<TokenEvent> _eventsController =
      StreamController<TokenEvent>.broadcast();

  final StreamController<Token?> _tokenStreamController =
      StreamController<Token?>.broadcast();

  /// In-flight refresh, or `null` when no refresh is running.
  ///
  /// Only mutated synchronously; see the comments on [_runRefresh] for the
  /// invariants we rely on.
  Completer<Result<Token>>? _refreshCompleter;

  bool _disposed = false;

  /// Lifecycle events. Use this to drive logout flows or UI feedback.
  Stream<TokenEvent> get events => _eventsController.stream;

  /// Reactive stream of token changes.
  ///
  /// Emits the new [Token] after a successful refresh or [setTokens] call.
  /// Emits `null` after [clear] or an unauthorized refresh failure.
  ///
  /// Does not replay the current value to late subscribers — combine with
  /// [peek] to seed your state management layer:
  ///
  /// ```dart
  /// final initial = await keeper.peek();
  /// keeper.tokenStream.listen(...);
  /// ```
  Stream<Token?> get tokenStream => _tokenStreamController.stream;

  /// `true` while a refresh call is actively in flight.
  ///
  /// Synchronous read — useful for showing a loading indicator without
  /// subscribing to [events].
  bool get isRefreshing => _refreshCompleter != null;

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
  /// Returns `Error(Failure.unauthorized(...))` if there is no token at all,
  /// or if the refresh failed because the refresh token was rejected.
  Future<Result<Token>> getValidToken() async {
    _checkNotDisposed();
    final current = await _storage.read();
    if (current == null) {
      return const Error<Token>(
        Failure.unauthorized(message: 'No token in storage'),
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
      return const Error<Token>(
        Failure.unauthorized(message: 'No token to refresh'),
      );
    }
    return _runRefresh(current);
  }

  /// Runs [operation] with a valid token, retrying once if the operation
  /// returns a 401-coded failure (`Failure.unauthorized` or any
  /// `failure.code == 401`).
  ///
  /// The retry is bounded to a single additional attempt to avoid loops; if
  /// the second call also fails, that failure is returned to the caller.
  Future<Result<R>> withValidToken<R>(
    Future<Result<R>> Function(Token token) operation,
  ) async {
    _checkNotDisposed();
    final initial = await getValidToken();
    if (initial is Error<Token>) return Error<R>(initial.failure);
    final firstToken = (initial as Success<Token>).data;

    final firstAttempt = await operation(firstToken);
    if (firstAttempt is! Error<R>) return firstAttempt;
    if (firstAttempt.failure.code != 401) return firstAttempt;

    _log(LogLevel.debug, 'operation returned 401; refreshing and retrying');

    final refreshed = await forceRefresh();
    if (refreshed is Error<Token>) return Error<R>(refreshed.failure);
    return operation((refreshed as Success<Token>).data);
  }

  /// Closes event streams and releases internal state.
  ///
  /// After disposal, no further calls to public methods should be made.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventsController.close();
    await _tokenStreamController.close();
  }

  // ---- internals ----------------------------------------------------------

  bool _needsRefresh(Token token) {
    final now = _clock.now();
    if (token.isExpired(now)) return true;
    if (_proactiveWindow == Duration.zero) return false;
    return token.willExpireWithin(_proactiveWindow, now);
  }

  /// Single-flight gate around the actual refresh work.
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

    unawaited(_executeFlight(current, completer));
    return completer.future;
  }

  Future<void> _executeFlight(
    Token current,
    Completer<Result<Token>> completer,
  ) async {
    final result = await _runWithRetry(current);

    // Side-effects BEFORE completing the completer so observers and awaiters
    // see a consistent storage state.
    if (result is Success<Token>) {
      await _storage.write(result.data);
      _emit(TokenRefreshedEvent(result.data));
    } else if (result is Error<Token>) {
      _emit(RefreshFailedEvent(result.failure));
      if (result.failure.code == 401) {
        await _storage.delete();
        _emit(const TokenClearedEvent());
      }
    }

    // Clear BEFORE completing so awaiter continuations see a fresh state.
    _refreshCompleter = null;
    completer.complete(result);
  }

  /// Wraps the [_refresher] in `resilify`'s [RetryHelper.retry] so the
  /// existing back-off / jitter / attemptTimeout machinery is reused.
  Future<Result<Token>> _runWithRetry(Token current) {
    return RetryHelper.retry<Token>(
      () => Result.tryRunAsync<Token>(
        () async {
          final r = await _refresher(current);
          // Bridge a returned Error<Token> to a thrown failure so RetryHelper
          // sees it; tryRunAsync re-wraps the catch into Error<Token>.
          if (r is Error<Token>) throw _RefresherError(r.failure);
          return (r as Success<Token>).data;
        },
        onError: (e, st) {
          if (e is _RefresherError) {
            return e.failure.copyWith(stackTrace: st);
          }
          return Failure.unknown(
            message: 'Refresher threw: $e',
            cause: e,
            stackTrace: st,
          );
        },
      ),
      maxAttempts: _retry.maxAttempts,
      delay: _retry.delay,
      maxDelay: _retry.maxDelay,
      backoffFactor: _retry.backoffFactor,
      jitter: _retry.jitter,
      random: _retry.random,
      attemptTimeout: _retry.attemptTimeout,
      retryIf: _retry.retryIf ?? RefreshRetryConfig.defaultRetryIf,
      onRetry: (attempt, failure) => _log(
        LogLevel.warning,
        'refresh attempt $attempt failed: ${failure.message} '
        '(code: ${failure.code})',
        error: failure.cause,
      ),
    );
  }

  void _emit(TokenEvent event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
    if (!_tokenStreamController.isClosed) {
      switch (event) {
        case TokenRefreshedEvent(:final token):
          _tokenStreamController.add(token);
        case TokenClearedEvent():
          _tokenStreamController.add(null);
        case RefreshFailedEvent():
          break;
      }
    }
  }

  void _checkNotDisposed() {
    assert(!_disposed, 'TokenKeeper has been disposed');
  }
}

/// Internal wrapper used to smuggle a [Failure] returned by the refresher
/// through [Result.tryRunAsync] without losing fidelity.
class _RefresherError implements Exception {
  _RefresherError(this.failure);
  final Failure failure;

  @override
  String toString() => 'RefresherError($failure)';
}
