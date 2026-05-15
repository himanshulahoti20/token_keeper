import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

void main() {
  final fixedNow = DateTime.utc(2025, 6, 1, 12);

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

  group('Token.remainingLifetime', () {
    test('null when expiresAt is null', () {
      expect(const Token(accessToken: 'a').remainingLifetime(fixedNow), isNull);
    });

    test('correct duration when not expired', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(minutes: 10)),
      );
      expect(t.remainingLifetime(fixedNow), const Duration(minutes: 10));
    });

    test('Duration.zero when already expired (not negative)', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.subtract(const Duration(hours: 1)),
      );
      expect(t.remainingLifetime(fixedNow), Duration.zero);
    });
  });

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

    test('null for missing required accessToken', () {
      expect(Token.fromJsonOrNull({'refreshToken': 'rt'}), isNull);
    });

    test('null for invalid expiresAt format', () {
      expect(
        Token.fromJsonOrNull({
          'accessToken': 'a',
          'expiresAt': 'not-a-date',
        }),
        isNull,
      );
    });
  });

  group('Token scope helpers', () {
    const token = Token(
      accessToken: 'a',
      scopes: ['read', 'write', 'admin'],
    );

    test('hasScope', () {
      expect(token.hasScope('read'), isTrue);
      expect(token.hasScope('delete'), isFalse);
      expect(token.hasScope('Read'), isFalse,
          reason: 'case-sensitive per RFC 6749');
    });

    test('hasAllScopes', () {
      expect(token.hasAllScopes(['read', 'write']), isTrue);
      expect(token.hasAllScopes(['read', 'delete']), isFalse);
      expect(token.hasAllScopes([]), isTrue);
    });

    test('hasAnyScope', () {
      expect(token.hasAnyScope(['delete', 'write']), isTrue);
      expect(token.hasAnyScope(['delete', 'purge']), isFalse);
      expect(token.hasAnyScope([]), isFalse);
    });
  });

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

    test('RefreshFailedEvent equals one with same Failure', () {
      const f = Failure.unauthorized(message: 'x');
      expect(const RefreshFailedEvent(f), const RefreshFailedEvent(f));
    });
  });

  group('Token.requiresRefresh (1.1.1)', () {
    test('false when expiresAt is null', () {
      expect(const Token(accessToken: 'a').requiresRefresh(now: fixedNow),
          isFalse);
    });

    test('true within default 5-minute window', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(minutes: 2)),
      );
      expect(t.requiresRefresh(now: fixedNow), isTrue);
    });

    test('false when comfortably ahead of default window', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      expect(t.requiresRefresh(now: fixedNow), isFalse);
    });

    test('honours custom window', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(minutes: 30)),
      );
      expect(t.requiresRefresh(window: const Duration(hours: 1), now: fixedNow),
          isTrue);
    });
  });

  group('Token.isValidWithAllScopes / isValidWithAnyScope (1.1.1)', () {
    final freshToken = Token(
      accessToken: 'a',
      expiresAt: fixedNow.add(const Duration(hours: 1)),
      scopes: const ['read', 'write'],
    );
    final expiredToken = Token(
      accessToken: 'a',
      expiresAt: fixedNow.subtract(const Duration(seconds: 1)),
      scopes: const ['read', 'write'],
    );

    test('isValidWithAllScopes true when fresh and all scopes granted', () {
      expect(freshToken.isValidWithAllScopes(['read', 'write'], fixedNow),
          isTrue);
    });

    test('isValidWithAllScopes false when expired even if scopes granted', () {
      expect(expiredToken.isValidWithAllScopes(['read'], fixedNow), isFalse);
    });

    test('isValidWithAnyScope false when scope missing', () {
      expect(freshToken.isValidWithAnyScope(['admin'], fixedNow), isFalse);
    });

    test('isValidWithAnyScope true when at least one scope granted', () {
      expect(freshToken.isValidWithAnyScope(['admin', 'read'], fixedNow),
          isTrue);
    });
  });

  group('Token.maskedAccessToken (1.1.2)', () {
    test('fully redacts short tokens', () {
      expect(const Token(accessToken: 'short').maskedAccessToken, '***');
      expect(const Token(accessToken: '12345678').maskedAccessToken, '***');
    });

    test('shows first/last 4 chars of longer tokens', () {
      const t = Token(accessToken: 'eyJhbGciOiJSUzI1NiJ9');
      expect(t.maskedAccessToken, 'eyJh…NiJ9');
    });

    test('never contains the middle of the token', () {
      const t = Token(accessToken: 'abcdefghijklmnopqrstuvwxyz');
      expect(t.maskedAccessToken.contains('lmno'), isFalse);
    });
  });

  group('Token.expiresInSeconds (1.1.2)', () {
    test('null when expiresAt is null', () {
      expect(const Token(accessToken: 'a').expiresInSeconds(fixedNow), isNull);
    });

    test('whole seconds remaining when not expired', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(seconds: 3600)),
      );
      expect(t.expiresInSeconds(fixedNow), 3600);
    });

    test('0 (not negative) when already expired', () {
      final t = Token(
        accessToken: 'a',
        expiresAt: fixedNow.subtract(const Duration(hours: 1)),
      );
      expect(t.expiresInSeconds(fixedNow), 0);
    });
  });

  group('TokenEvent toString (1.1.2)', () {
    test('TokenRefreshedEvent redacts the access token', () {
      const t = Token(accessToken: 'eyJhbGciOiJSUzI1NiJ9');
      final s = const TokenRefreshedEvent(t).toString();
      expect(s, contains('TokenRefreshedEvent'));
      expect(s, contains('eyJh…NiJ9'));
      expect(s, isNot(contains('OiJSU')));
    });

    test('TokenClearedEvent has a stable string', () {
      expect(const TokenClearedEvent().toString(), 'TokenClearedEvent()');
    });

    test('RefreshFailedEvent includes the failure', () {
      const evt = RefreshFailedEvent(Failure.unauthorized(message: 'x'));
      expect(evt.toString(), contains('RefreshFailedEvent'));
      expect(evt.toString(), contains('x'));
    });
  });
}
