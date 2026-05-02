import 'package:equatable/equatable.dart';

/// Categorises a [Failure] so callers can branch without inspecting messages.
enum FailureType {
  /// The caller is not (or no longer) authenticated. Usually triggers logout.
  unauthorized,

  /// A transport-level failure (timeout, no connectivity, DNS, etc.).
  network,

  /// Anything else — server 5xx, malformed payloads, programming errors.
  unknown,
}

/// A typed result that is either [Success] or [Failure].
///
/// `token_keeper` never throws across its public surface; every fallible call
/// returns a [Result] so callers handle both branches explicitly.
sealed class Result<T> extends Equatable {
  /// Const constructor for subclasses.
  const Result();

  /// `true` when this result is a [Success].
  bool get isSuccess => this is Success<T>;

  /// `true` when this result is a [Failure].
  bool get isFailure => this is Failure<T>;

  /// Returns the success value or `null` for [Failure].
  T? get valueOrNull => switch (this) {
        Success<T>(:final value) => value,
        Failure<T>() => null,
      };

  /// Folds the result into a single value by handling both branches.
  R fold<R>({
    required R Function(T value) onSuccess,
    required R Function(Failure<T> failure) onFailure,
  }) =>
      switch (this) {
        Success<T>(:final value) => onSuccess(value),
        Failure<T>() => onFailure(this as Failure<T>),
      };

  /// Maps a successful value to another type, propagating any [Failure].
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Success<T>(:final value) => Success<R>(transform(value)),
        Failure<T>(:final message, :final type, :final cause) =>
          Failure<R>(message: message, type: type, cause: cause),
      };
}

/// A successful [Result] carrying [value].
final class Success<T> extends Result<T> {
  /// Creates a successful result.
  const Success(this.value);

  /// The success payload.
  final T value;

  @override
  List<Object?> get props => [value];
}

/// A failed [Result] with a [message], a [type], and an optional [cause].
final class Failure<T> extends Result<T> {
  /// Creates a typed failure.
  const Failure({
    required this.message,
    required this.type,
    this.cause,
  });

  /// Human-readable description of what went wrong.
  final String message;

  /// Failure category — see [FailureType].
  final FailureType type;

  /// Underlying error object (if any). Useful for debugging / logging.
  final Object? cause;

  /// Returns this failure re-typed for a different success type.
  Failure<R> cast<R>() =>
      Failure<R>(message: message, type: type, cause: cause);

  @override
  List<Object?> get props => [message, type, cause];
}
