# Changelog

All notable changes to this package will be documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-05-02

### Added

- `Token.isValid([DateTime? now])` — convenience inverse of `isExpired`;
  always `true` for tokens with no `expiresAt`.
- `Token.remainingLifetime([DateTime? now])` — returns `Duration?` until
  expiry; `null` for unknown lifetime, `Duration.zero` (never negative) when
  already expired. Useful for countdown timers and progress indicators.
- `Token.hasScope(String)`, `Token.hasAllScopes(List<String>)`,
  `Token.hasAnyScope(List<String>)` — RFC 6749 case-sensitive scope-check
  helpers; remove repetitive `scopes.contains` calls from application code.
- `Token.fromJsonOrNull(Map<String, dynamic>)` — safe deserialisation factory
  that returns `null` instead of throwing on malformed or corrupt JSON.
  Preferred at storage read boundaries.
- `Result.getOrElse(T Function() fallback)` — extracts the success value or
  calls `fallback` for a `Failure`; keeps call sites free of `switch`
  boilerplate for the common "or default" case.
- `TokenKeeper.isRefreshing` — synchronous `bool` getter; `true` while a
  refresh is actively in flight. Useful for showing loading spinners without
  subscribing to the event stream.
- `TokenKeeperInterceptor.onRefreshFailed` callback — optional hook invoked
  when a 401-triggered refresh fails. Allows navigating to login directly from
  the interceptor without a separate `events` subscription.

### Improved

- `Failure.toString()` now produces a readable
  `Failure(type: message[, cause: ...])` string instead of the default
  Equatable dump — makes test failure output immediately actionable.
- `TokenEvent` subclasses now implement `Equatable` (with `props`) so events
  can be compared with `==` directly in tests and reactive state layers
  without `.runtimeType` checks.

## [1.0.0] — 2026-05-02

### Added

- `Token` model with JSON, equality, expiry helpers, and `copyWith`.
- `Result<T>` / `Success<T>` / `Failure<T>` sealed types with `FailureType`
  enum (`unauthorized`, `network`, `unknown`).
- `TokenStorage` interface plus `InMemoryTokenStorage` implementation.
- `TokenKeeper` core with:
  - single-flight refresh (one in-flight refresh per keeper, even under
    50+ concurrent calls),
  - proactive refresh via `proactiveWindow`,
  - `withValidToken` with bounded one-shot retry on `unauthorized`,
  - `getValidToken`, `forceRefresh`, `setTokens`, `clear`, `peek`,
  - lifecycle event stream (`TokenRefreshedEvent`, `TokenClearedEvent`,
    `RefreshFailedEvent`).
- `TokenKeeperInterceptor` for Dio with attach + 401-refresh-and-retry.
- `RefreshRetryPolicy` with built-in exponential backoff factory.
- Pluggable `TokenKeeperLogger` and `Clock` / `FixedClock` for tests.
- 37 unit tests covering single-flight, proactive refresh, retry policy,
  events, interceptor 401 handling, and edge cases.
