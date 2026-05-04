// ignore_for_file: avoid_print
//
// A self-contained example: simulates a backend, wires Dio with a
// TokenKeeperInterceptor, and shows automatic refresh + 401 retry.
//
// `token_keeper` 1.1.0 uses `resilify`'s `Result<T>` / `Failure` types, so
// the refresher just bridges DioException onto Failure constructors.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:resilify/resilify_dio.dart' show mapDioException;
import 'package:token_keeper/dio.dart';
import 'package:token_keeper/token_keeper.dart';

Future<void> main() async {
  // 1. Storage (wrap with CachingTokenStorage on top of secure storage in
  //    production).
  final storage = CachingTokenStorage(InMemoryTokenStorage());

  // 2. Refresher: hits your /auth/refresh endpoint. Must NEVER throw —
  //    return a Result.error(Failure.x(...)) instead.
  final refresherDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  Future<Result<Token>> refresh(Token current) async {
    return Result.tryRunAsync<Token>(
      () async {
        final res = await refresherDio.post<Map<String, dynamic>>(
          '/auth/refresh',
          data: {'refreshToken': current.refreshToken},
        );
        final body = res.data!;
        return Token(
          accessToken: body['access_token'] as String,
          refreshToken: body['refresh_token'] as String?,
          expiresAt: DateTime.now().add(
            Duration(seconds: body['expires_in'] as int),
          ),
        );
      },
      // resilify's Dio integration converts DioException into a structured
      // Failure with the right code and message.
      onError: (e, st) =>
          e is DioException ? mapDioException(e) : Failure.unknown(cause: e),
    );
  }

  // 3. Keeper.
  final keeper = TokenKeeper(
    storage: storage,
    refresher: refresh,
    proactiveWindow: const Duration(seconds: 30),
    retryConfig: RefreshRetryConfig.exponential(maxAttempts: 3),
    logger: (level, message, {error, stackTrace}) {
      print('[token_keeper][${level.name}] $message');
    },
  );

  // 4. Listen for logout events.
  keeper.events.listen((event) {
    switch (event) {
      case TokenRefreshedEvent():
        print('-> token refreshed');
      case TokenClearedEvent():
        print('-> session ended; route user to login');
      case RefreshFailedEvent(:final failure):
        print('-> refresh failed: ${failure.message}');
    }
  });

  // 5. App-wide Dio wired up with the interceptor.
  final api = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  api.interceptors.add(
    TokenKeeperInterceptor(
      keeper: keeper,
      dio: api,
      onRefreshFailed: (_) => print('navigate to /login'),
    ),
  );

  // 6. Login (the request that gets the initial tokens skips the interceptor).
  final loginRes = await api.post<Map<String, dynamic>>(
    '/auth/login',
    data: {'email': 'me@example.com', 'password': 'hunter2'},
    options: Options(extra: {'token_keeper_skip_auth': true}),
  );
  final body = loginRes.data!;
  await keeper.setTokens(
    Token(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String?,
      expiresAt: DateTime.now().add(
        Duration(seconds: body['expires_in'] as int),
      ),
    ),
  );

  // 7. Authenticated calls — the interceptor handles header + 401 retry.
  final me = await api.get<Map<String, dynamic>>('/me');
  print('me = ${jsonEncode(me.data)}');

  // 8. Or use withValidToken for non-Dio backends.
  final result = await keeper.withValidToken<String>((token) async {
    return Success('hello, ${token.accessToken.substring(0, 4)}…');
  });
  result.when(
    success: print,
    error: (f) => print('failed: ${f.message}'),
  );

  await keeper.dispose();
}
