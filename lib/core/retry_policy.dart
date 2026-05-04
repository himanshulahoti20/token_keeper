import 'dart:math';

import 'package:resilify/resilify.dart';

/// Configuration for retrying a refresh attempt.
///
/// Maps directly onto the parameters of `resilify`'s [RetryHelper.retry].
/// The default [retryIf] uses `resilify`'s [Failure.isRetryable] — true for
/// any 5xx, 408 (timeout), or 429 (rate limit) — so the refresh is retried
/// on transient errors but stops immediately on 401 (auth dead) or other
/// 4xx client errors.
class RefreshRetryConfig {
  /// Creates a config. With the defaults the refresh is attempted once and
  /// no retries are made (matches the spec of `token_keeper` 1.0.x).
  const RefreshRetryConfig({
    this.maxAttempts = 1,
    this.delay = const Duration(milliseconds: 500),
    this.maxDelay,
    this.backoffFactor = 2.0,
    this.jitter = 0.0,
    this.attemptTimeout,
    this.random,
    this.retryIf,
  })  : assert(maxAttempts > 0, 'maxAttempts must be > 0'),
        assert(backoffFactor > 0, 'backoffFactor must be > 0'),
        assert(jitter >= 0, 'jitter must be >= 0');

  /// Convenience: exponential backoff for transient (`isRetryable`) failures.
  factory RefreshRetryConfig.exponential({
    int maxAttempts = 3,
    Duration delay = const Duration(milliseconds: 200),
    Duration? maxDelay = const Duration(seconds: 5),
    double backoffFactor = 2.0,
    double jitter = 0.2,
    Duration? attemptTimeout,
  }) {
    return RefreshRetryConfig(
      maxAttempts: maxAttempts,
      delay: delay,
      maxDelay: maxDelay,
      backoffFactor: backoffFactor,
      jitter: jitter,
      attemptTimeout: attemptTimeout,
    );
  }

  /// Total attempts including the first call. `1` disables retries.
  final int maxAttempts;

  /// Base wait between attempts; doubled on each retry by [backoffFactor].
  final Duration delay;

  /// Caps the wait between attempts after backoff. `null` = no cap.
  final Duration? maxDelay;

  /// Multiplier applied to [delay] on each successive failure.
  final double backoffFactor;

  /// `[0, jitter]` randomness multiplier on the back-off; `0.0` disables.
  final double jitter;

  /// Bound for each individual attempt; exceeding it yields
  /// `Failure.timeout()`. `null` = wait indefinitely.
  final Duration? attemptTimeout;

  /// Optional [Random] source so jitter is deterministic in tests.
  final Random? random;

  /// Predicate deciding whether to retry given the latest failure. Defaults
  /// to `failure.isRetryable` (true for 5xx, 408, 429).
  final bool Function(Failure failure)? retryIf;

  /// The default retry predicate used when [retryIf] is `null`.
  static bool defaultRetryIf(Failure failure) => failure.isRetryable;
}
