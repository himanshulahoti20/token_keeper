# Changelog

All notable changes to this package will be documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] — 2026-05-23

### Added

- **`Token.metadata`** — an optional `Map<String, dynamic>` field for
  arbitrary extra data alongside the token pair. Typical uses: tenant IDs,
  user IDs, feature flags, or any non-standard fields returned in the token
  response. Defaults to `const {}` so existing call sites are unaffected.
  Round-trips through `toJson` / `fromJson` (the `metadata` key is omitted
  from the JSON output when the map is empty). Included in `==` / `hashCode`
  via `Equatable`, and accepted by `copyWith`.

- **`Token.tryParseJwt` — auto-populates `metadata` from non-standard
  claims.** All JWT payload claims that are not part of the RFC 7519 standard
  set (`exp`, `iat`, `nbf`, `iss`, `sub`, `aud`, `jti`) or the scope claims
  (`scope`, `scp`, `scopes`) are collected into `Token.metadata`. This means
  custom claims like `tenant_id`, `role`, `org_id`, etc. are available
  immediately after parsing without extra plumbing.

- **`TokenKeeper.currentTokenStream()`** — a `Stream<Token?>` that
  immediately emits the current stored token (the result of `peek()`) and
  then forwards every subsequent change from `tokenStream`. Replaces the
  common "seed + subscribe" boilerplate:

  ```dart
  // before
  final initial = await keeper.peek();
  keeper.tokenStream.listen(...);

  // after
  keeper.currentTokenStream().listen(...);
  ```

  The first emission is `null` when storage is empty, so the stream is always
  safe to listen to regardless of auth state.

- **`TokenKeeper.onEvent<T extends TokenEvent>()`** — a typed stream of
  lifecycle events filtered to a single event type. Cleaner than calling
  `.where(...).cast<T>()` manually:

  ```dart
  keeper.onEvent<TokenRefreshedEvent>().listen((e) {
    print('refreshed: ${e.token.maskedAccessToken}');
  });

  keeper.onEvent<TokenClearedEvent>().listen((_) => router.go('/login'));
  ```

- **`TokenRefreshTimer.runNow()`** — triggers an immediate token check
  outside the normal periodic schedule. The periodic timer continues
  unaffected. Useful when the app returns from background and you want to
  proactively validate / refresh the token without waiting for the next tick.
  A no-op when the timer has already been `dispose`d.

- **`CachingTokenStorage.refresh()`** — combines `invalidate()` + `read()`
  into a single async call. Returns the freshly loaded token (`null` if the
  backing store is empty). Handy after a cross-isolate write where the
  in-memory cache is known to be stale:

  ```dart
  final fresh = await cachingStorage.refresh();
  ```

## [1.1.2] — 2026-05-15

### Added

- **`Token.maskedAccessToken`** — partially-redacted access-token string
  (`abcd…wxyz`) safe to drop into logs and crash reports. Tokens of 8
  characters or fewer are fully redacted as `***`.
- **`Token.expiresInSeconds([DateTime? now])`** — convenience getter that
  mirrors the OAuth 2.0 `expires_in` field. Returns the whole-second count
  until expiry (`0` for already-expired, `null` when expiry is unknown), so
  re-serializing a token to a refresh-response body is one call.
- **`CachingTokenStorage.warmup()`** — eagerly populates the cache from the
  backing store. Call once during app startup so the first `read()` on the
  request hot path skips disk I/O.
- **`CachingTokenStorage.isCached`** — synchronous bool getter that
  distinguishes "no token stored" from "we haven't checked yet" without an
  `await`.
- **`InMemoryTokenStorage.snapshot`** — synchronous peek at the persisted
  token; intended for test assertions that don't want to `await read()`.
- **`InMemoryTokenStorage.clone()`** — returns a new instance seeded with the
  current token; useful in tests when you need a decoupled copy that evolves
  independently.
- **`TokenKeeper.refreshIfNeeded()`** — alias of [`getValidToken`] that reads
  more naturally at call sites that don't immediately consume the token (e.g.
  background warmups, pre-flight checks). Identical behaviour and identical
  single-flight semantics.

### Improved

- **Event `toString()`** — `TokenRefreshedEvent`, `TokenClearedEvent`, and
  `RefreshFailedEvent` now produce single-line, redacted debug strings
  instead of falling back to the default `Equatable` form. Logs and test
  failure output are immediately readable; the access token is shown via
  `Token.maskedAccessToken` so secrets stay out of log files.

## [1.1.1] — 2026-05-04

### Added

- **`Token.requiresRefresh()`** — convenience method that returns `true` when
  the token will expire within the next 5 minutes (configurable via `window`
  parameter). Simplifies proactive refresh logic without manual expiry buffer
  management.
- **`Token.isValidWithAllScopes(List<String>)`** — combines expiry and scope
  checks in a single call; returns `true` if the token is valid and grants
  **all** required scopes. Reduces boilerplate at request boundaries.
- **`Token.isValidWithAnyScope(List<String>)`** — combines expiry and scope
  checks in a single call; returns `true` if the token is valid and grants
  **at least one** of the specified scopes.

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
