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
  });
}
