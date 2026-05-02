# Changelog

All notable changes to this package will be documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
