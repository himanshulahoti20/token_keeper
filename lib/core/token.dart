import 'dart:convert';

import 'package:equatable/equatable.dart';

/// An immutable OAuth-style token pair.
///
/// `expiresAt` is optional: not all auth schemes expose lifetime information.
/// When it's `null`, the token is considered non-expiring and proactive
/// refresh is disabled for it.
///
/// `metadata` carries arbitrary extra claims — tenant IDs, user IDs, feature
/// flags, or any non-standard JWT payload fields. [tryParseJwt] populates it
/// automatically from non-standard claims.
class Token extends Equatable {
  /// Creates an immutable [Token].
  const Token({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.scopes = const [],
    this.metadata = const {},
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
    final rawMetadata = json['metadata'];
    final metadata = rawMetadata is Map<String, dynamic>
        ? Map<String, dynamic>.unmodifiable(rawMetadata)
        : const <String, dynamic>{};
    return Token(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
      expiresAt:
          rawExpires == null ? null : DateTime.parse(rawExpires as String),
      scopes: scopes,
      metadata: metadata,
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

  /// Parses a JWT [jwt] and returns a [Token] seeded with the `exp` and
  /// `scope` / `scopes` / `scp` claims found in the payload.
  ///
  /// The raw JWT string is stored as [accessToken] verbatim so it can be
  /// attached to requests as-is. [refreshToken] is `null` unless supplied
  /// explicitly; pass it for refresh-token flows.
  ///
  /// Returns `null` if [jwt] is not a valid JWT (wrong segment count,
  /// undecodable payload, etc.). Never throws.
  ///
  /// **Note:** this only parses the payload; it does NOT verify the
  /// signature. Treat the returned [Token] as authoritative only after the
  /// server has accepted it on a subsequent request.
  static Token? tryParseJwt(String jwt, {String? refreshToken}) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;

      final payloadJson = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payloadJson);
      if (claims is! Map<String, dynamic>) return null;

      DateTime? expiresAt;
      final exp = claims['exp'];
      if (exp is int) {
        expiresAt =
            DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      }

      List<String> scopes = const [];
      final scopeClaim = claims['scope'] ?? claims['scp'] ?? claims['scopes'];
      if (scopeClaim is String && scopeClaim.isNotEmpty) {
        scopes = scopeClaim.split(' ').where((s) => s.isNotEmpty).toList();
      } else if (scopeClaim is List) {
        scopes = List<String>.unmodifiable(scopeClaim.cast<String>());
      }

      const standardClaims = {
        'exp', 'iat', 'nbf', 'iss', 'sub', 'aud', 'jti',
        'scope', 'scp', 'scopes',
      };
      final metadata = Map<String, dynamic>.unmodifiable(
        Map.fromEntries(
          claims.entries.where((e) => !standardClaims.contains(e.key)),
        ),
      );

      return Token(
        accessToken: jwt,
        refreshToken: refreshToken,
        expiresAt: expiresAt,
        scopes: scopes,
        metadata: metadata,
      );
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

  /// Arbitrary extra data associated with this token.
  ///
  /// Use this to carry non-standard JWT claims (e.g. tenant ID, user ID,
  /// feature flags) or any custom fields returned alongside the token
  /// response. [tryParseJwt] populates this automatically from all
  /// non-standard claims in the JWT payload.
  final Map<String, dynamic> metadata;

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

  /// Returns the number of whole seconds until [expiresAt], mirroring the
  /// OAuth 2.0 `expires_in` field used in token responses.
  ///
  /// Returns `null` when [expiresAt] is not set. Returns `0` (never negative)
  /// when the token is already expired so callers can re-serialize a token
  /// without producing an invalid `expires_in`.
  int? expiresInSeconds([DateTime? now]) => remainingLifetime(now)?.inSeconds;

  /// Returns `true` if the token will expire within [duration] from `now`.
  bool willExpireWithin(Duration duration, [DateTime? now]) {
    final exp = expiresAt;
    if (exp == null) return false;
    final n = now ?? DateTime.now();
    final threshold = n.add(duration);
    return !threshold.isBefore(exp);
  }

  /// Returns `true` if the token should be refreshed soon.
  ///
  /// By default, this checks if the token will expire within the next 5 minutes.
  /// Useful for proactive refresh logic without having to manage your own
  /// expiry buffer. Pass a custom [window] to override the default.
  bool requiresRefresh(
          {Duration window = const Duration(minutes: 5), DateTime? now}) =>
      willExpireWithin(window, now);

  /// Returns a partially-redacted form of [accessToken] suitable for logs.
  ///
  /// Shows the first 4 and last 4 characters joined by `…` (e.g.
  /// `eyJh…sR2c`). Tokens with 8 characters or fewer are fully redacted as
  /// `***` so short opaque tokens don't leak verbatim.
  ///
  /// Never log the raw [accessToken] in production — use this getter or
  /// [toString] (which already redacts) instead.
  String get maskedAccessToken {
    if (accessToken.length <= 8) return '***';
    return '${accessToken.substring(0, 4)}…'
        '${accessToken.substring(accessToken.length - 4)}';
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

  /// Returns `true` if the token is valid and has **all** of [required] scopes.
  ///
  /// Combines [isValid] and [hasAllScopes] for convenience at request
  /// boundaries where both expiry and scope grants must be checked.
  bool isValidWithAllScopes(List<String> required, [DateTime? now]) =>
      isValid(now) && hasAllScopes(required);

  /// Returns `true` if the token is valid and has **at least one** of [any] scopes.
  ///
  /// Combines [isValid] and [hasAnyScope] for convenience at request
  /// boundaries where both expiry and scope grants must be checked.
  bool isValidWithAnyScope(List<String> any, [DateTime? now]) =>
      isValid(now) && hasAnyScope(any);

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
    Map<String, dynamic>? metadata,
    bool clearRefreshToken = false,
    bool clearExpiresAt = false,
  }) {
    return Token(
      accessToken: accessToken ?? this.accessToken,
      refreshToken:
          clearRefreshToken ? null : (refreshToken ?? this.refreshToken),
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      scopes: scopes ?? this.scopes,
      metadata: metadata ?? this.metadata,
    );
  }

  /// JSON representation suitable for any [TokenStorage] backend.
  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt?.toIso8601String(),
        'scopes': scopes,
        if (metadata.isNotEmpty) 'metadata': metadata,
      };

  @override
  List<Object?> get props => [accessToken, refreshToken, expiresAt, scopes, metadata];

  @override
  bool get stringify => false;

  @override
  String toString() =>
      'Token(access=***${accessToken.length}, refresh=${refreshToken == null ? 'null' : '***'}, '
      'expiresAt=$expiresAt, scopes=$scopes)';
}
