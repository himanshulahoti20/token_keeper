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

  /// Synchronous peek at the currently-stored token.
  ///
  /// Tests often need to assert against the persisted state without awaiting;
  /// production code should prefer [read].
  Token? get snapshot => _token;

  /// Returns a new [InMemoryTokenStorage] seeded with the same token.
  ///
  /// Useful in tests when you need a separate, decoupled storage instance
  /// that shares the starting state but evolves independently.
  InMemoryTokenStorage clone() => InMemoryTokenStorage(initial: _token);

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
