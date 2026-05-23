import 'dart:convert';

import 'package:test/test.dart';
import 'package:token_keeper/token_keeper.dart';

String _makeJwt(Map<String, dynamic> payload) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final body = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return '$header.$body.fakesig';
}

void main() {
  group('Token.tryParseJwt', () {
    test('extracts exp and space-separated scope claim', () {
      final exp = DateTime.utc(2030, 6, 1).millisecondsSinceEpoch ~/ 1000;
      final token = Token.tryParseJwt(
        _makeJwt({'exp': exp, 'scope': 'read write admin'}),
      );
      expect(token, isNotNull);
      expect(
        token!.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true),
      );
      expect(token.scopes, ['read', 'write', 'admin']);
    });

    test('handles scopes as a JSON array', () {
      final token = Token.tryParseJwt(
        _makeJwt({
          'scopes': ['read', 'write'],
        }),
      );
      expect(token!.scopes, ['read', 'write']);
    });

    test('handles scp claim (Okta-style)', () {
      final token = Token.tryParseJwt(_makeJwt({'scp': 'openid profile'}));
      expect(token!.scopes, ['openid', 'profile']);
    });

    test('null expiresAt when exp claim is absent', () {
      final token = Token.tryParseJwt(_makeJwt({'sub': 'user-1'}));
      expect(token!.expiresAt, isNull);
    });

    test('stores raw jwt as accessToken', () {
      final jwt = _makeJwt({'exp': 9999999999});
      final token = Token.tryParseJwt(jwt);
      expect(token!.accessToken, jwt);
    });

    test('accepts optional refreshToken arg', () {
      final token = Token.tryParseJwt(_makeJwt({}), refreshToken: 'rt-xyz');
      expect(token!.refreshToken, 'rt-xyz');
    });

    test('returns null for malformed JWT (wrong segment count)', () {
      expect(Token.tryParseJwt('not.a.valid.jwt.lol'), isNull);
    });

    test('returns null for invalid base64 payload', () {
      expect(Token.tryParseJwt('header.!!!.sig'), isNull);
    });

    test('returns null for empty string', () {
      expect(Token.tryParseJwt(''), isNull);
    });

    test('returns null when payload is not a JSON object', () {
      final body = base64Url.encode(utf8.encode('"just-a-string"'));
      expect(Token.tryParseJwt('h.$body.s'), isNull);
    });

    test('populates metadata with non-standard claims', () {
      final exp = DateTime.utc(2030, 6, 1).millisecondsSinceEpoch ~/ 1000;
      final token = Token.tryParseJwt(_makeJwt({
        'exp': exp,
        'sub': 'user-1',
        'iss': 'https://auth.example.com',
        'tenant_id': 'acme',
        'role': 'admin',
        'custom_flag': true,
      }));
      expect(token, isNotNull);
      expect(token!.metadata['tenant_id'], 'acme');
      expect(token.metadata['role'], 'admin');
      expect(token.metadata['custom_flag'], true);
    });

    test('excludes standard claims from metadata', () {
      final exp = DateTime.utc(2030, 6, 1).millisecondsSinceEpoch ~/ 1000;
      final token = Token.tryParseJwt(_makeJwt({
        'exp': exp,
        'iat': 1000,
        'nbf': 1000,
        'iss': 'issuer',
        'sub': 'user-1',
        'aud': 'api',
        'jti': 'abc123',
        'scope': 'read write',
        'scp': 'read',
        'scopes': ['read'],
        'tenant_id': 'acme',
      }));
      expect(token!.metadata.containsKey('exp'), isFalse);
      expect(token.metadata.containsKey('iat'), isFalse);
      expect(token.metadata.containsKey('nbf'), isFalse);
      expect(token.metadata.containsKey('iss'), isFalse);
      expect(token.metadata.containsKey('sub'), isFalse);
      expect(token.metadata.containsKey('aud'), isFalse);
      expect(token.metadata.containsKey('jti'), isFalse);
      expect(token.metadata.containsKey('scope'), isFalse);
      expect(token.metadata.containsKey('scp'), isFalse);
      expect(token.metadata.containsKey('scopes'), isFalse);
      expect(token.metadata['tenant_id'], 'acme');
    });

    test('metadata is empty when no non-standard claims are present', () {
      final exp = DateTime.utc(2030, 6, 1).millisecondsSinceEpoch ~/ 1000;
      final token = Token.tryParseJwt(_makeJwt({'exp': exp, 'sub': 'u'}));
      expect(token!.metadata, isEmpty);
    });
  });
}
