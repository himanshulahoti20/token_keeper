// ignore_for_file: avoid_print
//
// A self-contained example that demonstrates every major feature added in
// token_keeper 1.2.0:
//
//   • CachingTokenStorage  — warm startup, invalidate, refresh
//   • TokenKeeper          — single-flight refresh, proactive window,
//                            withValidToken, forceRefresh
//   • currentTokenStream() — seed + subscribe in one call
//   • onEvent<T>()         — typed event subscriptions
//   • Token.metadata       — non-standard claims from tryParseJwt
//   • TokenRefreshTimer    — periodic background refresh + runNow()
//   • TokenKeeperInterceptor — header attachment + 401 retry
//
// The "backend" is simulated inline so this file runs without a real server.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:resilify/resilify_dio.dart' show mapDioException;
import 'package:token_keeper/dio.dart';
import 'package:token_keeper/token_keeper.dart';

// ---------------------------------------------------------------------------
// 1. Storage
// ---------------------------------------------------------------------------

final storage = CachingTokenStorage(InMemoryTokenStorage());

// ---------------------------------------------------------------------------
// 2. Refresher
// ---------------------------------------------------------------------------

final _refresherDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));

Future<Result<Token>> _refresh(Token current) {
  return Result.tryRunAsync<Token>(
    () async {
      final res = await _refresherDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refreshToken': current.refreshToken},
      );
      final body = res.data!;
      // tryParseJwt extracts exp, scopes, and any non-standard claims
      // (tenant_id, role, …) into Token.metadata automatically.
      final jwt = body['access_token'] as String;
      return Token.tryParseJwt(
            jwt,
            refreshToken: body['refresh_token'] as String?,
          ) ??
          Token(
            accessToken: jwt,
            refreshToken: body['refresh_token'] as String?,
            expiresAt: DateTime.now().add(
              Duration(seconds: body['expires_in'] as int),
            ),
          );
    },
    onError: (e, st) =>
        e is DioException ? mapDioException(e) : Failure.unknown(cause: e),
  );
}

// ---------------------------------------------------------------------------
// 3. Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  // ---- Keeper ---------------------------------------------------------------

  final keeper = TokenKeeper(
    storage: storage,
    refresher: _refresh,
    proactiveWindow: const Duration(seconds: 30),
    retryConfig: RefreshRetryConfig.exponential(maxAttempts: 3),
    logger: (level, message, {error, stackTrace}) {
      print('[token_keeper][${level.name}] $message');
    },
  );

  // ---- Typed event subscriptions (onEvent<T>) -------------------------------

  keeper.onEvent<TokenRefreshedEvent>().listen((e) {
    print('-> token refreshed: ${e.token.maskedAccessToken}');
    if (e.token.metadata.isNotEmpty) {
      print('   metadata: ${e.token.metadata}');
    }
  });

  keeper.onEvent<TokenClearedEvent>().listen((_) {
    print('-> session ended; routing to /login');
  });

  keeper.onEvent<RefreshFailedEvent>().listen((e) {
    print('-> refresh failed: ${e.failure.message} (code ${e.failure.code})');
  });

  // ---- Seed + subscribe in one call (currentTokenStream) --------------------
  //
  // Emits the token currently in storage immediately, then every subsequent
  // change — no separate peek() + tokenStream.listen() needed.

  keeper.currentTokenStream().listen((token) {
    if (token == null) {
      print('[stream] no token — user is logged out');
    } else {
      print('[stream] token: ${token.maskedAccessToken}');
    }
  });

  // ---- Dio interceptor ------------------------------------------------------

  final api = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  api.interceptors.add(
    TokenKeeperInterceptor(
      keeper: keeper,
      dio: api,
      onRefreshFailed: (_) => print('navigate to /login'),
    ),
  );

  // ---- Login ----------------------------------------------------------------

  final loginRes = await api.post<Map<String, dynamic>>(
    '/auth/login',
    data: {'email': 'me@example.com', 'password': 'hunter2'},
    options: Options(extra: {'token_keeper_skip_auth': true}),
  );
  final body = loginRes.data!;

  // If the server returns a JWT, tryParseJwt fills metadata automatically.
  final jwt = body['access_token'] as String;
  final token = Token.tryParseJwt(
        jwt,
        refreshToken: body['refresh_token'] as String?,
      ) ??
      Token(
        accessToken: jwt,
        refreshToken: body['refresh_token'] as String?,
        expiresAt: DateTime.now().add(
          Duration(seconds: body['expires_in'] as int),
        ),
      );

  await keeper.setTokens(token);

  // Access metadata extracted from the JWT payload.
  print('tenant: ${token.metadata['tenant_id']}');
  print('role:   ${token.metadata['role']}');

  // ---- Authenticated calls --------------------------------------------------

  final me = await api.get<Map<String, dynamic>>('/me');
  print('me = ${jsonEncode(me.data)}');

  // ---- withValidToken for non-Dio backends ----------------------------------

  final result = await keeper.withValidToken<String>((t) async {
    return Success('hello from ${t.maskedAccessToken}');
  });
  result.when(
    success: print,
    error: (f) => print('failed: ${f.message}'),
  );

  // ---- Background refresh timer ---------------------------------------------
  //
  // Keeps the token warm in services / daemon processes that don't issue
  // HTTP requests frequently enough to rely on the proactiveWindow alone.
  // Set checkInterval < proactiveWindow so each tick has a chance to refresh
  // before actual expiry.

  final timer = TokenRefreshTimer(
    keeper: keeper,
    checkInterval: const Duration(minutes: 5),
    logger: (level, message, {error, stackTrace}) {
      print('[timer][${level.name}] $message');
    },
  );
  timer.start();
  print('timer running: ${timer.isRunning}');

  // On app resume from background, trigger an immediate check without
  // cancelling the periodic schedule.
  await timer.runNow();

  // ---- CachingTokenStorage.refresh() ----------------------------------------
  //
  // After a cross-isolate write to the backing store the in-memory cache
  // may be stale. refresh() invalidates + reloads in one call.

  final fresh = await storage.refresh();
  print('reloaded from backing store: ${fresh?.maskedAccessToken}');

  // ---- Cleanup --------------------------------------------------------------

  timer.dispose();
  await keeper.dispose();
}
