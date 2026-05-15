import 'dart:async';

import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

Token _expiringToken({
  String access = 'a-1',
  String refresh = 'r-1',
  DateTime? expiresAt,
}) =>
    Token(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt,
    );

void main() {
  late FixedClock clock;
  late InMemoryTokenStorage storage;
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2025, 1, 1, 12);
    clock = FixedClock(now);
    storage = InMemoryTokenStorage();
  });

  group('getValidToken', () {
    test('returns Error(Failure.unauthorized) when storage is empty', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Error(Failure.unknown(message: 'should not call')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result, isA<Error<Token>>());
      expect((result as Error<Token>).failure.code, 401);
    });

    test('returns the cached token when not expired', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(minutes: 10)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Error(Failure.unknown(message: 'should not call')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result, isA<Success<Token>>());
      expect((result as Success<Token>).data.accessToken, 'a-1');
    });

    test('refreshes when token is expired', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      var calls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async {
          calls++;
          return Success(current.copyWith(
            accessToken: 'a-2',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result.dataOrNull?.accessToken, 'a-2');
      expect(calls, 1);
    });

    test('refreshes proactively when within proactiveWindow', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(seconds: 30)),
      ));

      var calls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          calls++;
          return Success(_expiringToken(
            access: 'a-fresh',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
        proactiveWindow: const Duration(minutes: 1),
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result.dataOrNull?.accessToken, 'a-fresh');
      expect(calls, 1);
    });
  });

  group('single-flight refresh', () {
    test('100 concurrent calls trigger exactly ONE refresh', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      final completer = Completer<Result<Token>>();
      var calls = 0;

      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          calls++;
          return completer.future;
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final futures = List.generate(100, (_) => keeper.getValidToken());
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1, reason: 'only one refresher invocation expected');

      completer.complete(Success(_expiringToken(
        access: 'fresh',
        expiresAt: now.add(const Duration(hours: 1)),
      )));

      final results = await Future.wait(futures);
      expect(results.length, 100);
      for (final r in results) {
        expect(r, isA<Success<Token>>());
        expect((r as Success<Token>).data.accessToken, 'fresh');
      }
      expect(calls, 1);
    });

    test('refresh-after-refresh works correctly', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      var calls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          calls++;
          return Success(_expiringToken(
            access: 'fresh-$calls',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final r1 = await keeper.forceRefresh();
      final r2 = await keeper.forceRefresh();
      expect(calls, 2);
      expect(r1.dataOrNull?.accessToken, 'fresh-1');
      expect(r2.dataOrNull?.accessToken, 'fresh-2');
    });
  });

  group('withValidToken', () {
    test('returns operation result on success', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(hours: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.withValidToken<String>(
        (t) async => Success<String>('hi-${t.accessToken}'),
      );
      expect(result.dataOrNull, 'hi-a-1');
    });

    test('refreshes and retries once on 401, then returns success', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(hours: 1)),
      ));

      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async => Success(current.copyWith(
          accessToken: 'a-2',
          expiresAt: now.add(const Duration(hours: 1)),
        )),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      var calls = 0;
      final result = await keeper.withValidToken<String>((t) async {
        calls++;
        if (calls == 1) {
          return const Error<String>(Failure.unauthorized(message: '401'));
        }
        return Success<String>('ok-${t.accessToken}');
      });
      expect(calls, 2);
      expect(result.dataOrNull, 'ok-a-2');
    });

    test('retries at most ONCE — no infinite loop', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(hours: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async => Success(current.copyWith(
          accessToken: 'a-2',
          expiresAt: now.add(const Duration(hours: 1)),
        )),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      var calls = 0;
      final result = await keeper.withValidToken<String>((_) async {
        calls++;
        return const Error<String>(
          Failure.unauthorized(message: '401 again'),
        );
      });
      expect(calls, 2, reason: 'one initial + one retry');
      expect(result, isA<Error<String>>());
      expect((result as Error<String>).failure.code, 401);
    });

    test('non-401 failure is returned without retry', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(hours: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      var calls = 0;
      final result = await keeper.withValidToken<String>((_) async {
        calls++;
        return const Error<String>(
          Failure.serverError(message: '500'),
        );
      });
      expect(calls, 1);
      expect(result, isA<Error<String>>());
    });
  });

  group('events', () {
    test('emits TokenRefreshedEvent on successful refresh', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async => Success(current.copyWith(
          accessToken: 'a-2',
          expiresAt: now.add(const Duration(hours: 1)),
        )),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final events = <TokenEvent>[];
      final sub = keeper.events.listen(events.add);
      addTearDown(sub.cancel);

      await keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single, isA<TokenRefreshedEvent>());
    });

    test(
        'refresh failing with 401 clears storage and emits both '
        'RefreshFailedEvent and TokenClearedEvent', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(
          Failure.unauthorized(message: 'refresh token revoked'),
        ),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final events = <TokenEvent>[];
      final sub = keeper.events.listen(events.add);
      addTearDown(sub.cancel);

      final result = await keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);

      expect(result, isA<Error<Token>>());
      expect(await storage.read(), isNull);
      expect(events.whereType<RefreshFailedEvent>(), hasLength(1));
      expect(events.whereType<TokenClearedEvent>(), hasLength(1));
    });

    test('non-401 refresh failure does NOT clear storage', () async {
      final t = _expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      );
      await storage.write(t);
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Error(Failure.network(message: 'timeout')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final events = <TokenEvent>[];
      final sub = keeper.events.listen(events.add);
      addTearDown(sub.cancel);

      await keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);

      expect(await storage.read(), t);
      expect(events.whereType<RefreshFailedEvent>(), hasLength(1));
      expect(events.whereType<TokenClearedEvent>(), isEmpty);
    });

    test('clear() emits TokenClearedEvent', () async {
      await storage.write(_expiringToken());
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final events = <TokenEvent>[];
      final sub = keeper.events.listen(events.add);
      addTearDown(sub.cancel);

      await keeper.clear();
      await Future<void>.delayed(Duration.zero);

      expect(events, [isA<TokenClearedEvent>()]);
      expect(await storage.read(), isNull);
    });
  });

  group('retry config (resilify-backed)', () {
    test('exponential config retries on transient (5xx) failures', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      var attempts = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async {
          attempts++;
          if (attempts < 3) {
            return const Error(Failure.serverError(message: 'down'));
          }
          return Success(current.copyWith(
            accessToken: 'a-final',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
        retryConfig: RefreshRetryConfig.exponential(
          maxAttempts: 3,
          delay: const Duration(milliseconds: 1),
          jitter: 0,
        ),
      );
      addTearDown(keeper.dispose);

      final result = await keeper.forceRefresh();
      expect(attempts, 3);
      expect(result.dataOrNull?.accessToken, 'a-final');
    });

    test('default config does NOT retry', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      var attempts = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          attempts++;
          return const Error(Failure.serverError(message: 'oops'));
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      await keeper.forceRefresh();
      expect(attempts, 1);
    });

    test('does NOT retry on 401 (auth dead) even with maxAttempts > 1',
        () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      var attempts = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          attempts++;
          return const Error(Failure.unauthorized(message: 'revoked'));
        },
        clock: clock,
        retryConfig: const RefreshRetryConfig(
          maxAttempts: 5,
          delay: Duration(milliseconds: 1),
        ),
      );
      addTearDown(keeper.dispose);

      await keeper.forceRefresh();
      expect(attempts, 1, reason: '401 is not retryable');
    });
  });

  group('peek/setTokens/clear', () {
    test('peek returns the raw stored token without refreshing', () async {
      final expired = _expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      );
      await storage.write(expired);
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Error(Failure.unknown(message: 'should not be called')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      expect(await keeper.peek(), expired);
    });

    test('setTokens writes and emits TokenRefreshedEvent', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final events = <TokenEvent>[];
      final sub = keeper.events.listen(events.add);
      addTearDown(sub.cancel);

      const newToken = Token(accessToken: 'set-1');
      await keeper.setTokens(newToken);
      await Future<void>.delayed(Duration.zero);

      expect(await storage.read(), newToken);
      expect(events.whereType<TokenRefreshedEvent>(), hasLength(1));
    });
  });

  group('refresher safety', () {
    test('refresher that throws is converted to Error(Failure.unknown)',
        () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => throw StateError('boom'),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result, isA<Error<Token>>());
      expect((result as Error<Token>).failure.code, isNull);
      expect(result.failure.message, contains('boom'));
    });
  });

  group('isRefreshing', () {
    test('false when no refresh in flight', () {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);
      expect(keeper.isRefreshing, isFalse);
    });

    test('true while refreshing, false after', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      final gate = Completer<Result<Token>>();
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) => gate.future,
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final fut = keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);
      expect(keeper.isRefreshing, isTrue);

      gate.complete(Success(_expiringToken(
        access: 'fresh',
        expiresAt: now.add(const Duration(hours: 1)),
      )));
      await fut;
      expect(keeper.isRefreshing, isFalse);
    });
  });

  group('refreshIfNeeded (1.1.2)', () {
    test('returns the current token when still valid', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(minutes: 10)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Error(Failure.unknown(message: 'should not call')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.refreshIfNeeded();
      expect(result, isA<Success<Token>>());
      expect((result as Success<Token>).data.accessToken, 'a-1');
    });

    test('triggers a refresh when the token is expired', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      var refreshCalls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          refreshCalls++;
          return Success(_expiringToken(
            access: 'fresh',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.refreshIfNeeded();
      expect(refreshCalls, 1);
      expect((result as Success<Token>).data.accessToken, 'fresh');
    });
  });
}
