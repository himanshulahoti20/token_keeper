// ignore_for_file: avoid_print
//
// A self-contained example: simulates a backend, wires Dio with a
// TokenKeeperInterceptor, and shows automatic refresh + 401 retry.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:token_keeper/dio.dart';
import 'package:token_keeper/token_keeper.dart';

Future<void> main() async {
  // 1. Storage (swap for SecureStorageAdapter in production).
  final storage = InMemoryTokenStorage();

  // 2. Refresher: hits your /auth/refresh endpoint. Must NEVER throw —
  //    return a Failure instead.
  final refresherDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
  Future<Result<Token>> refresh(Token current) async {
    try {
      final res = await refresherDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refreshToken': current.refreshToken},
      );
      final body = res.data!;
      return Success(Token(
        accessToken: body['access_token'] as String,
        refreshToken: body['refresh_token'] as String?,
        expiresAt: DateTime.now().add(
          Duration(seconds: body['expires_in'] as int),
        ),
      ));
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        return Failure(
          message: 'Refresh token rejected',
          type: FailureType.unauthorized,
          cause: e,
        );
      }
      return Failure(
        message: e.message ?? 'Network error',
        type: FailureType.network,
        cause: e,
      );
    }
  }

  // 3. Keeper.
  final keeper = TokenKeeper(
    storage: storage,
    refresher: refresh,
    proactiveWindow: const Duration(seconds: 30),
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
  api.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: api));

  // 6. Login (the request that gets the initial tokens skips the interceptor).
  final loginRes = await api.post<Map<String, dynamic>>(
    '/auth/login',
    data: {'email': 'me@example.com', 'password': 'hunter2'},
    options: Options(extra: {'token_keeper_skip_auth': true}),
  );
  final body = loginRes.data!;
  await keeper.setTokens(Token(
    accessToken: body['access_token'] as String,
    refreshToken: body['refresh_token'] as String?,
    expiresAt: DateTime.now().add(
      Duration(seconds: body['expires_in'] as int),
    ),
  ));

  // 7. Authenticated calls — the interceptor handles header + 401 retry.
  final me = await api.get<Map<String, dynamic>>('/me');
  print('me = ${jsonEncode(me.data)}');

  // 8. Or use withValidToken for non-Dio backends.
  final result = await keeper.withValidToken<String>((token) async {
    // ... call your gRPC / GraphQL / whatever ...
    return Success('hello, ${token.accessToken.substring(0, 4)}…');
  });
  print(result);

  await keeper.dispose();
}
