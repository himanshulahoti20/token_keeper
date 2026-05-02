import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

void main() {
  group('Result', () {
    test('Success exposes value and isSuccess', () {
      const r = Success<int>(42);
      expect(r.isSuccess, isTrue);
      expect(r.isFailure, isFalse);
      expect(r.valueOrNull, 42);
    });

    test('Failure exposes message/type/cause and casts cleanly', () {
      const f = Failure<int>(
        message: 'boom',
        type: FailureType.network,
        cause: 'inner',
      );
      expect(f.isFailure, isTrue);
      expect(f.message, 'boom');
      expect(f.type, FailureType.network);
      final casted = f.cast<String>();
      expect(casted, isA<Failure<String>>());
      expect(casted.message, 'boom');
    });

    test('fold dispatches to the right branch', () {
      const ok = Success<int>(1);
      const bad = Failure<int>(message: 'x', type: FailureType.unknown);
      expect(
        ok.fold(onSuccess: (v) => 'ok-$v', onFailure: (_) => 'fail'),
        'ok-1',
      );
      expect(
        bad.fold(onSuccess: (v) => 'ok-$v', onFailure: (_) => 'fail'),
        'fail',
      );
    });

    test('map transforms only the Success branch', () {
      const ok = Success<int>(2);
      final mapped = ok.map((v) => v * 10);
      expect(mapped, const Success<int>(20));

      const bad = Failure<int>(message: 'x', type: FailureType.unknown);
      final mappedBad = bad.map((v) => v * 10);
      expect(mappedBad, isA<Failure<int>>());
    });
  });
}
