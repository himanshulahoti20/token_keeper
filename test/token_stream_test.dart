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
  });
}
