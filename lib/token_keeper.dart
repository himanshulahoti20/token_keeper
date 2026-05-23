/// `token_keeper` 1.2.0 — auth tokens, handled, on top of `resilify`.
///
/// This barrel re-exports the public surface plus the entire `resilify`
/// `Result<T>` / `Failure` API. The optional Dio integration lives in
/// `package:token_keeper/dio.dart` so pure-Dart consumers don't pay for
/// `dio` if they don't need it.
///
/// ```dart
/// import 'package:token_keeper/token_keeper.dart';
/// import 'package:token_keeper/dio.dart'; // optional
/// ```
///
/// > **`dart:core.Error` collision.** The `Error` variant of `resilify`'s
/// > `Result<T>` shadows `dart:core.Error`. If you need both in the same
/// > file, hide one at the import site:
/// >
/// > ```dart
/// > import 'package:token_keeper/token_keeper.dart';
/// > import 'dart:core' hide Error;
/// > ```
library;

export 'core/clock.dart';
export 'core/events.dart';
export 'core/logger.dart';
// Re-exports the entire resilify surface (Result, Success, Error, Failure,
// RetryHelper, extensions).
export 'core/result.dart';
export 'core/retry_policy.dart';
export 'core/token.dart';
export 'keeper/token_keeper.dart';
export 'keeper/token_refresh_timer.dart';
export 'storage/caching_storage.dart';
export 'storage/in_memory_storage.dart';
export 'storage/token_storage.dart';
