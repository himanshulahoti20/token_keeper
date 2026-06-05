import '../core/token.dart';
import 'token_storage.dart';

/// A [TokenStorage] decorator that keeps an in-memory copy of the last
/// written token so that [read] is effectively synchronous on the hot path.
///
/// Wrap any [TokenStorage] backend (e.g. `flutter_secure_storage`) with this
/// to avoid waiting for disk I/O on every request that calls
/// `TokenKeeper.getValidToken()`:
///
/// ```dart
/// final keeper = TokenKeeper(
///   storage: CachingTokenStorage(SecureStorageAdapter()),
///   refresher: ...,
/// );
/// ```
///
/// All writes and deletes flow through to the backing store *and* update the
/// cache atomically. If another process or isolate may modify the underlying
/// store, call [invalidate] (or [refresh]) to bypass the cache.
class CachingTokenStorage implements TokenStorage {
  /// Creates a caching layer on top of [backing].
  CachingTokenStorage(this._backing);

  final TokenStorage _backing;

  Token? _cache;
  bool _loaded = false;

  /// In-flight backing-store load. Shared across concurrent callers so the
  /// backing store is read at most once even if [read] and [warmup] are
  /// awaited concurrently before the first load completes.
  Future<Token?>? _pendingLoad;

  /// Returns the cached token synchronously without going to the backing
  /// store. Returns `null` if the cache has not been populated yet.
  Token? get cachedToken => _loaded ? _cache : null;

  /// Whether the cache has been populated from the backing store.
  ///
  /// Use this to distinguish "no token stored" from "we haven't checked yet"
  /// in places where you can't `await` a [read].
  bool get isCached => _loaded;

  /// Eagerly populates the cache from the backing store.
  ///
  /// Call this once during app startup so the first [read] on the request
  /// hot path doesn't pay for backing-store I/O. Subsequent calls are
  /// no-ops unless the cache has been [invalidate]d.
  ///
  /// Concurrent calls share a single backing-store read rather than issuing
  /// multiple I/O requests.
  Future<void> warmup() async {
    if (_loaded) return;
    await _load();
  }

  @override
  Future<Token?> read() {
    if (_loaded) return Future.value(_cache);
    return _load();
  }

  @override
  Future<void> write(Token token) async {
    _cache = token;
    _loaded = true;
    _pendingLoad = null;
    await _backing.write(token);
  }

  @override
  Future<void> delete() async {
    _cache = null;
    _loaded = true;
    _pendingLoad = null;
    await _backing.delete();
  }

  /// Invalidates the cache so the next [read] fetches from the backing store.
  void invalidate() {
    _loaded = false;
    _cache = null;
    _pendingLoad = null;
  }

  /// Invalidates the cache and immediately reloads from the backing store.
  ///
  /// Returns the freshly loaded token (`null` if the backing store is empty).
  /// More convenient than calling [invalidate] followed by [read] separately —
  /// useful after a cross-isolate write where the in-memory cache is stale.
  Future<Token?> refresh() {
    invalidate();
    return read();
  }

  /// Single backing-store read, deduplicated across concurrent callers.
  Future<Token?> _load() {
    return _pendingLoad ??= _backing.read().then((token) {
      _cache = token;
      _loaded = true;
      _pendingLoad = null;
      return token;
    });
  }
}
