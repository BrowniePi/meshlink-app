import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/backend_config.dart';

/// Raised when an auth call cannot complete. The booleans flag the rejections
/// the UI needs to distinguish (pick another email/name, verify your email,
/// wrong credentials); everything else is a generic retryable failure.
class AuthException implements Exception {
  const AuthException(
    this.message, {
    this.emailTaken = false,
    this.usernameTaken = false,
    this.unverified = false,
    this.invalidCredentials = false,
  });
  final String message;
  final bool emailTaken;
  final bool usernameTaken;
  final bool unverified;
  final bool invalidCredentials;
  @override
  String toString() => message;
}

/// An authenticated account session: a short-lived access JWT plus the opaque
/// refresh token that mints the next one. [username] is the mesh handle the
/// account is bound to.
class Session {
  const Session({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.username,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String username;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
        'username': username,
      };

  static Session fromJson(Map<String, dynamic> json) => Session(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (json['expires_at'] as int) * 1000,
        ),
        username: json['username'] as String,
      );
}

/// Client for the backend `/auth/*` account endpoints. FastAPI is the auth
/// authority; the account (email + password) is the durable identity, and the
/// device keypairs sent on signup/login are bound to it server-side.
class AuthClient {
  AuthClient({required this.config, http.Client? client})
      : _client = client ?? http.Client();

  final BackendConfig config;
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('${config.baseUrl}$path');

  Future<http.Response> _post(String path, Map<String, dynamic> body) async {
    try {
      return await _client.post(
        _uri(path),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (e) {
      throw AuthException('Backend unreachable: $e');
    }
  }

  String _detail(http.Response r) {
    try {
      return (jsonDecode(r.body) as Map<String, dynamic>)['detail'] as String;
    } catch (_) {
      return '';
    }
  }

  /// POST /auth/signup — create the account + public directory row and trigger
  /// the verification email. No session is returned; login is blocked until
  /// the email is verified.
  Future<void> signup({
    required String email,
    required String username,
    required String password,
    required Uint8List curve25519Pub,
    required Uint8List ed25519Pub,
  }) async {
    final r = await _post('/auth/signup', {
      'email': email,
      'username': username,
      'password': password,
      'curve25519_pub': _hex(curve25519Pub),
      'ed25519_pub': _hex(ed25519Pub),
    });
    if (r.statusCode == 409) {
      final detail = _detail(r);
      if (detail.contains('email')) {
        throw const AuthException('That email is already registered',
            emailTaken: true);
      }
      throw const AuthException('That username is taken', usernameTaken: true);
    }
    if (r.statusCode == 422) {
      throw const AuthException(
          'Check your email, username, and 8+ character password');
    }
    if (r.statusCode != 201) {
      throw AuthException('Signup failed (${r.statusCode})');
    }
  }

  /// POST /auth/login — verify credentials and bind these (fresh) device keys
  /// to the account. 403 when the email is unverified; 401 on bad credentials.
  Future<Session> login({
    required String email,
    required String password,
    required Uint8List curve25519Pub,
    required Uint8List ed25519Pub,
  }) async {
    final r = await _post('/auth/login', {
      'email': email,
      'password': password,
      'curve25519_pub': _hex(curve25519Pub),
      'ed25519_pub': _hex(ed25519Pub),
    });
    if (r.statusCode == 403) {
      throw const AuthException('Verify your email before logging in',
          unverified: true);
    }
    if (r.statusCode == 401) {
      throw const AuthException('Incorrect email or password',
          invalidCredentials: true);
    }
    if (r.statusCode != 200) {
      throw AuthException('Login failed (${r.statusCode})');
    }
    return Session.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// POST /auth/refresh — rotate the refresh token and mint a new access
  /// token. The returned session carries the previous username (the response
  /// omits it; the caller supplies it).
  Future<Session> refresh(String refreshToken, {required String username}) async {
    final r = await _post('/auth/refresh', {'refresh_token': refreshToken});
    if (r.statusCode == 401) {
      throw const AuthException('Session expired — please log in again',
          invalidCredentials: true);
    }
    if (r.statusCode != 200) {
      throw AuthException('Refresh failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return Session(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (body['expires_at'] as int) * 1000,
      ),
      username: username,
    );
  }

  /// POST /auth/verify-email — confirm the account with the emailed token.
  Future<void> verifyEmail(String token) async {
    final r = await _post('/auth/verify-email', {'token': token});
    if (r.statusCode == 400) {
      throw const AuthException('That verification link is invalid or expired');
    }
    if (r.statusCode != 200) {
      throw AuthException('Verification failed (${r.statusCode})');
    }
  }

  /// POST /auth/resend-verification — always succeeds server-side (no
  /// enumeration); surfaces only transport failures.
  Future<void> resendVerification(String email) async {
    await _post('/auth/resend-verification', {'email': email});
  }

  /// POST /auth/request-password-reset — always 202 (no enumeration).
  Future<void> requestPasswordReset(String email) async {
    await _post('/auth/request-password-reset', {'email': email});
  }

  /// POST /auth/reset-password — set a new password with the emailed token.
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    final r = await _post('/auth/reset-password', {
      'token': token,
      'new_password': newPassword,
    });
    if (r.statusCode == 400) {
      throw const AuthException('That reset link is invalid or expired');
    }
    if (r.statusCode != 200) {
      throw AuthException('Password reset failed (${r.statusCode})');
    }
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
