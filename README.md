# token_keeper

[![pub version](https://img.shields.io/pub/v/token_keeper.svg)](https://pub.dev/packages/token_keeper)
[![pub points](https://img.shields.io/pub/points/token_keeper)](https://pub.dev/packages/token_keeper/score)
[![pub likes](https://img.shields.io/pub/likes/token_keeper)](https://pub.dev/packages/token_keeper/score)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![CI](https://github.com/himanshulahoti20/token_keeper/actions/workflows/dart_ci.yml/badge.svg?branch=main&cache_bust=1)

<!-- tech -->
[![Flutter ≥3.10](https://img.shields.io/badge/flutter-%E2%89%A53.10-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart ≥3.3](https://img.shields.io/badge/dart-%E2%89%A53.3-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![platforms](https://img.shields.io/badge/platform-android%20%7C%20ios%20%7C%20macos%20%7C%20web%20%7C%20linux%20%7C%20windows-lightgrey)](https://pub.dev/packages/token_keeper)

> Auth tokens, handled — powered by [`resilify`](https://pub.dev/packages/resilify).

A pure-Dart token manager that gives you **single-flight refresh**,
**proactive expiry**, **clean `Result<T>` APIs** (via `resilify`),
**reactive token streams**, **JWT parsing with metadata extraction**,
a **caching storage decorator**, a **background refresh timer**, and a
drop-in **Dio interceptor** — without locking you into a transport, storage
backend, or auth scheme.

No exceptions cross the public surface. No global state. No Flutter
dependency in the core. No surprise duplicate refresh calls when 50 requests
fire at once.

## Why

Every Flutter/Dart app reinvents the same wheel: store an access token, store
a refresh token, attach the header, watch for `401`, refresh, retry, debounce
the refresh, log out on permanent failure. Most implementations get
concurrency wrong (two refreshes for the same response burst) or leak
exceptions through `try/catch` mazes.

`token_keeper` is the small, well-tested core that gets it right — it shares
its `Result` / `Failure` model with `resilify`, so token errors slot into the
same vocabulary as the rest of your API stack.

## Features

- **Single-flight refresh** — exactly one in-flight refresh per keeper, even
  under 50+ concurrent callers.
- **Proactive refresh** — refresh `N` seconds before expiry, not after.
- **`Result<T>` everywhere (resilify)** — `Success<T>(data)` or
  `Error<T>(Failure.unauthorized() | Failure.network() | …)`. Public methods
  never throw.
- **Backoff + jitter on refresh** — via `resilify`'s `RetryHelper.retry`
  under the hood. Built-in `RefreshRetryConfig.exponential`.
- **`withValidToken`** — wrap any operation; auto-refresh + one bounded
  retry on `401`. No infinite loops.
- **`Token.metadata`** — arbitrary `Map<String, dynamic>` for extra claims
  (tenant IDs, roles, feature flags). Populated automatically from
  non-standard JWT payload claims by `tryParseJwt`.
- **`currentTokenStream()`** — seeded stream that immediately emits the
  current stored token, then forwards every subsequent change. Replaces the
  common seed-then-subscribe boilerplate.
- **`onEvent<T>()`** — typed event stream filter; subscribe directly to the
  event type you care about (`TokenRefreshedEvent`, `TokenClearedEvent`,
  `RefreshFailedEvent`) without manual casting.
- **Reactive `tokenStream`** — `Stream<Token?>` of token changes.
- **Lifecycle events** — `TokenRefreshedEvent`, `TokenClearedEvent`,
  `RefreshFailedEvent` on a broadcast `Stream`.
- **`Token.tryParseJwt`** — pure-Dart JWT parser, auto-fills `expiresAt`,
  scopes, and `metadata` from claims; returns `null` on bad input.
- **`CachingTokenStorage`** — in-memory cache decorator on top of any
  backend (e.g. `flutter_secure_storage`). Includes `refresh()` for a
  combined invalidate + reload in one call.
- **`TokenRefreshTimer`** — periodic background refresh for long-lived
  services, with `runNow()` for immediate out-of-schedule checks.
- **Dio interceptor** — attaches `Authorization`, retries once on `401`.
- **Pluggable clock & logger** — `FixedClock` for tests, `TokenKeeperLogger`
  hook with zero logging dependency.

## Install

```yaml
dependencies:
  token_keeper: ^1.2.0
  # Pulled in transitively, but list it if you import resilify directly.
  # resilify: ^1.0.6
```

If you want the Dio integration, also depend on `dio: ^5`.

## Quick start

```dart
import 'package:token_keeper/token_keeper.dart';
import 'package:token_keeper/dio.dart';
import 'package:dio/dio.dart';

final keeper = TokenKeeper(
  // Caching layer keeps reads off disk on the hot path.
  storage: CachingTokenStorage(InMemoryTokenStorage()),
  refresher: (current) async {
    // Hit your /auth/refresh and return Success(newToken) or
    // Error(Failure.x(...)).
    try {
      final res = await refreshDio.post('/auth/refresh',
          data: {'refresh': current.refreshToken});
      if (res.statusCode == 401) {
        return const Error(Failure.unauthorized(message: 'revoked'));
      }
      return Success(Token(
        accessToken: res.data['access_token'] as String,
        refreshToken: res.data['refresh_token'] as String?,
        expiresAt: DateTime.now()
            .add(Duration(seconds: res.data['expires_in'])),
      ));
    } catch (e) {
      return Error(Failure.network(cause: e));
    }
  },
  proactiveWindow: const Duration(seconds: 30),
  retryConfig: RefreshRetryConfig.exponential(maxAttempts: 3),
);

// Wire Dio.
final api = Dio();
api.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: api));

// Seed + subscribe in one call — emits the current token immediately,
// then every subsequent change.
keeper.currentTokenStream().listen((token) {
  if (token == null) navigator.toLogin();
});

// Or subscribe to a specific event type.
keeper.onEvent<TokenClearedEvent>().listen((_) => navigator.toLogin());

// Seed after login.
await keeper.setTokens(Token(accessToken: '...', refreshToken: '...', expiresAt: ...));

// Use Dio normally — refresh + retry happens transparently.
final me = await api.get('/me');
```

## API reference

### `Token`

| Field | Type | Notes |
| --- | --- | --- |
| `accessToken` | `String` | bearer token |
| `refreshToken` | `String?` | nullable for client-credentials flows |
| `expiresAt` | `DateTime?` | null = non-expiring |
| `scopes` | `List<String>` | granted scopes |
| `metadata` | `Map<String, dynamic>` | extra claims; defaults to `{}` |

```dart
// Lifecycle
token.isExpired();                                  // ignores null expiry
token.isValid();                                    // inverse of isExpired
token.willExpireWithin(const Duration(seconds: 30));
token.requiresRefresh();                            // default 5-min window
token.remainingLifetime();                          // Duration?
token.expiresInSeconds();                           // OAuth-style int?

// Scope checks
token.hasScope('read:profile');
token.hasAllScopes(['read:profile', 'write:profile']);
token.hasAnyScope(['admin', 'owner']);
token.isValidWithAllScopes(['read:profile']);       // expiry + scopes
token.isValidWithAnyScope(['admin', 'owner']);      // expiry + scopes

// Construction / serialization
token.copyWith(accessToken: 'x', clearRefreshToken: true);
token.copyWith(metadata: {'tenant': 'acme'});
Token.fromJson(token.toJson());
Token.fromJsonOrNull(maybeCorruptJson);             // null on bad input
Token.tryParseJwt(jwt, refreshToken: rt);           // null on bad input;
                                                    // populates metadata from
                                                    // non-standard JWT claims
// Logging-safe representation
print(token.maskedAccessToken);                     // "eyJh…sR2c"
```

#### `Token.metadata`

`metadata` carries arbitrary extra data alongside the token pair. When you
call `Token.tryParseJwt`, all non-standard JWT payload claims are captured
automatically. Standard claims (`exp`, `iat`, `nbf`, `iss`, `sub`, `aud`,
`jti`, `scope`, `scp`, `scopes`) are excluded.

```dart
// From a JWT with custom claims
final token = Token.tryParseJwt(jwtString);
print(token!.metadata['tenant_id']);  // e.g. 'acme'
print(token.metadata['role']);        // e.g. 'admin'

// Or set it directly
final t = Token(
  accessToken: '...',
  metadata: {'tenant_id': 'acme', 'role': 'admin'},
);
```

`metadata` is included in `==` / `hashCode` (via `Equatable`), round-trips
through `toJson` / `fromJson`, and is accepted by `copyWith`. The `metadata`
key is omitted from JSON output when the map is empty.

### `Result<T>` and `Failure` (re-exported from `resilify`)

```dart
sealed class Result<T> { ... }
final class Success<T> extends Result<T> { final T data; }
final class Error<T>   extends Result<T> { final Failure failure; }

class Failure {
  final int?    code;          // HTTP status or domain-specific code
  final String  message;
  final Object? cause;
  final StackTrace? stackTrace;

  // Named constructors:
  const Failure.unauthorized({String message = '...', ...});
  const Failure.network({...});
  const Failure.timeout({...});
  const Failure.serverError({...});
  const Failure.rateLimit({...});
  // ...

  bool get is4xx;
  bool get is5xx;
  bool get isRetryable;        // 5xx + 408 + 429
}
```

Helpers: `result.fold(onSuccess, onError)` (positional),
`result.when(success: , error: )`, `result.dataOrNull`,
`result.errorOrNull`, `result.getOrElse(() => fallback)`,
`result.map(transform)`.

> **`dart:core.Error` collision** — `resilify`'s `Error<T>` variant
> shadows `dart:core.Error`. If you need both in the same file, hide one:
> `import 'dart:core' hide Error;`

### `TokenKeeper`

```dart
TokenKeeper({
  required TokenStorage storage,
  required TokenRefresher refresher,
  Duration proactiveWindow = Duration.zero,
  Clock clock = const Clock(),
  RefreshRetryConfig retryConfig = const RefreshRetryConfig(),
  TokenKeeperLogger logger = noopLogger,
});

Future<Result<Token>> getValidToken();
Future<Result<Token>> refreshIfNeeded();        // alias of getValidToken
Future<Result<R>>     withValidToken<R>(Future<Result<R>> Function(Token) op);
Future<Result<Token>> forceRefresh();
Future<void>          setTokens(Token token);
Future<void>          clear();
Future<Token?>        peek();
bool                  get isRefreshing;         // sync — true while refreshing
Stream<TokenEvent>    get events;
Stream<Token?>        get tokenStream;          // reactive token changes
Stream<Token?>        currentTokenStream();     // seed + subscribe in one call
Stream<T>             onEvent<T extends TokenEvent>(); // typed event filter
Future<void>          dispose();
```

#### `withValidToken` semantics

1. Fetch a valid token (refresh if expired or within proactive window).
2. Run the operation.
3. If the operation returns `Failure(unauthorized)`, force-refresh once and
   retry exactly once. Any further failure is returned as-is. **No infinite
   loops.**

#### `currentTokenStream()`

Replaces the common seed-then-subscribe pattern:

```dart
// before
final initial = await keeper.peek();
myState.token = initial;
keeper.tokenStream.listen((t) => myState.token = t);

// after
keeper.currentTokenStream().listen((t) => myState.token = t);
```

The first emission is `null` when storage is empty, so it is always safe to
listen to regardless of auth state.

#### `onEvent<T>()`

Subscribe to a specific event type without filtering manually:

```dart
keeper.onEvent<TokenRefreshedEvent>().listen((e) {
  analytics.track('token_refreshed', {'masked': e.token.maskedAccessToken});
});

keeper.onEvent<TokenClearedEvent>().listen((_) => router.go('/login'));

keeper.onEvent<RefreshFailedEvent>().listen((e) {
  logger.error('refresh failed: ${e.failure.message}');
});
```

### Storage

```dart
abstract interface class TokenStorage {
  Future<Token?> read();
  Future<void>   write(Token token);
  Future<void>   delete();
}
```

Built-in: `InMemoryTokenStorage({Token? initial})` — also exposes
`snapshot` (sync getter) and `clone()` for tests.

#### `CachingTokenStorage`

Wrap any backend with an in-memory cache so the request hot path skips disk
I/O:

```dart
final storage = CachingTokenStorage(SecureStorageAdapter());

await storage.warmup();        // optional: prime the cache at app startup
storage.isCached;              // sync bool — has the cache loaded yet?
storage.cachedToken;           // sync read of the last-loaded token
storage.invalidate();          // drop the cache, e.g. before a cross-isolate read
await storage.refresh();       // invalidate + reload in one call; returns Token?
```

#### Implementing a secure storage adapter

Pure-Dart core means no `flutter_secure_storage` dependency. Add it in your
app and wire it up like this:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

class SecureStorageAdapter implements TokenStorage {
  SecureStorageAdapter({this.key = 'token_keeper.token'});
  final FlutterSecureStorage _s = const FlutterSecureStorage();
  final String key;

  @override
  Future<Token?> read() async {
    final raw = await _s.read(key: key);
    if (raw == null) return null;
    return Token.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> write(Token token) =>
      _s.write(key: key, value: jsonEncode(token.toJson()));

  @override
  Future<void> delete() => _s.delete(key: key);
}
```

### Events

```dart
sealed class TokenEvent { }
final class TokenRefreshedEvent extends TokenEvent { final Token token; }
final class TokenClearedEvent   extends TokenEvent { }
final class RefreshFailedEvent  extends TokenEvent { final Failure failure; }
```

All three implement `Equatable` and have redacted `toString()` overrides so
they're directly usable in tests, log lines, and reactive state layers.

Use `onEvent<T>()` for typed subscriptions, or `events` with a `switch` for
exhaustive handling:

```dart
keeper.events.listen((event) {
  switch (event) {
    case TokenClearedEvent():   router.go('/login');
    case TokenRefreshedEvent(): /* analytics ping */;
    case RefreshFailedEvent(:final failure): logger.warn(failure.message);
  }
});
```

For reactive UI, prefer `currentTokenStream()`:

```dart
keeper.currentTokenStream().listen((token) {
  // null after clear() or unauthorized refresh failure;
  // current token on subscribe, then new Token after refresh / setTokens.
});
```

### `TokenRefreshTimer`

Periodically calls `getValidToken()` to keep the stored token warm. Primarily
useful for **background services** or daemon processes where HTTP requests may
not fire frequently enough to trigger the on-demand refresh in
`getValidToken`. For on-demand Flutter UI, the `proactiveWindow` on
`TokenKeeper` is usually sufficient and you don't need this class.

```dart
final timer = TokenRefreshTimer(
  keeper: keeper,
  checkInterval: const Duration(minutes: 5),
);
timer.start();

// Trigger an immediate check outside the schedule, e.g. when the app
// returns from background.
await timer.runNow();

// When done (e.g. user logs out).
timer.dispose();
```

Configure the keeper with a `proactiveWindow` larger than `checkInterval` so
the periodic tick has a chance to refresh before actual expiry:

```dart
TokenKeeper(proactiveWindow: const Duration(minutes: 10), ...);
TokenRefreshTimer(keeper: keeper, checkInterval: const Duration(minutes: 5));
```

| Member | Description |
| --- | --- |
| `start()` | Begin periodic checks. No-op if already running or disposed. |
| `stop()` | Pause. Call `start()` to resume. |
| `runNow()` | Immediate check outside the schedule. No-op if disposed. |
| `dispose()` | Stop permanently. Cannot be restarted. |
| `isRunning` | `bool` — whether the timer is currently ticking. |

### Dio interceptor

```dart
final api = Dio();
api.interceptors.add(TokenKeeperInterceptor(
  keeper: keeper,
  dio: api,
  headerName: 'Authorization',                            // optional
  scheme: 'Bearer',                                       // optional
  shouldRefreshOn: (r) => r?.statusCode == 401,           // optional
  onRefreshFailed: (_) => router.go('/login'),            // optional
));
```

To bypass the interceptor for a single request (e.g. the login or refresh
endpoint itself), set `Options(extra: {'token_keeper_skip_auth': true})` or
call `requestOptions.skipTokenKeeper()`.

### Retry config

The default config makes a single attempt. Use the exponential factory for
backoff on transient failures (5xx / 408 / 429 by default — 401 is never
retried because the auth grant is dead):

```dart
TokenKeeper(
  retryConfig: RefreshRetryConfig.exponential(
    maxAttempts: 4,
    delay: const Duration(milliseconds: 250),
    maxDelay: const Duration(seconds: 5),
  ),
);
```

Or roll your own predicate:

```dart
RefreshRetryConfig(
  maxAttempts: 5,
  delay: const Duration(milliseconds: 100),
  retryIf: (failure) => failure.code != 401,
);
```

`RefreshRetryConfig` is a thin wrapper around `resilify`'s `RetryHelper`, so
it shares the same exponential / jitter / `attemptTimeout` machinery as the
rest of the resilify ecosystem.

### Logging

```dart
TokenKeeper(
  logger: (level, message, {error, stackTrace}) {
    print('[token_keeper:${level.name}] $message');
  },
);
```

## Concurrency model

`token_keeper` relies on Dart's single-threaded execution within an isolate.
The single-flight gate is implemented as a synchronous read/write of a
private `Completer?` field — any caller that reaches `_runRefresh` while a
flight is active observes a non-null completer and joins it. The internal
flight handler clears the field **before** completing the completer, so
awaiter continuations always observe a clean state when a follow-up refresh
is required.

This was tested with 100 concurrent callers waking up against an expired
token; exactly one refresh was issued.

## Testing

The package ships with `FixedClock` and `InMemoryTokenStorage` to keep tests
deterministic and fast:

```dart
final clock = FixedClock(DateTime.utc(2025));
final storage = InMemoryTokenStorage();

final keeper = TokenKeeper(
  storage: storage,
  refresher: (_) async => Success(Token(accessToken: 'fresh',
      expiresAt: clock.now().add(const Duration(hours: 1)))),
  clock: clock,
);
```

Then advance the clock to trigger expiry behavior.

## Folder layout

```text
lib/
  token_keeper.dart           # barrel
  dio.dart                    # optional Dio integration barrel
  core/
    clock.dart
    events.dart
    logger.dart
    result.dart               # re-exports resilify Result/Failure
    retry_policy.dart         # RefreshRetryConfig
    token.dart
  storage/
    token_storage.dart
    in_memory_storage.dart
    caching_storage.dart      # in-memory cache decorator
  keeper/
    token_keeper.dart
    token_refresh_timer.dart  # periodic background refresh
  dio/
    token_keeper_interceptor.dart

test/
  token_test.dart
  token_extras_test.dart
  token_jwt_test.dart
  in_memory_storage_test.dart
  caching_storage_test.dart
  token_keeper_test.dart
  token_stream_test.dart
  token_keeper_interceptor_test.dart

example/
  main.dart
```

## ❤️ Support

If you find this package helpful, consider [sponsoring on GitHub][sponsor].

[sponsor]: https://github.com/sponsors/himanshulahoti20

## License

MIT — see [LICENSE](LICENSE).
