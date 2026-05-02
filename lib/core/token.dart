import 'package:equatable/equatable.dart';

/// An immutable OAuth-style token pair.
///
/// `expiresAt` is optional: not all auth schemes expose lifetime information.
/// When it's `null`, the token is considered non-expiring and proactive
/// refresh is disabled for it.
class Token extends Equatable {
  /// Creates an immutable [Token].
  const Token({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.scopes = const [],
  });

  /// Reconstructs a [Token] from its [toJson] form.
  ///
  /// Throws if [json] is missing required fields or has unexpected types.
  /// Use [fromJsonOrNull] when the input is untrusted.
  factory Token.fromJson(Map<String, dynamic> json) {
    final rawScopes = json['scopes'];
    final scopes = rawScopes is List
        ? List<String>.unmodifiable(rawScopes.map((e) => e as String))
        : const <String>[];
    final rawExpires = json['expiresAt'];
    return Token(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
      expiresAt:
          rawExpires == null ? null : DateTime.parse(rawExpires as String),
      scopes: scopes,
    );
  }

  /// Like [fromJson] but returns `null` on any parse error instead of
  /// throwing. Prefer this at storage boundaries where the persisted data
  /// may be stale or corrupt.
  static Token? fromJsonOrNull(Map<String, dynamic> json) {
    try {
      return Token.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Bearer token used to authenticate requests.
  final String accessToken;

  /// Long-lived token used to obtain a new [accessToken]. May be `null` for
  /// flows that do not issue refresh tokens (e.g. client-credentials).
  final String? refreshToken;

  /// Absolute expiry of [accessToken]. `null` means unknown / non-expiring.
  final DateTime? expiresAt;

  /// Scopes granted with this token.
  final List<String> scopes;

  /// Returns `true` if [expiresAt] is non-null and not in the future.
  ///
  /// `now` is optional — supplying it makes tests deterministic.
  bool isExpired([DateTime? now]) {
    final exp = expiresAt;
    if (exp == null) return false;
    final n = now ?? DateTime.now();
    return !n.isBefore(exp);
  }

  /// Returns `true` when the token is NOT expired.
  ///
  /// Convenience inverse of [isExpired]. Tokens with no [expiresAt] are
  /// always considered valid.
  bool isValid([DateTime? now]) => !isExpired(now);

  /// Returns the time remaining until [expiresAt].
  ///
  /// Returns `null` when [expiresAt] is not set (unknown lifetime).
  /// Returns [Duration.zero] when the token is already expired rather than
  /// a negative duration, so callers can safely use it as a countdown.
  Duration? remainingLifetime([DateTime? now]) {
    final exp = expiresAt;
    if (exp == null) return null;
    final remaining = exp.difference(now ?? DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Returns `true` if the token will expire within [duration] from `now`.
  bool willExpireWithin(Duration duration, [DateTime? now]) {
    final exp = expiresAt;
    if (exp == null) return false;
    final n = now ?? DateTime.now();
    final threshold = n.add(duration);
    return !threshold.isBefore(exp);
  }

  // ---- scope helpers --------------------------------------------------------

  /// Returns `true` if [scope] is present in [scopes].
  ///
  /// Comparison is case-sensitive per RFC 6749 §3.3.
  bool hasScope(String scope) => scopes.contains(scope);

  /// Returns `true` if **all** of [required] are present in [scopes].
  bool hasAllScopes(List<String> required) => required.every(scopes.contains);

  /// Returns `true` if **at least one** of [any] is present in [scopes].
  bool hasAnyScope(List<String> any) => any.any(scopes.contains);

  // ---------------------------------------------------------------------------

  /// Returns a copy with the supplied fields replaced.
  ///
  /// Use [clearRefreshToken] / [clearExpiresAt] to explicitly null those
  /// fields (regular `null` arguments are treated as "no change").
  Token copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    List<String>? scopes,
    bool clearRefreshToken = false,
    bool clearExpiresAt = false,
  }) {
    return Token(
      accessToken: accessToken ?? this.accessToken,
      refreshToken:
          clearRefreshToken ? null : (refreshToken ?? this.refreshToken),
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      scopes: scopes ?? this.scopes,
    );
  }

  /// JSON representation suitable for any [TokenStorage] backend.
  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt?.toIso8601String(),
        'scopes': scopes,
      };

  @override
  List<Object?> get props => [accessToken, refreshToken, expiresAt, scopes];

  @override
  bool get stringify => false;

  @override
  String toString() =>
      'Token(access=***${accessToken.length}, refresh=${refreshToken == null ? 'null' : '***'}, '
      'expiresAt=$expiresAt, scopes=$scopes)';
}
