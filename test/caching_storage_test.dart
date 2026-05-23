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

    test('isCached reflects load state', () async {
      final cache = CachingTokenStorage(
        InMemoryTokenStorage(initial: const Token(accessToken: 'a')),
      );
      expect(cache.isCached, isFalse);
      await cache.read();
      expect(cache.isCached, isTrue);
      cache.invalidate();
      expect(cache.isCached, isFalse);
    });

    test('warmup populates the cache without a read call', () async {
      final cache = CachingTokenStorage(
        InMemoryTokenStorage(initial: const Token(accessToken: 'a')),
      );
      expect(cache.cachedToken, isNull);
      await cache.warmup();
      expect(cache.isCached, isTrue);
      expect(cache.cachedToken, const Token(accessToken: 'a'));
    });

    test('warmup is idempotent', () async {
      var hits = 0;
      final backing = _CountingStorage(
        onRead: () {
          hits++;
          return const Token(accessToken: 'a');
        },
      );
      final cache = CachingTokenStorage(backing);
      await cache.warmup();
      await cache.warmup();
      await cache.warmup();
      expect(hits, 1);
    });

    test('refresh reloads from backing and returns fresh token', () async {
      var readCount = 0;
      final backing = _CountingStorage(
        onRead: () {
          readCount++;
          return Token(accessToken: 'v$readCount');
        },
      );
      final cache = CachingTokenStorage(backing);

      final first = await cache.read();
      expect(first!.accessToken, 'v1');
      expect(readCount, 1);

      final second = await cache.refresh();
      expect(second!.accessToken, 'v2');
      expect(readCount, 2);
    });

    test('refresh updates isCached and cachedToken', () async {
      final backing = InMemoryTokenStorage(
        initial: const Token(accessToken: 'a'),
      );
      final cache = CachingTokenStorage(backing);

      cache.invalidate();
      expect(cache.isCached, isFalse);

      await cache.refresh();
      expect(cache.isCached, isTrue);
      expect(cache.cachedToken, const Token(accessToken: 'a'));
    });
  });
}
