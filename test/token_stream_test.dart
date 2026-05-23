import 'dart:async';

import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

void main() {
  late FixedClock clock;
  late InMemoryTokenStorage storage;
  late DateTime now;

  setUp(() {
    now = DateTime.utc(2025, 1, 1, 12);
    clock = FixedClock(now);
    storage = InMemoryTokenStorage();
  });

  group('TokenKeeper.tokenStream', () {
    test('emits new token after setTokens', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final received = <Token?>[];
      final sub = keeper.tokenStream.listen(received.add);
      addTearDown(sub.cancel);

      const t = Token(accessToken: 'abc');
      await keeper.setTokens(t);
      await Future<void>.delayed(Duration.zero);

      expect(received, [t]);
    });

    test('emits null after clear()', () async {
      await storage.write(const Token(accessToken: 'a'));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final received = <Token?>[];
      final sub = keeper.tokenStream.listen(received.add);
      addTearDown(sub.cancel);

      await keeper.clear();
      await Future<void>.delayed(Duration.zero);

      expect(received, [null]);
    });

    test('emits new token after successful refresh', () async {
      await storage.write(Token(
        accessToken: 'old',
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async => Success(
          current.copyWith(
            accessToken: 'fresh',
            expiresAt: now.add(const Duration(hours: 1)),
          ),
        ),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final received = <Token?>[];
      final sub = keeper.tokenStream.listen(received.add);
      addTearDown(sub.cancel);

      await keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 1);
      expect(received.single!.accessToken, 'fresh');
    });

    test('emits null after 401 refresh failure', () async {
      await storage.write(Token(
        accessToken: 'old',
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Error(Failure.unauthorized(message: 'revoked')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final received = <Token?>[];
      final sub = keeper.tokenStream.listen(received.add);
      addTearDown(sub.cancel);

      await keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);

      expect(received, [null]);
    });

    test('broadcasts to multiple concurrent subscribers', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final a = <Token?>[];
      final b = <Token?>[];
      final s1 = keeper.tokenStream.listen(a.add);
      final s2 = keeper.tokenStream.listen(b.add);
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);

      await keeper.setTokens(const Token(accessToken: 'x'));
      await Future<void>.delayed(Duration.zero);

      expect(a, hasLength(1));
      expect(b, hasLength(1));
      expect(a.single, b.single);
    });
  });

  group('TokenKeeper.currentTokenStream', () {
    test('emits null first when storage is empty', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final first = await keeper.currentTokenStream().first;
      expect(first, isNull);
    });

    test('emits stored token first when one exists', () async {
      const t = Token(accessToken: 'initial');
      await storage.write(t);
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final first = await keeper.currentTokenStream().first;
      expect(first, t);
    });

    test('continues emitting after the seed value on token changes', () async {
      const initial = Token(accessToken: 'v1');
      await storage.write(initial);
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final received = <Token?>[];
      final sub = keeper.currentTokenStream().listen(received.add);
      addTearDown(sub.cancel);

      await Future<void>.delayed(Duration.zero);
      await keeper.setTokens(const Token(accessToken: 'v2'));
      await Future<void>.delayed(Duration.zero);

      expect(received.first, initial);
      expect(received.last!.accessToken, 'v2');
      expect(received.length, 2);
    });
  });

  group('TokenKeeper.onEvent', () {
    test('emits only events matching the type parameter', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final refreshedEvents = <TokenRefreshedEvent>[];
      final sub =
          keeper.onEvent<TokenRefreshedEvent>().listen(refreshedEvents.add);
      addTearDown(sub.cancel);

      await keeper.setTokens(const Token(accessToken: 'a'));
      await keeper.clear();
      await Future<void>.delayed(Duration.zero);

      expect(refreshedEvents, hasLength(1));
      expect(refreshedEvents.single.token.accessToken, 'a');
    });

    test('does not emit when no events of that type occur', () async {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final clearedEvents = <TokenClearedEvent>[];
      final sub =
          keeper.onEvent<TokenClearedEvent>().listen(clearedEvents.add);
      addTearDown(sub.cancel);

      await keeper.setTokens(const Token(accessToken: 'a'));
      await Future<void>.delayed(Duration.zero);

      expect(clearedEvents, isEmpty);
    });

    test('RefreshFailedEvent filtered correctly', () async {
      await storage.write(Token(
        accessToken: 'old',
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Error(Failure.network(message: 'timeout')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final failures = <RefreshFailedEvent>[];
      final sub = keeper.onEvent<RefreshFailedEvent>().listen(failures.add);
      addTearDown(sub.cancel);

      await keeper.getValidToken();
      await Future<void>.delayed(Duration.zero);

      expect(failures, hasLength(1));
      expect(failures.single.failure.message, 'timeout');
    });
  });

  group('TokenRefreshTimer', () {
    test('does not refresh when token is valid', () async {
      await storage.write(Token(
        accessToken: 'live',
        expiresAt: now.add(const Duration(hours: 1)),
      ));

      var refreshCalls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          refreshCalls++;
          return const Error(Failure.unknown(message: 'no'));
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final timer = TokenRefreshTimer(
        keeper: keeper,
        checkInterval: const Duration(milliseconds: 10),
        clock: clock,
      );
      timer.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      timer.dispose();

      expect(refreshCalls, 0);
    });

    test('triggers refresh when token is within proactive window', () async {
      await storage.write(Token(
        accessToken: 'old',
        expiresAt: now.add(const Duration(seconds: 10)),
      ));

      var refreshCalls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async {
          refreshCalls++;
          return Success(current.copyWith(
            accessToken: 'new',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
        proactiveWindow: const Duration(minutes: 1),
      );
      addTearDown(keeper.dispose);

      final timer = TokenRefreshTimer(
        keeper: keeper,
        checkInterval: const Duration(milliseconds: 10),
        clock: clock,
      );
      timer.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      timer.dispose();

      expect(refreshCalls, greaterThanOrEqualTo(1));
    });

    test('isRunning reflects start/stop state', () {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final timer = TokenRefreshTimer(
        keeper: keeper,
        checkInterval: const Duration(minutes: 1),
        clock: clock,
      );

      expect(timer.isRunning, isFalse);
      timer.start();
      expect(timer.isRunning, isTrue);
      timer.stop();
      expect(timer.isRunning, isFalse);
      timer.dispose();
    });

    test('dispose prevents restart', () {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => const Error(Failure.unknown(message: 'no')),
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final timer = TokenRefreshTimer(
        keeper: keeper,
        checkInterval: const Duration(minutes: 1),
        clock: clock,
      );
      timer.dispose();
      timer.start();
      expect(timer.isRunning, isFalse);
    });

    test('runNow triggers an immediate check outside the schedule', () async {
      await storage.write(Token(
        accessToken: 'old',
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ));

      var refreshCalls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (current) async {
          refreshCalls++;
          return Success(current.copyWith(
            accessToken: 'fresh',
            expiresAt: now.add(const Duration(hours: 1)),
          ));
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final timer = TokenRefreshTimer(
        keeper: keeper,
        checkInterval: const Duration(hours: 1),
        clock: clock,
      );
      addTearDown(timer.dispose);

      await timer.runNow();
      expect(refreshCalls, 1);
    });

    test('runNow is a no-op after dispose', () async {
      await storage.write(const Token(accessToken: 'a'));
      var refreshCalls = 0;
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async {
          refreshCalls++;
          return const Error(Failure.unknown(message: 'no'));
        },
        clock: clock,
      );
      addTearDown(keeper.dispose);

      final timer = TokenRefreshTimer(
        keeper: keeper,
        checkInterval: const Duration(hours: 1),
        clock: clock,
      );
      timer.dispose();
      await timer.runNow();
      expect(refreshCalls, 0);
    });
  });
}
