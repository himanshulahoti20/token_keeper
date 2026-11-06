import 'package:dio/dio.dart';
import 'package:resilify/resilify.dart';

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
/// 2. On a `401` (configurable via [shouldRefreshOn]), runs a single-flight
///    refresh via [TokenKeeper.forceRefresh] and retries the request exactly
///    once. The retry is tagged on `RequestOptions.extra` so it can never
///    recurse.
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
  /// * [onRefreshFailed] is invoked when a 401-triggered refresh fails. Use
  ///   it to navigate directly to login from the interceptor layer.
  TokenKeeperInterceptor({
    required this.keeper,
    required this.dio,
    this.headerName = 'Authorization',
    this.scheme = 'Bearer',
    bool Function(Response<dynamic>? response)? shouldRefreshOn,
    this.onRefreshFailed,
    this.onTokenAttached,
    this.shouldAttach,
  }) : _shouldRefreshOn = shouldRefreshOn ?? _defaultShouldRefreshOn;

  /// Token source.
  final TokenKeeper keeper;

  /// Client used to retry requests after a successful refresh.
  final Dio dio;

  /// Header name to set. Defaults to `Authorization`.
  final String headerName;

  /// Scheme prefix for the header. Defaults to `Bearer`.
  final String scheme;

  /// Called when a refresh triggered by a `401` fails. Receives `resilify`'s
  /// non-generic [Failure].
  ///
  /// ```dart
  /// TokenKeeperInterceptor(
  ///   keeper: keeper,
  ///   dio: dio,
  ///   onRefreshFailed: (_) => router.go('/login'),
  /// );
  /// ```
  ///
  /// [TokenKeeper] still emits [RefreshFailedEvent] / [TokenClearedEvent]
  /// regardless of whether this callback is set.
  final void Function(Failure failure)? onRefreshFailed;

  /// Called each time a token is successfully attached to an outgoing request.
  ///
  /// Receives the [Token] that was attached and the [RequestOptions] for the
  /// request. Useful for per-request logging, analytics, or debugging without
  /// adding a separate `tokenStream` subscription.
  ///
  /// ```dart
  /// TokenKeeperInterceptor(
  ///   keeper: keeper,
  ///   dio: dio,
  ///   onTokenAttached: (token, options) {
  ///     logger.debug('${options.path}: ${token.maskedAccessToken}');
  ///   },
  /// );
  /// ```
  final void Function(Token token, RequestOptions options)? onTokenAttached;

  /// Decides per request whether to attach the token. Return `false` to send
  /// the request untouched — and to ignore its `401`s (no refresh, no retry).
  ///
  /// Use it to keep the bearer token away from third-party hosts when one
  /// `Dio` talks to several services:
  ///
  /// ```dart
  /// TokenKeeperInterceptor(
  ///   keeper: keeper,
  ///   dio: dio,
  ///   shouldAttach: (o) => o.uri.host == 'api.example.com',
  /// );
  /// ```
  final bool Function(RequestOptions options)? shouldAttach;

  final bool Function(Response<dynamic>? response) _shouldRefreshOn;

  static const String _retryFlag = '_token_keeper_retried';
  static const String _skipAuthFlag = 'token_keeper_skip_auth';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[_skipAuthFlag] == true ||
        !(shouldAttach?.call(options) ?? true)) {
      handler.next(options);
      return;
    }
    final result = await keeper.getValidToken();
    final token = result.dataOrNull;
    if (token != null) {
      options.headers[headerName] = '$scheme ${token.accessToken}';
      onTokenAttached?.call(token, options);
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

    if (alreadyRetried ||
        !(shouldAttach?.call(err.requestOptions) ?? true) ||
        !_shouldRefreshOn(response)) {
      handler.next(err);
      return;
    }

    // If the failing request carried a token that has since been replaced,
    // reuse the newer one instead of refreshing again.
    final sent = err.requestOptions.headers[headerName];
    final prefix = '$scheme ';
    final refreshed = sent is String && sent.startsWith(prefix)
        ? await keeper.refreshIfStale(sent.substring(prefix.length))
        : await keeper.forceRefresh();
    final refreshedToken = refreshed.dataOrNull;
    if (refreshedToken == null) {
      onRefreshFailed?.call(refreshed.errorOrNull!);
      handler.next(err);
      return;
    }

    final retryOptions = _cloneForRetry(
      err.requestOptions,
      refreshedToken.accessToken,
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
