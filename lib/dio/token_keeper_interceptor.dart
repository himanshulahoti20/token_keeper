import 'package:dio/dio.dart';

import '../core/result.dart';
import '../core/token.dart';
import '../keeper/token_keeper.dart';

/// Dio interceptor that authenticates requests with [TokenKeeper].
///
/// Behaviour:
///
/// 1. Before each request, fetches a valid token via
///    [TokenKeeper.getValidToken] and sets the auth header. If no token is
///    available the request proceeds *without* the header so anonymous
///    endpoints still work.
/// 2. On a `401`, runs a single-flight refresh via [TokenKeeper.forceRefresh]
///    and retries the request exactly once. The retry is tagged on
///    `RequestOptions.extra` so it can never recurse.
/// 3. If the refresh fails the original error is forwarded unchanged. The
///    [TokenKeeper] itself emits `TokenClearedEvent` for unauthorized refresh
///    failures, which your app should listen to in order to log the user out.
class TokenKeeperInterceptor extends Interceptor {
  /// Creates an interceptor.
  ///
  /// * [keeper] is the source of tokens.
  /// * [dio] is used to retry the original request after a refresh. Pass the
  ///   same `Dio` instance the interceptor is attached to.
  /// * [headerName] / [scheme] customise the auth header (defaults produce
  ///   `Authorization: Bearer <token>`).
  /// * [shouldRefreshOn] lets you treat additional status codes (e.g. `419`)
  ///   as auth failures.
  TokenKeeperInterceptor({
    required this.keeper,
    required this.dio,
    this.headerName = 'Authorization',
    this.scheme = 'Bearer',
    bool Function(Response<dynamic>? response)? shouldRefreshOn,
  }) : _shouldRefreshOn = shouldRefreshOn ?? _defaultShouldRefreshOn;

  /// Token source.
  final TokenKeeper keeper;

  /// Client used to retry requests after a successful refresh.
  final Dio dio;

  /// Header name to set. Defaults to `Authorization`.
  final String headerName;

  /// Scheme prefix for the header. Defaults to `Bearer`.
  final String scheme;

  final bool Function(Response<dynamic>? response) _shouldRefreshOn;

  static const String _retryFlag = '_token_keeper_retried';
  static const String _skipAuthFlag = 'token_keeper_skip_auth';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[_skipAuthFlag] == true) {
      handler.next(options);
      return;
    }
    final result = await keeper.getValidToken();
    if (result is Success<Token>) {
      options.headers[headerName] = '$scheme ${result.value.accessToken}';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    final alreadyRetried = err.requestOptions.extra[_retryFlag] == true;

    if (alreadyRetried || !_shouldRefreshOn(response)) {
      handler.next(err);
      return;
    }

    final refreshed = await keeper.forceRefresh();
    if (refreshed is! Success<Token>) {
      handler.next(err);
      return;
    }

    final retryOptions = _cloneForRetry(
      err.requestOptions,
      refreshed.value.accessToken,
    );

    try {
      final retryResponse = await dio.fetch<dynamic>(retryOptions);
      handler.resolve(retryResponse);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  RequestOptions _cloneForRetry(RequestOptions original, String accessToken) {
    final headers = Map<String, dynamic>.from(original.headers)
      ..[headerName] = '$scheme $accessToken';
    final extra = Map<String, dynamic>.from(original.extra)
      ..[_retryFlag] = true;
    return original.copyWith(headers: headers, extra: extra);
  }

  static bool _defaultShouldRefreshOn(Response<dynamic>? response) =>
      response?.statusCode == 401;
}

/// Extension that lets callers opt out of token attachment for a single
/// request — handy for hitting a token endpoint with the same `Dio`.
extension TokenKeeperRequestOptions on RequestOptions {
  /// Marks this request so [TokenKeeperInterceptor] won't attach a token.
  void skipTokenKeeper() {
    extra[TokenKeeperInterceptor._skipAuthFlag] = true;
  }
}
