import 'package:equatable/equatable.dart';

import 'result.dart';
import 'token.dart';

/// Events emitted by `TokenKeeper.events`.
///
/// Sealed so `switch` expressions are exhaustive at the call site.
/// Implements [Equatable] so events can be compared directly in tests and
/// state management layers.
sealed class TokenEvent extends Equatable {
  /// Const constructor for subclasses.
  const TokenEvent();
}

/// Emitted after a successful refresh. Carries the new [token].
final class TokenRefreshedEvent extends TokenEvent {
  /// Creates a refresh event with the freshly stored [token].
  const TokenRefreshedEvent(this.token);

  /// The new token now in storage.
  final Token token;

  @override
  List<Object?> get props => [token];
}

/// Emitted whenever stored credentials are wiped — either by an explicit
/// `clear()` call or by an unrecoverable refresh failure.
final class TokenClearedEvent extends TokenEvent {
  /// Creates a clear event.
  const TokenClearedEvent();

  @override
  List<Object?> get props => const [];
}

/// Emitted when a refresh attempt fails. [failure] explains why.
final class RefreshFailedEvent extends TokenEvent {
  /// Creates a refresh-failure event.
  const RefreshFailedEvent(this.failure);

  /// The failure that ended the refresh attempt.
  final Failure<Token> failure;

  @override
  List<Object?> get props => [failure];
}
