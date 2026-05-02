import 'result.dart';
import 'token.dart';

/// Decides whether a failed refresh should be retried, and how long to wait.
///
/// Defaults to no retries (matches the spec: refresh failures surface
/// immediately so the caller can log out). Override [maxAttempts] and
/// [delayFor] to add exponential backoff.
class RefreshRetryPolicy {
  /// Creates a retry policy.
  const RefreshRetryPolicy({
    this.maxAttempts = 1,
    this.delayFor = _zeroDelay,
    this.shouldRetry = _retryOnNetworkOnly,
  });

  /// A built-in exponential-backoff policy. Retries [maxAttempts] times,
  /// doubling the [base] delay each attempt, only on transient network
  /// failures.
  factory RefreshRetryPolicy.exponential({
    int maxAttempts = 3,
    Duration base = const Duration(milliseconds: 200),
    Duration max = const Duration(seconds: 5),
  }) =>
      RefreshRetryPolicy(
        maxAttempts: maxAttempts,
        delayFor: (attempt) {
          final exp = base * (1 << (attempt - 1));
          return exp > max ? max : exp;
        },
        shouldRetry: _retryOnNetworkOnly,
      );

  /// Total attempts including the first call. `1` disables retries.
  final int maxAttempts;

  /// Delay before the next attempt. `attempt` is 1-based and counts attempts
  /// already performed (so the first call to `delayFor(1)` is the wait
  /// *before* the second attempt).
  final Duration Function(int attempt) delayFor;

  /// Predicate that decides whether to retry given the latest [Failure].
  final bool Function(Failure<Token> failure) shouldRetry;
}

Duration _zeroDelay(int _) => Duration.zero;

bool _retryOnNetworkOnly(Failure<Token> failure) =>
    failure.type == FailureType.network;
