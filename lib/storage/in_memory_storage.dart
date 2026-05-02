import '../core/token.dart';
import 'token_storage.dart';

/// A simple, isolate-local [TokenStorage] backed by a single field.
///
/// Useful for tests and short-lived processes. Not durable; tokens are lost
/// when the process exits.
class InMemoryTokenStorage implements TokenStorage {
  /// Creates an empty storage. Pass [initial] to seed it.
  InMemoryTokenStorage({Token? initial}) : _token = initial;

  Token? _token;

  @override
  Future<Token?> read() async => _token;

  @override
  Future<void> write(Token token) async {
    _token = token;
  }

  @override
  Future<void> delete() async {
    _token = null;
  }
}
