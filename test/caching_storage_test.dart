import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

class _CountingStorage implements TokenStorage {
  _CountingStorage({required this.onRead});
  final Token? Function() onRead;

  @override
  Future<Token?> read() async => onRead();

  @override
  Future<void> write(Token token) async {}

  @override
  Future<void> delete() async {}
}

void main() {
  group('CachingTokenStorage', () {
    test('delegates first read to backing store', () async {
      final backing = InMemoryTokenStorage(
        initial: const Token(accessToken: 'a'),
      );
      final cache = CachingTokenStorage(backing);
      expect(await cache.read(), const Token(accessToken: 'a'));
    });

    test('subsequent reads do not hit backing store again', () async {
      var hits = 0;
      final backing = _CountingStorage(
        onRead: () {
          hits++;
          return const Token(accessToken: 'a');
        },
      );
      final cache = CachingTokenStorage(backing);

      await cache.read();
      await cache.read();
      await cache.read();

      expect(hits, 1);
    });

    test('write updates cache and backing', () async {
      final backing = InMemoryTokenStorage();
      final cache = CachingTokenStorage(backing);

      const t = Token(accessToken: 'new');
      await cache.write(t);

      expect(cache.cachedToken, t);
      expect(await backing.read(), t);
    });

    test('delete clears cache and backing', () async {
      final backing = InMemoryTokenStorage(
        initial: const Token(accessToken: 'a'),
      );
      final cache = CachingTokenStorage(backing);

      await cache.read();
      await cache.delete();

      expect(cache.cachedToken, isNull);
      expect(await backing.read(), isNull);
    });

    test('invalidate forces re-read from backing', () async {
      var hits = 0;
      final backing = _CountingStorage(
        onRead: () {
          hits++;
          return const Token(accessToken: 'a');
        },
      );
      final cache = CachingTokenStorage(backing);

      await cache.read();
      cache.invalidate();
      await cache.read();

      expect(hits, 2);
    });

    test('cachedToken is null before first read', () {
      final cache = CachingTokenStorage(InMemoryTokenStorage());
      expect(cache.cachedToken, isNull);
    });
  });
}
