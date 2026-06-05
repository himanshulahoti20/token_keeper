import '../core/token.dart';

/// Persistence contract for tokens.
///
/// Implementations should be safe to call from any isolate. They should NOT
/// throw — failures should be swallowed or logged. `TokenKeeper` calls these
/// methods on its hot path and treats them as best-effort.
abstract interface class TokenStorage {
  /// Returns the stored token or `null` if none was written.
  Future<Token?> read();

  /// Persists [token], replacing any previous entry.
  Future<void> write(Token token);

  /// Removes any stored token. A no-op if storage is empty.
  Future<void> delete();
}

/// Convenience extensions on any [TokenStorage] implementation.
extension TokenStorageExtension on TokenStorage {
  /// Returns `true` if a token is currently in storage.
  ///
  /// Equivalent to `(await read()) != null` but reads more naturally at
  /// call sites that only need a presence check — e.g. "is the user logged
  /// in?" without needing the token itself.
  Future<bool> exists() async => (await read()) != null;
}
