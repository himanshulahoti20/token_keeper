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
    test('returns Failure.unauthorized when storage is empty', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Failure(message: 'nope', type: FailureType.unknown),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result, isA<Failure<Token>>());
      expect((result as Failure<Token>).type, FailureType.unauthorized);
    });

    test('returns the cached token when not expired', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(minutes: 10)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Failure(
            message: 'should not call', type: FailureType.unknown),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result, isA<Success<Token>>());
      expect((result as Success<Token>).value.accessToken, 'a-1');
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
          return Success(
            current.copyWith(
              accessToken: 'a-2',
              expiresAt: now.add(const Duration(hours: 1)),
            ),
          );
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.getValidToken();
      expect(result, isA<Success<Token>>());
      expect((result as Success<Token>).value.accessToken, 'a-2');
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
      expect((result as Success<Token>).value.accessToken, 'a-fresh');
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

      // Launch 100 concurrent getValidToken calls.
      final futures = List.generate(100, (_) => keeper.getValidToken());

      // Give Dart a chance to schedule all of them.
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
        expect((r as Success<Token>).value.accessToken, 'fresh');
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
      expect((r1 as Success<Token>).value.accessToken, 'fresh-1');
      expect((r2 as Success<Token>).value.accessToken, 'fresh-2');
    });
  });

  group('withValidToken', () {
    test('returns operation result on success', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(hours: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Failure(message: 'no', type: FailureType.unknown),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final result = await keeper.withValidToken<String>(
        (t) async => Success<String>('hi-${t.accessToken}'),
      );
      expect((result as Success<String>).value, 'hi-a-1');
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
          return const Failure<String>(
            message: '401',
            type: FailureType.unauthorized,
          );
        }
        return Success<String>('ok-${t.accessToken}');
      });
      expect(calls, 2);
      expect((result as Success<String>).value, 'ok-a-2');
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
        return const Failure<String>(
          message: '401 again',
          type: FailureType.unauthorized,
        );
      });
      expect(calls, 2, reason: 'one initial + one retry');
      expect(result, isA<Failure<String>>());
      expect((result as Failure<String>).type, FailureType.unauthorized);
    });

    test('non-unauthorized failure is returned without retry', () async {
      await storage.write(_expiringToken(
        expiresAt: now.add(const Duration(hours: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Failure(message: 'no', type: FailureType.unknown),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      var calls = 0;
      final result = await keeper.withValidToken<String>((_) async {
        calls++;
        return const Failure<String>(
          message: 'server',
          type: FailureType.unknown,
        );
      });
      expect(calls, 1);
      expect(result, isA<Failure<String>>());
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
        'refresh failing with unauthorized clears storage and emits both '
        'RefreshFailedEvent and TokenClearedEvent', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Failure(
          message: 'refresh token revoked',
          type: FailureType.unauthorized,
        ),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final events = <TokenEvent>[];
      final sub = keeper.events.listen(events.add);
      addTearDown(sub.cancel);

      final result = await keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);

      expect(result, isA<Failure<Token>>());
      expect(await storage.read(), isNull);
      expect(events.whereType<RefreshFailedEvent>(), hasLength(1));
      expect(events.whereType<TokenClearedEvent>(), hasLength(1));
    });

    test('non-auth refresh failure does NOT clear storage', () async {
      final t = _expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      );
      await storage.write(t);
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Failure(message: 'timeout', type: FailureType.network),
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
        refresher: (_) async =>
            const Failure(message: 'no', type: FailureType.unknown),
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

  group('retry policy', () {
    test('exponential policy retries on network failures only', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      var attempts = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async {
          attempts++;
          if (attempts < 3) {
            return const Failure(
              message: 'down',
              type: FailureType.network,
            );
          }
          return Success(current.copyWith(
            accessToken: 'a-final',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
        retryPolicy: RefreshRetryPolicy.exponential(
          maxAttempts: 3,
          base: const Duration(milliseconds: 1),
        ),
      );
      addTearDown(keeper.dispose);

      final result = await keeper.forceRefresh();
      expect(attempts, 3);
      expect((result as Success<Token>).value.accessToken, 'a-final');
    });

    test('default policy does NOT retry', () async {
      await storage.write(_expiringToken(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      var attempts = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          attempts++;
          return const Failure(message: 'oops', type: FailureType.network);
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      await keeper.forceRefresh();
      expect(attempts, 1);
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
        refresher: (_) async => const Failure(
            message: 'should not be called', type: FailureType.unknown),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      expect(await keeper.peek(), expired);
    });

    test('setTokens writes and emits TokenRefreshedEvent', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Failure(message: 'no', type: FailureType.unknown),
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
    test('refresher that throws is converted to a Failure', () async {
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
      expect(result, isA<Failure<Token>>());
      expect((result as Failure<Token>).type, FailureType.unknown);
    });
  });
}
