/// Re-exports the `Result<T>` / `Failure` types from `resilify`.
///
/// `token_keeper` 1.1.0 unified its result type with the
/// [`resilify`](https://pub.dev/packages/resilify) package so that callers can
/// share a single `Result` / `Failure` model across token management and the
/// rest of their networking stack.
///
/// > **Heads up — `dart:core.Error` collision.** The [Error] variant from
/// > `resilify` shadows `dart:core.Error`. If you need both in the same file,
/// > hide one at the import site:
/// >
/// > ```dart
/// > import 'package:token_keeper/token_keeper.dart';
/// > import 'dart:core' hide Error;
/// > ```
library;

export 'package:resilify/resilify.dart';
