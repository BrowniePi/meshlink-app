import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshlink_app/auth/auth_client.dart';
import 'package:meshlink_app/auth/auth_service.dart';
import 'package:meshlink_app/auth/session_storage.dart';
import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/identity/device_identity.dart';
import 'package:meshlink_app/identity/encryption_identity.dart';
import 'package:meshlink_app/identity/secure_storage.dart';
import 'package:meshlink_app/identity/token_storage.dart';

const _config = BackendConfig(
    baseUrl: 'http://test', eventId: 'evt-1', anonKey: 'anon-test');

/// In-memory stand-in for the native Keychain/Keystore bridge.
class _FakeStorage implements SecureStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

AuthClient _client(MockClient mock) => AuthClient(config: _config, client: mock);

Uint8List _pub() => Uint8List(32);

String _gotrueSession({String access = 'a.b.c', String refresh = 'refresh-1',
    int expiresAt = 1800000000, String username = 'ada'}) =>
    jsonEncode({
      'access_token': access,
      'refresh_token': refresh,
      'expires_at': expiresAt,
      'expires_in': 3600,
      'user': {
        'id': 'uuid-1',
        'user_metadata': {'username': username},
      },
    });

/// Serves the GoTrue/PostgREST surface a successful login touches: the token
/// grant plus the profiles key-rebind PATCH.
MockClient _loginMock({String sessionBody = ''}) => MockClient((req) async {
      if (req.url.path == '/auth/v1/token') {
        return http.Response(
            sessionBody.isEmpty ? _gotrueSession() : sessionBody, 200);
      }
      if (req.url.path == '/rest/v1/profiles') {
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });

void main() {
  group('AuthClient error mapping', () {
    test('signup pre-check rejects a taken username', () async {
      final client = _client(MockClient((req) async {
        if (req.url.path == '/rest/v1/rpc/username_available') {
          return http.Response('false', 200);
        }
        fail('signup must not be attempted after a failed pre-check');
      }));
      final e = await client
          .signup(email: 'a@x.com', username: 'a', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e! as AuthException).usernameTaken, isTrue);
    });

    test('signup maps user_already_exists → emailTaken', () async {
      final client = _client(MockClient((req) async {
        if (req.url.path == '/rest/v1/rpc/username_available') {
          return http.Response('true', 200);
        }
        return http.Response(
            jsonEncode({
              'code': 422,
              'error_code': 'user_already_exists',
              'msg': 'User already registered',
            }),
            422);
      }));
      final e = await client
          .signup(email: 'a@x.com', username: 'a', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e! as AuthException).emailTaken, isTrue);
    });

    test('login maps email_not_confirmed → unverified and '
        'invalid_credentials → invalidCredentials', () async {
      final unverified = _client(MockClient((_) async => http.Response(
          jsonEncode({
            'code': 400,
            'error_code': 'email_not_confirmed',
            'msg': 'Email not confirmed',
          }),
          400)));
      final e1 = await unverified
          .login(email: 'a@x.com', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e1! as AuthException).unverified, isTrue);

      final bad = _client(MockClient((_) async => http.Response(
          jsonEncode({
            'code': 400,
            'error_code': 'invalid_credentials',
            'msg': 'Invalid login credentials',
          }),
          400)));
      final e2 = await bad
          .login(email: 'a@x.com', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e2! as AuthException).invalidCredentials, isTrue);
    });

    test('login returns a Session on 200 and rebinds the device keys',
        () async {
      var rebindServed = false;
      final client = _client(MockClient((req) async {
        if (req.url.path == '/auth/v1/token') {
          expect(req.url.queryParameters['grant_type'], 'password');
          expect(req.headers['apikey'], 'anon-test');
          return http.Response(_gotrueSession(), 200);
        }
        if (req.url.path == '/rest/v1/profiles' && req.method == 'PATCH') {
          rebindServed = true;
          expect(req.url.queryParameters['id'], 'eq.uuid-1');
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['curve25519_pub'], '00' * 32);
          expect(body['ed25519_pub'], '00' * 32);
          return http.Response('', 204);
        }
        return http.Response('not found', 404);
      }));
      final session = await client.login(
          email: 'a@x.com', password: 'password123',
          curve25519Pub: _pub(), ed25519Pub: _pub());
      expect(session.username, 'ada');
      expect(session.accessToken, 'a.b.c');
      expect(rebindServed, isTrue);
    });
  });

  group('AuthService', () {
    Future<AuthService> build(MockClient mock, SecureStorage storage) async {
      final identity = await DeviceIdentity.loadOrGenerate(storage);
      final encryption = await EncryptionIdentity.loadOrGenerate(storage);
      return AuthService(
        client: AuthClient(config: _config, client: mock),
        sessionStorage: SessionStorage(storage),
        identity: identity,
        encryption: encryption,
        tokenStorage: TokenStorage(storage),
      );
    }

    test('login persists the session and reports logged in', () async {
      final storage = _FakeStorage();
      final mock = _loginMock();
      final auth = await build(mock, storage);
      expect(auth.isLoggedIn, isFalse);
      await auth.login(email: 'a@x.com', password: 'password123');
      expect(auth.isLoggedIn, isTrue);
      // A fresh service restores it from storage.
      final restored = await build(mock, storage);
      await restored.init();
      expect(restored.isLoggedIn, isTrue);
      expect(restored.session!.username, 'ada');
    });

    test('logout clears the session and attestation token', () async {
      final storage = _FakeStorage();
      final mock = _loginMock();
      await TokenStorage(storage).write(AttestationToken(
          token: 'att', expiresAt: DateTime.fromMillisecondsSinceEpoch(0)));
      final auth = await build(mock, storage);
      await auth.login(email: 'a@x.com', password: 'password123');
      await auth.logout();
      expect(auth.isLoggedIn, isFalse);
      expect(await SessionStorage(storage).read(), isNull);
      // logout clears the attestation token too (spec: session + token only)
      expect(await TokenStorage(storage).read(), isNull);
    });

    test('validAccessToken rotates when the access token is expired', () async {
      final storage = _FakeStorage();
      var loginServed = false;
      final mock = MockClient((req) async {
        if (req.url.path == '/rest/v1/profiles') {
          return http.Response('', 204);
        }
        if (req.url.queryParameters['grant_type'] == 'password') {
          loginServed = true;
          return http.Response(
              _gotrueSession(access: 'old', expiresAt: 0), 200);
        }
        // grant_type=refresh_token
        return http.Response(
            _gotrueSession(access: 'fresh', refresh: 'refresh-2'), 200);
      });
      final auth = await build(mock, storage);
      await auth.login(email: 'a@x.com', password: 'password123');
      expect(loginServed, isTrue);
      final token = await auth.validAccessToken();
      expect(token, 'fresh');
      expect(auth.session!.refreshToken, 'refresh-2');
    });
  });
}
