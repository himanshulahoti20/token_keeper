# Changelog

All notable changes to this package will be documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-05-04

> **Major upgrade.** This release replaces the package's home-grown
> `Result<T>` / `Failure<T>` types with the unified
> [`resilify`](https://pub.dev/packages/resilify) `Result` / `Failure` model
> so authentication errors share the same vocabulary as the rest of your
> networking stack. **It contains breaking changes** — see "Migration" below.

### Added

- **`resilify` integration** — `Result<T>`, `Success<T>`, `Error<T>`, and
  the rich [`Failure`](https://pub.dev/packages/resilify) value type
  (with named constructors `unauthorized`, `network`, `timeout`,
  `serverError`, `rateLimit`, …) are re-exported from
  `package:token_keeper/token_keeper.dart`. Callers no longer need to
  import `resilify` directly; it comes along for the ride.
- **`RefreshRetryConfig`** — wraps `resilify`'s `RetryHelper.retry`. Same
  exponential / jitter / `attemptTimeout` machinery used everywhere else in
  the resilify ecosystem. The default `retryIf` is `failure.isRetryable`,
  so 5xx / 408 / 429 are retried but 401 (auth dead) is not.
- **`Token.tryParseJwt(String, {String? refreshToken})`** — pure-Dart JWT
  parser (base64url + JSON, no signature verification) that auto-fills
  `expiresAt` from the `exp` claim and `scopes` from `scope` / `scp` /
  `scopes` claims. Returns `null` on bad input; never throws.
- **`Token.hasScope` / `hasAllScopes` / `hasAnyScope`** — RFC 6749
  case-sensitive scope check helpers (carried over from 1.0.x).
- **`CachingTokenStorage`** — decorator that wraps any `TokenStorage`
  backend with an in-memory cache so hot-path reads avoid disk I/O. Exposes
  `cachedToken` (sync read of the cache) and `invalidate()` for
  cross-isolate scenarios.
- **`TokenKeeper.tokenStream`** (`Stream<Token?>`) — reactive stream of
  token changes. Emits the new `Token` after refresh / `setTokens`, and
  `null` after `clear()` or unauthorized refresh failure.
- **`TokenRefreshTimer`** — periodic background timer that calls
  `getValidToken()` on a configurable interval. For long-lived services
  that don't naturally exercise the keeper through requests.
- **`TokenKeeper.isRefreshing`** — synchronous `bool`; true while a
  refresh is in flight (carried over from 1.0.1).
- **`TokenKeeperInterceptor.onRefreshFailed`** — callback receives the
  resilify `Failure` (carried over from 1.0.1).

### Changed (BREAKING)

- The shape of `Result<T>` / `Failure` is now defined by `resilify`:
  - `Failure<T>` (generic) → `Failure` (non-generic value type with `code`,
    `message`, `cause`, `stackTrace`).
  - `Success<T>(value)` → `Success<T>(data)` — the field name changed.
  - `Failure<T>(message: x, type: FailureType.unauthorized)` →
    `Failure.unauthorized(message: x)` (or any other named constructor).
  - The `FailureType` enum is removed; categorise failures by HTTP `code`
    or use `Failure.is4xx` / `is5xx` / `isRetryable` getters.
- `result.fold(onSuccess:, onFailure:)` (named) →
  `result.fold(onSuccess, onError)` (positional, matches resilify).
- `result.value` (on `Success`) → `result.data`. `result.valueOrNull` →
  `result.dataOrNull`.
- `Failure<Token>` in `RefreshFailedEvent` is now plain `Failure`.
- `TokenKeeper(retryPolicy: RefreshRetryPolicy.exponential(...))` →
  `TokenKeeper(retryConfig: RefreshRetryConfig.exponential(...))`.

### Migration (1.0.x → 1.1.0)

```dart
// before
return const Failure(message: 'no token', type: FailureType.unauthorized);
// after
return const Error(Failure.unauthorized(message: 'no token'));

// before
if (firstAttempt.type == FailureType.unauthorized) { /* retry */ }
// after
if (firstAttempt.failure.code == 401) { /* retry */ }

// before
result.fold(onSuccess: (t) => ..., onFailure: (f) => ...);
// after
result.fold((t) => ..., (f) => ...);          // positional
// or
result.when(success: (t) => ..., error: (f) => ...);

// before
TokenKeeper(retryPolicy: RefreshRetryPolicy.exponential(maxAttempts: 3));
// after
TokenKeeper(retryConfig: RefreshRetryConfig.exponential(maxAttempts: 3));
```

> **`dart:core.Error` collision** — `resilify`'s `Error<T>` variant
> shadows `dart:core.Error`. If you need both in the same file, hide one:
> `import 'dart:core' hide Error;`

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
