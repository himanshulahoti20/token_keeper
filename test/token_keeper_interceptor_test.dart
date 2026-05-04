import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:token_keeper/dio.dart';
import 'package:token_keeper/token_keeper.dart';

class _ScriptedAdapter implements HttpClientAdapter {
  final List<ResponseBody Function(RequestOptions options)> _scripts = [];
  final List<RequestOptions> received = [];

  void enqueue(ResponseBody Function(RequestOptions) response) {
    _scripts.add(response);
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    received.add(options);
    if (_scripts.isEmpty) {
      return ResponseBody.fromString('{}', 200);
    }
    final next = _scripts.removeAt(0);
    return next(options);
  }
}

ResponseBody _json(Map<String, dynamic> body, int status) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  late Dio dio;
  late _ScriptedAdapter adapter;
  late InMemoryTokenStorage storage;
  late FixedClock clock;

  setUp(() {
    adapter = _ScriptedAdapter();
    dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
    dio.httpClientAdapter = adapter;
    storage = InMemoryTokenStorage();
    clock = FixedClock(DateTime.utc(2025));
  });

  test('attaches Authorization header from a valid token', () async {
    await storage.write(Token(
      accessToken: 'live-token',
      expiresAt: clock.now().add(const Duration(hours: 1)),
    ));

    final keeper = TokenKeeper(
      storage: storage,
      refresher: (_) async => const Error(Failure.unknown(message: 'no')),
      clock: clock,
    );
    addTearDown(keeper.dispose);

    dio.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: dio));
    adapter.enqueue((_) => _json({'ok': true}, 200));

    final res = await dio.get<Map<String, dynamic>>('/me');
    expect(res.statusCode, 200);
    expect(
      adapter.received.single.headers['Authorization'],
      'Bearer live-token',
    );
  });

  test('on 401 it refreshes and retries the request once', () async {
    await storage.write(Token(
      accessToken: 'old',
      expiresAt: clock.now().add(const Duration(hours: 1)),
    ));

    final keeper = TokenKeeper(
      storage: storage,
      refresher: (current) async => Success(current.copyWith(
        accessToken: 'fresh',
        expiresAt: clock.now().add(const Duration(hours: 1)),
      )),
      clock: clock,
    );
    addTearDown(keeper.dispose);

    dio.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: dio));

    adapter.enqueue((_) => _json({'error': 'unauthorized'}, 401));
    adapter.enqueue((_) => _json({'ok': true}, 200));

    final res = await dio.get<Map<String, dynamic>>('/me');
    expect(res.statusCode, 200);
    expect(adapter.received.length, 2);
    expect(adapter.received[0].headers['Authorization'], 'Bearer old');
    expect(adapter.received[1].headers['Authorization'], 'Bearer fresh');
  });

  test('does not retry more than once on consecutive 401s', () async {
    await storage.write(Token(
      accessToken: 'old',
      expiresAt: clock.now().add(const Duration(hours: 1)),
    ));

    final keeper = TokenKeeper(
      storage: storage,
      refresher: (current) async => Success(current.copyWith(
        accessToken: 'fresh',
        expiresAt: clock.now().add(const Duration(hours: 1)),
      )),
      clock: clock,
    );
    addTearDown(keeper.dispose);

    dio.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: dio));

    adapter.enqueue((_) => _json({'error': 'unauthorized'}, 401));
    adapter.enqueue((_) => _json({'error': 'still unauthorized'}, 401));

    DioException? caught;
    try {
      await dio.get<Map<String, dynamic>>('/me');
    } on DioException catch (e) {
      caught = e;
    }
    expect(caught, isNotNull);
    expect(caught!.response?.statusCode, 401);
    expect(adapter.received.length, 2);
  });

  test('refresh failure with 401 propagates and clears storage', () async {
    await storage.write(Token(
      accessToken: 'old',
      expiresAt: clock.now().add(const Duration(hours: 1)),
    ));

    final keeper = TokenKeeper(
      storage: storage,
      refresher: (_) async => const Error(
        Failure.unauthorized(message: 'revoked'),
      ),
      clock: clock,
    );
    addTearDown(keeper.dispose);

    final cleared = Completer<void>();
    final sub = keeper.events.listen((event) {
      if (event is TokenClearedEvent && !cleared.isCompleted) {
        cleared.complete();
      }
    });
    addTearDown(sub.cancel);

    dio.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: dio));
    adapter.enqueue((_) => _json({'error': 'unauthorized'}, 401));

    DioException? caught;
    try {
      await dio.get<Map<String, dynamic>>('/me');
    } on DioException catch (e) {
      caught = e;
    }
    expect(caught, isNotNull);
    await cleared.future;
    expect(await storage.read(), isNull);
  });

  test('skipTokenKeeper prevents header attachment for one request', () async {
    await storage.write(Token(
      accessToken: 'live',
      expiresAt: clock.now().add(const Duration(hours: 1)),
    ));

    final keeper = TokenKeeper(
      storage: storage,
      refresher: (_) async => const Error(Failure.unknown(message: 'no')),
      clock: clock,
    );
    addTearDown(keeper.dispose);

    dio.interceptors.add(TokenKeeperInterceptor(keeper: keeper, dio: dio));
    adapter.enqueue((_) => _json({'ok': true}, 200));

    final res = await dio.get<Map<String, dynamic>>(
      '/login',
      options: Options(extra: {'token_keeper_skip_auth': true}),
    );
    expect(res.statusCode, 200);
    expect(
      adapter.received.single.headers.containsKey('Authorization'),
      isFalse,
    );
  });

  test('onRefreshFailed callback receives the Failure', () async {
    await storage.write(Token(
      accessToken: 'old',
      expiresAt: clock.now().add(const Duration(hours: 1)),
    ));

    final keeper = TokenKeeper(
      storage: storage,
      refresher: (_) async => const Error(
        Failure.unauthorized(message: 'gone'),
      ),
      clock: clock,
    );
    addTearDown(keeper.dispose);

    Failure? caught;
    dio.interceptors.add(TokenKeeperInterceptor(
      keeper: keeper,
      dio: dio,
      onRefreshFailed: (f) => caught = f,
    ));
    adapter.enqueue((_) => _json({}, 401));

    try {
      await dio.get<dynamic>('/me');
    } on DioException catch (_) {/* expected */}

    expect(caught, isNotNull);
    expect(caught!.code, 401);
    expect(caught!.message, 'gone');
  });
}
