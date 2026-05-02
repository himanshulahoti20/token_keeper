import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

void main() {
  group('Token', () {
    final fixedNow = DateTime.utc(2025, 1, 1, 12);

    test('isExpired is false when expiresAt is null', () {
      const token = Token(accessToken: 'a');
      expect(token.isExpired(fixedNow), isFalse);
    });

    test('isExpired flips at exactly the expiry instant', () {
      final token = Token(accessToken: 'a', expiresAt: fixedNow);
      expect(token.isExpired(fixedNow), isTrue);
      expect(
        token.isExpired(fixedNow.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('willExpireWithin respects the window', () {
      final token = Token(
        accessToken: 'a',
        expiresAt: fixedNow.add(const Duration(seconds: 30)),
      );
      expect(
        token.willExpireWithin(const Duration(seconds: 60), fixedNow),
        isTrue,
      );
      expect(
        token.willExpireWithin(const Duration(seconds: 10), fixedNow),
        isFalse,
      );
    });

    test('copyWith with clear flags nulls fields', () {
      final t = Token(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: fixedNow,
      );
      final cleared = t.copyWith(
        clearRefreshToken: true,
        clearExpiresAt: true,
      );
      expect(cleared.refreshToken, isNull);
      expect(cleared.expiresAt, isNull);
      expect(cleared.accessToken, 'a');
    });

    test('toJson/fromJson round-trip', () {
      final t = Token(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: fixedNow,
        scopes: const ['email', 'profile'],
      );
      final round = Token.fromJson(t.toJson());
      expect(round, t);
    });

    test('equality via Equatable', () {
      const a = Token(accessToken: 'x', scopes: ['s']);
      const b = Token(accessToken: 'x', scopes: ['s']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
