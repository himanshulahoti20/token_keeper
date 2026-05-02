import 'dart:async';

import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

void main() {
  final fixedNow = DateTime.utc(2025, 6, 1, 12);

  // ---- Token.isValid --------------------------------------------------------

  group('Token.isValid', () {
    test('is true when no expiresAt', () {
      expect(const Token(accessToken: 'a').isValid(fixedNow), isTrue);
    });

    test('is true when not yet expired', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(seconds: 1)),
      );
      expect(t.isValid(fixedNow), isTrue);
    });

    test('is false at the exact expiry instant', () {
      final t = Token(accessToken: 'a', expiresAt: fixedNow);
      expect(t.isValid(fixedNow), isFalse);
    });

    test('is false after expiry', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.subtract(const Duration(seconds: 1)),
      );
      expect(t.isValid(fixedNow), isFalse);
    });
  });

  // ---- Token.remainingLifetime ----------------------------------------------

  group('Token.remainingLifetime', () {
    test('returns null when expiresAt is null', () {
      expect(const Token(accessToken: 'a').remainingLifetime(fixedNow), isNull);
    });

    test('returns correct duration when not expired', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(minutes: 10)),
      );
      expect(
        t.remainingLifetime(fixedNow),
        const Duration(minutes: 10),
      );
    });

    test('returns Duration.zero when already expired (not negative)', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.subtract(const Duration(hours: 1)),
      );
      expect(t.remainingLifetime(fixedNow), Duration.zero);
    });

    test('returns Duration.zero at exact expiry instant', () {
      final t = Token(accessToken: 'a', expiresAt: fixedNow);
      expect(t.remainingLifetime(fixedNow), Duration.zero);
    });
  });

  // ---- Token.fromJsonOrNull -------------------------------------------------

  group('Token.fromJsonOrNull', () {
    test('round-trips valid JSON', () {
      final original = Token(
        accessToken: 'at',
        refreshToken: 'rt',
        expiresAt: fixedNow,
        scopes: const ['read'],
      );
      expect(Token.fromJsonOrNull(original.toJson()), original);
    });

    test('returns null for missing required accessToken', () {
      expect(Token.fromJsonOrNull({'refreshToken': 'rt'}), isNull);
    });

    test('returns null for wrong type on accessToken', () {
      expect(Token.fromJsonOrNull({'accessToken': 123}), isNull);
    });

    test('returns null for invalid expiresAt format', () {
      expect(
        Token.fromJsonOrNull({
          'accessToken': 'a',
          'expiresAt': 'not-a-date',
        }),
        isNull,
      );
    });
  });

  // ---- Result.getOrElse -----------------------------------------------------

  group('Result.getOrElse', () {
    test('returns value on Success', () {
      const r = Success<int>(42);
      expect(r.getOrElse(() => -1), 42);
    });

    test('calls fallback on Failure', () {
      const r = Failure<int>(message: 'oops', type: FailureType.unknown);
      expect(r.getOrElse(() => 99), 99);
    });

    test('fallback is not called on Success', () {
      var called = false;
      const Success<int>(1).getOrElse(() {
        called = true;
        return 0;
      });
      expect(called, isFalse);
    });
  });

  // ---- Failure.toString -----------------------------------------------------

  group('Failure.toString', () {
    test('includes type and message', () {
      const f = Failure<int>(
          message: 'token expired', type: FailureType.unauthorized);
      expect(f.toString(), contains('unauthorized'));
      expect(f.toString(), contains('token expired'));
    });

    test('includes cause when present', () {
      final f = Failure<int>(
        message: 'boom',
        type: FailureType.network,
        cause: Exception('socket hang up'),
      );
      expect(f.toString(), contains('socket hang up'));
    });

    test('omits cause label when cause is null', () {
      const f = Failure<int>(message: 'x', type: FailureType.unknown);
      expect(f.toString(), isNot(contains('cause')));
    });
  });

  // ---- TokenEvent equality --------------------------------------------------

  group('TokenEvent equality', () {
    const token = Token(accessToken: 'abc', scopes: ['read']);

    test('TokenClearedEvent equals another TokenClearedEvent', () {
      expect(const TokenClearedEvent(), const TokenClearedEvent());
    });

    test('TokenRefreshedEvent equals one with same token', () {
      expect(
        const TokenRefreshedEvent(token),
        const TokenRefreshedEvent(token),
      );
    });

    test('TokenRefreshedEvent differs when token differs', () {
      expect(
        const TokenRefreshedEvent(token),
        isNot(TokenRefreshedEvent(token.copyWith(accessToken: 'xyz'))),
      );
    });

    test('RefreshFailedEvent equals one with same failure', () {
      const f = Failure<Token>(message: 'x', type: FailureType.network);
      expect(const RefreshFailedEvent(f), const RefreshFailedEvent(f));
    });

    test('different event types are not equal', () {
      expect(
        const TokenClearedEvent(),
        isNot(const TokenRefreshedEvent(token)),
      );
    });
  });

  // ---- Token scope helpers --------------------------------------------------

  group('Token scope helpers', () {
    const token = Token(
      accessToken: 'a',
      scopes: ['read', 'write', 'admin'],
    );

    group('hasScope', () {
      test('returns true for a present scope', () {
        expect(token.hasScope('read'), isTrue);
      });

      test('returns false for an absent scope', () {
        expect(token.hasScope('delete'), isFalse);
      });

      test('comparison is case-sensitive', () {
        expect(token.hasScope('Read'), isFalse);
      });
    });

    group('hasAllScopes', () {
      test('returns true when all required scopes are present', () {
        expect(token.hasAllScopes(['read', 'write']), isTrue);
      });

      test('returns false when any required scope is absent', () {
        expect(token.hasAllScopes(['read', 'delete']), isFalse);
      });

      test('returns true for empty list', () {
        expect(token.hasAllScopes([]), isTrue);
      });
    });

    group('hasAnyScope', () {
      test('returns true when at least one scope matches', () {
        expect(token.hasAnyScope(['delete', 'write']), isTrue);
      });

      test('returns false when no scope matches', () {
        expect(token.hasAnyScope(['delete', 'purge']), isFalse);
      });

      test('returns false for empty list', () {
        expect(token.hasAnyScope([]), isFalse);
      });
    });
  });

  // ---- TokenKeeperInterceptor.onRefreshFailed --------------------------------

  group('TokenKeeperInterceptor.onRefreshFailed', () {
    // This group requires dio — import is already in the interceptor test file.
    // We test the callback contract at the keeper level here to stay
    // dependency-free in this file.

    test('onRefreshFailed receives the failure from forceRefresh', () async {
      final clock = FixedClock(DateTime.utc(2025));
      final storage = InMemoryTokenStorage(
        initial: Token(
          accessToken: 'old',
          expiresAt: clock.now().add(const Duration(hours: 1)),
        ),
      );

      const expectedFailure = Failure<Token>(
        message: 'revoked',
        type: FailureType.unauthorized,
      );

      // Simulate what the interceptor does: call forceRefresh and invoke
      // onRefreshFailed when it fails.
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async => expectedFailure,
        clock: clock,
      );
      addTearDown(keeper.dispose);

      Failure<Token>? captured;
      final result = await keeper.forceRefresh();
      if (result is Failure<Token>) {
        // This mirrors the interceptor's onRefreshFailed?.call(result)
        captured = result;
      }

      expect(captured, expectedFailure);
      expect(captured!.type, FailureType.unauthorized);
    });
  });

  // ---- TokenKeeper.isRefreshing --------------------------------------------

  group('TokenKeeper.isRefreshing', () {
    late FixedClock clock;
    late InMemoryTokenStorage storage;

    setUp(() {
      clock = FixedClock(DateTime.utc(2025));
      storage = InMemoryTokenStorage();
    });

    test('is false when no refresh is in flight', () {
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) async =>
            const Failure(message: 'no', type: FailureType.unknown),
        clock: clock,
      );
      addTearDown(keeper.dispose);
      expect(keeper.isRefreshing, isFalse);
    });

    test('is true while a refresh is in flight, false after', () async {
      await storage.write(Token(
        accessToken: 'old',
        expiresAt: clock.now().subtract(const Duration(seconds: 1)),
      ));

      final gate = Completer<Result<Token>>();
      final keeper = TokenKeeper(
        storage: storage,
        refresher: (_) => gate.future,
        clock: clock,
      );
      addTearDown(keeper.dispose);

      // Kick off refresh without awaiting.
      final refreshFuture = keeper.getValidToken();
      // Yield so the refresh flight starts.
      await Future<void>.delayed(Duration.zero);

      expect(keeper.isRefreshing, isTrue);

      gate.complete(Success(Token(
        accessToken: 'new',
        expiresAt: clock.now().add(const Duration(hours: 1)),
      )));
      await refreshFuture;

      expect(keeper.isRefreshing, isFalse);
    });
  });
}
