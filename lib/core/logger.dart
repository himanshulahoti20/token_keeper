/// Severity levels for [TokenKeeperLogger].
enum LogLevel {
  /// Verbose tracing — request/refresh lifecycle.
  debug,

  /// Notable lifecycle events (refresh succeeded, tokens cleared).
  info,

  /// Recoverable problems (retry triggered, transient network failure).
  warning,

  /// Unrecoverable refresh failures.
  error,
}

/// A pluggable logging hook. Pass an instance to `TokenKeeper(logger: ...)` to
/// observe internal lifecycle without adding a logging dependency.
typedef TokenKeeperLogger = void Function(
  LogLevel level,
  String message, {
  Object? error,
  StackTrace? stackTrace,
});

/// A logger that drops every message. Used as the default.
void noopLogger(
  LogLevel level,
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) {}
