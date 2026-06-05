import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

void main() {
  group('InMemoryTokenStorage', () {
    test('starts empty', () async {
      final s = InMemoryTokenStorage();
      expect(await s.read(), isNull);
    });

    test('seeds from initial', () async {
      const t = Token(accessToken: 'a');
      final s = InMemoryTokenStorage(initial: t);
      expect(await s.read(), t);
    });

    test('write replaces previous and delete clears', () async {
      final s = InMemoryTokenStorage();
      await s.write(const Token(accessToken: 'a'));
      expect((await s.read())!.accessToken, 'a');
      await s.write(const Token(accessToken: 'b'));
      expect((await s.read())!.accessToken, 'b');
      await s.delete();
      expect(await s.read(), isNull);
    });

    test('snapshot reflects current token synchronously', () async {
      final s = InMemoryTokenStorage();
      expect(s.snapshot, isNull);
      await s.write(const Token(accessToken: 'a'));
      expect(s.snapshot, const Token(accessToken: 'a'));
      await s.delete();
      expect(s.snapshot, isNull);
    });

    group('exists() extension (1.3.0)', () {
      test('returns false when storage is empty', () async {
        final s = InMemoryTokenStorage();
        expect(await s.exists(), isFalse);
      });

      test('returns true when a token is stored', () async {
        final s = InMemoryTokenStorage(initial: const Token(accessToken: 'a'));
        expect(await s.exists(), isTrue);
      });

      test('returns false after delete', () async {
        final s = InMemoryTokenStorage(initial: const Token(accessToken: 'a'));
        await s.delete();
        expect(await s.exists(), isFalse);
      });
    });

    test('clone returns an independent copy seeded with current token',
        () async {
      final original = InMemoryTokenStorage(
        initial: const Token(accessToken: 'a'),
      );
      final copy = original.clone();

      expect(copy.snapshot, const Token(accessToken: 'a'));

      await copy.write(const Token(accessToken: 'b'));
      expect(copy.snapshot, const Token(accessToken: 'b'));
      expect(original.snapshot, const Token(accessToken: 'a'),
          reason: 'clone must not share state with the original');
    });
  });
}
