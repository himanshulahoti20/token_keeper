# token_keeper

> Auth tokens, handled.

A pure-Dart token manager that gives you **single-flight refresh**,
**proactive expiry**, **clean `Result<T>` APIs**, **lifecycle events**, and a
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

`token_keeper` is the small, well-tested core that gets it right.

## Features

- **Single-flight refresh** — exactly one in-flight refresh per keeper, even
  under 50+ concurrent callers. Uses a `Completer` and a synchronous gate.
- **Proactive refresh** — refresh `N` seconds before expiry, not after.
- **`Result<T>` everywhere** — `Success` or typed `Failure(unauthorized | network | unknown)`. Public methods never throw.
- **`withValidToken`** — wrap any operation; auto-refresh + one bounded
  retry on `unauthorized`. No infinite loops.
- **Lifecycle events** — `TokenRefreshedEvent`, `TokenClearedEvent`,
  `RefreshFailedEvent` on a broadcast `Stream`.
- **Dio interceptor** — attaches `Authorization`, retries once on `401`.
- **Pluggable storage** — implement `TokenStorage` for Keychain, secure
  storage, SQLite, an isolate, anything.
- **Pluggable retry policy** — built-in `RefreshRetryPolicy.exponential`.
- **Pluggable clock** — `FixedClock` for deterministic tests.
- **Pluggable logger** — observability hook with no logging dependency.

## Install

```yaml
dependencies:
  token_keeper: ^1.0.0
```

If you want the Dio integration, also depend on `dio: ^5`.

## Quick start

```dart
import 'package:token_keeper/token_keeper.dart';
import 'package:token_keeper/dio.dart';
import 'package:dio/dio.dart';

final keeper = TokenKeeper(
  storage: InMemoryTokenStorage(),       // or your secure adapter
  refresher: (current) async {
    // Hit your /auth/refresh and return Success(newToken) or Failure(...).
    final res = await refreshDio.post('/auth/refresh',
        data: {'refresh': current.refreshToken});
    if (res.statusCode == 401) {
      return const Failure(message: 'revoked', type: FailureType.unauthorized);
    }
    return Success(Token(
      accessToken: res.data['access_token'] as String,
      refreshToken: res.data['refresh_token'] as String?,
      expiresAt: DateTime.now().add(Duration(seconds: res.data['expires_in'])),
    ));
  },
  proactiveWindow: const Duration(seconds: 30),
);

// Wire Dio.
final api = Dio();
api.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: api));

// Listen for logout.
keeper.events.listen((event) {
  if (event is TokenClearedEvent) navigator.toLogin();
});

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

```dart
token.isExpired();                            // ignores null expiry
token.willExpireWithin(const Duration(seconds: 30));
token.copyWith(accessToken: 'x', clearRefreshToken: true);
Token.fromJson(token.toJson());
```

### `Result<T>`

```dart
sealed class Result<T> { ... }
final class Success<T> extends Result<T> { final T value; }
final class Failure<T> extends Result<T> {
  final String message;
  final FailureType type; // unauthorized | network | unknown
  final Object? cause;
}
```

Helpers: `result.fold(onSuccess:, onFailure:)`, `result.map(...)`,
`failure.cast<R>()`, `result.valueOrNull`.

### `TokenKeeper`

```dart
TokenKeeper({
  required TokenStorage storage,
  required TokenRefresher refresher,
  Duration proactiveWindow = Duration.zero,
  Clock clock = const Clock(),
  RefreshRetryPolicy retryPolicy = const RefreshRetryPolicy(),
  TokenKeeperLogger logger = noopLogger,
});

Future<Result<Token>> getValidToken();
Future<Result<R>>     withValidToken<R>(Future<Result<R>> Function(Token) op);
Future<Result<Token>> forceRefresh();
Future<void>          setTokens(Token token);
Future<void>          clear();
Future<Token?>        peek();
Stream<TokenEvent>    get events;
Future<void>          dispose();
```

#### `withValidToken` semantics

1. Fetch a valid token (refresh if expired or within proactive window).
2. Run the operation.
3. If the operation returns `Failure(unauthorized)`, force-refresh once and
   retry exactly once. Any further failure is returned as-is. **No infinite
   loops.**

### Storage

```dart
abstract interface class TokenStorage {
  Future<Token?> read();
  Future<void>   write(Token token);
  Future<void>   delete();
}
```

Built-in: `InMemoryTokenStorage({Token? initial})`.

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
final class TokenClearedEvent  extends TokenEvent { }
final class RefreshFailedEvent extends TokenEvent { final Failure<Token> failure; }
```

A typical logout listener:

```dart
keeper.events.listen((event) {
  switch (event) {
    case TokenClearedEvent(): router.go('/login');
    case TokenRefreshedEvent(): /* analytics ping */;
    case RefreshFailedEvent(:final failure): logger.warn(failure.message);
  }
});
```

### Dio interceptor

```dart
final api = Dio();
api.interceptors.add(TokenKeeperInterceptor(
  keeper: keeper,
  dio: api,
  headerName: 'Authorization', // optional
  scheme: 'Bearer',            // optional
  shouldRefreshOn: (response) => response?.statusCode == 401, // optional
));
```

To bypass the interceptor for a single request (e.g. login or refresh), set
`Options(extra: {'token_keeper_skip_auth': true})` or call
`requestOptions.skipTokenKeeper()`.

### Retry policy

The default policy makes a single attempt. Use the exponential factory for
backoff on network failures:

```dart
TokenKeeper(
  // ...
  retryPolicy: RefreshRetryPolicy.exponential(
    maxAttempts: 4,
    base: const Duration(milliseconds: 250),
    max: const Duration(seconds: 5),
  ),
);
```

Or roll your own predicate:

```dart
RefreshRetryPolicy(
  maxAttempts: 5,
  delayFor: (attempt) => Duration(milliseconds: 100 * attempt),
  shouldRetry: (failure) => failure.type != FailureType.unauthorized,
);
```

### Logging

```dart
TokenKeeper(
  // ...
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
    result.dart
    retry_policy.dart
    token.dart
  storage/
    token_storage.dart
    in_memory_storage.dart
  keeper/
    token_keeper.dart
  dio/
    token_keeper_interceptor.dart

test/
  token_test.dart
  result_test.dart
  in_memory_storage_test.dart
  token_keeper_test.dart
  token_keeper_interceptor_test.dart

example/
  main.dart
```

## License

MIT — see [LICENSE](LICENSE).
