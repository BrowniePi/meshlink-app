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

const _config = BackendConfig(baseUrl: 'http://test', eventId: 'evt-1');

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

void main() {
  group('AuthClient error mapping', () {
    test('signup maps 409 email vs username by detail', () async {
      final emailTaken = _client(MockClient((_) async =>
          http.Response(jsonEncode({'detail': 'email already registered'}), 409)));
      final e1 = await emailTaken
          .signup(email: 'a@x.com', username: 'a', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e1! as AuthException).emailTaken, isTrue);

      final nameTaken = _client(MockClient((_) async =>
          http.Response(jsonEncode({'detail': 'username already taken'}), 409)));
      final e2 = await nameTaken
          .signup(email: 'a@x.com', username: 'a', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e2! as AuthException).usernameTaken, isTrue);
    });

    test('login maps 403 → unverified and 401 → invalidCredentials', () async {
      final unverified = _client(MockClient((_) async =>
          http.Response(jsonEncode({'detail': 'email not verified'}), 403)));
      final e1 = await unverified
          .login(email: 'a@x.com', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e1! as AuthException).unverified, isTrue);

      final bad = _client(MockClient((_) async =>
          http.Response(jsonEncode({'detail': 'invalid credentials'}), 401)));
      final e2 = await bad
          .login(email: 'a@x.com', password: 'password123',
              curve25519Pub: _pub(), ed25519Pub: _pub())
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((e2! as AuthException).invalidCredentials, isTrue);
    });

    test('login returns a Session on 200', () async {
      final client = _client(MockClient((_) async => http.Response(
          jsonEncode({
            'access_token': 'a.b.c',
            'refresh_token': 'refresh-1',
            'expires_at': 1800000000,
            'username': 'ada',
          }),
          200)));
      final session = await client.login(
          email: 'a@x.com', password: 'password123',
          curve25519Pub: _pub(), ed25519Pub: _pub());
      expect(session.username, 'ada');
      expect(session.accessToken, 'a.b.c');
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
      final mock = MockClient((_) async => http.Response(
          jsonEncode({
            'access_token': 'a.b.c',
            'refresh_token': 'refresh-1',
            'expires_at': 1800000000,
            'username': 'ada',
          }),
          200));
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
      final mock = MockClient((_) async => http.Response(
          jsonEncode({
            'access_token': 'a.b.c',
            'refresh_token': 'refresh-1',
            'expires_at': 1800000000,
            'username': 'ada',
          }),
          200));
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
        if (req.url.path == '/auth/login') {
          loginServed = true;
          return http.Response(
              jsonEncode({
                'access_token': 'old',
                'refresh_token': 'refresh-1',
                'expires_at': 0, // already expired
                'username': 'ada',
              }),
              200);
        }
        // /auth/refresh
        return http.Response(
            jsonEncode({
              'access_token': 'fresh',
              'refresh_token': 'refresh-2',
              'expires_at': 1800000000,
            }),
            200);
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
