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

/// Client for Supabase GoTrue (`/auth/v1/*`). Supabase is the auth authority;
/// the account (email + password) is the durable identity. The device
/// keypairs ride in the signup metadata (a DB trigger creates the public
/// `profiles` directory row from them) and are re-bound on every login by
/// PATCHing our own profiles row.
class AuthClient {
  AuthClient({required this.config, http.Client? client})
      : _client = client ?? http.Client();

  final BackendConfig config;
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('${config.baseUrl}$path');

  Map<String, String> _headers([String? bearer]) => {
        'Content-Type': 'application/json',
        'apikey': config.anonKey,
        'Authorization': 'Bearer ${bearer ?? config.anonKey}',
      };

  Future<http.Response> _post(String path, Map<String, dynamic> body,
      {String? bearer}) async {
    try {
      return await _client.post(
        _uri(path),
        headers: _headers(bearer),
        body: jsonEncode(body),
      );
    } catch (e) {
      throw AuthException('Backend unreachable: $e');
    }
  }

  /// GoTrue error bodies come in two dialects: `{error_code, msg}` (modern)
  /// and `{error, error_description}` (OAuth-style token endpoint).
  ({String code, String message}) _error(http.Response r) {
    try {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      return (
        code: (body['error_code'] ?? body['error'] ?? '') as String,
        message:
            (body['msg'] ?? body['error_description'] ?? body['message'] ?? '')
                as String,
      );
    } catch (_) {
      return (code: '', message: '');
    }
  }

  Session _parseSession(Map<String, dynamic> body, {String? username}) {
    final expiresAt = body['expires_at'] is int
        ? DateTime.fromMillisecondsSinceEpoch((body['expires_at'] as int) * 1000)
        : DateTime.now().add(Duration(seconds: body['expires_in'] as int));
    final user = body['user'] as Map<String, dynamic>?;
    final metadata = user?['user_metadata'] as Map<String, dynamic>?;
    return Session(
      accessToken: body['access_token'] as String,
      refreshToken: body['refresh_token'] as String,
      expiresAt: expiresAt,
      username: (metadata?['username'] as String?) ?? username ?? '',
    );
  }

  /// Create the account and trigger the verification email. The username +
  /// device keys ride in the metadata; a trigger creates the directory row
  /// (aborting the signup when the username is taken). No session results —
  /// login is blocked until the email is verified.
  Future<void> signup({
    required String email,
    required String username,
    required String password,
    required Uint8List curve25519Pub,
    required Uint8List ed25519Pub,
  }) async {
    // Pre-check so a taken name is a clean rejection instead of the trigger
    // aborting the auth insert (which GoTrue reports as a generic 500).
    final check = await _post('/rest/v1/rpc/username_available',
        {'name': username});
    if (check.statusCode == 200 && check.body.trim() == 'false') {
      throw const AuthException('That username is taken', usernameTaken: true);
    }
    final r = await _post('/auth/v1/signup', {
      'email': email,
      'password': password,
      'data': {
        'username': username,
        'curve25519_pub': _hex(curve25519Pub),
        'ed25519_pub': _hex(ed25519Pub),
      },
    });
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    final error = _error(r);
    if (error.code.contains('exists') || error.code.contains('registered')) {
      throw const AuthException('That email is already registered',
          emailTaken: true);
    }
    if (r.statusCode == 500) {
      // The profiles trigger aborted the insert — a username race with the
      // pre-check, or invalid metadata.
      throw const AuthException('That username is taken', usernameTaken: true);
    }
    if (r.statusCode == 422 || r.statusCode == 400) {
      throw AuthException(error.message.isNotEmpty
          ? error.message
          : 'Check your email, username, and 8+ character password');
    }
    throw AuthException('Signup failed (${r.statusCode})');
  }

  /// Log in, then bind these (fresh) device keys to the account by updating
  /// our profiles row (the directory nodes and friends resolve keys from).
  Future<Session> login({
    required String email,
    required String password,
    required Uint8List curve25519Pub,
    required Uint8List ed25519Pub,
  }) async {
    final r = await _post('/auth/v1/token?grant_type=password', {
      'email': email,
      'password': password,
    });
    if (r.statusCode != 200) {
      final error = _error(r);
      if (error.code == 'email_not_confirmed') {
        throw const AuthException('Verify your email before logging in',
            unverified: true);
      }
      if (error.code == 'invalid_credentials' || error.code == 'invalid_grant') {
        throw const AuthException('Incorrect email or password',
            invalidCredentials: true);
      }
      throw AuthException('Login failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final session = _parseSession(body);
    final userId = (body['user'] as Map<String, dynamic>?)?['id'] as String?;
    if (userId != null) {
      await _rebindKeys(session.accessToken, userId,
          curve25519Pub: curve25519Pub, ed25519Pub: ed25519Pub);
    }
    return session;
  }

  /// PATCH our own profiles row with this device's keys. A new device = a new
  /// mesh identity under the same account; nodes learn the new keys on their
  /// next directory sync. RLS restricts the update to our own row.
  Future<void> _rebindKeys(String accessToken, String userId,
      {required Uint8List curve25519Pub, required Uint8List ed25519Pub}) async {
    try {
      final r = await _client.patch(
        _uri('/rest/v1/profiles?id=eq.$userId'),
        headers: {..._headers(accessToken), 'Prefer': 'return=minimal'},
        body: jsonEncode({
          'curve25519_pub': _hex(curve25519Pub),
          'ed25519_pub': _hex(ed25519Pub),
        }),
      );
      if (r.statusCode >= 300) {
        throw AuthException('Device key rebind failed (${r.statusCode})');
      }
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('Device key rebind failed: $e');
    }
  }

  /// Rotate the refresh token and mint a new access token. [username] is a
  /// fallback for sessions whose user object omits the metadata.
  Future<Session> refresh(String refreshToken, {required String username}) async {
    final r = await _post('/auth/v1/token?grant_type=refresh_token',
        {'refresh_token': refreshToken});
    if (r.statusCode != 200) {
      throw const AuthException('Session expired — please log in again',
          invalidCredentials: true);
    }
    return _parseSession(jsonDecode(r.body) as Map<String, dynamic>,
        username: username);
  }

  /// Confirm the account with the emailed 6-digit code (the email template
  /// includes {{ .Token }}). The verify-pending screen's primary path is
  /// link-click + retry-login, so this is the manual-code fallback.
  Future<void> verifyEmail({required String email, required String token}) async {
    final r = await _post('/auth/v1/verify', {
      'type': 'signup',
      'email': email,
      'token': token,
    });
    if (r.statusCode == 401 || r.statusCode == 403 || r.statusCode == 400) {
      throw const AuthException('That verification code is invalid or expired');
    }
    if (r.statusCode != 200) {
      throw AuthException('Verification failed (${r.statusCode})');
    }
  }

  /// Re-send the signup confirmation email. GoTrue answers 200 regardless of
  /// whether the address exists (no enumeration); surface only transport
  /// failures.
  Future<void> resendVerification(String email) async {
    await _post('/auth/v1/resend', {'type': 'signup', 'email': email});
  }

  /// Request a password-recovery email (no enumeration server-side).
  Future<void> requestPasswordReset(String email) async {
    await _post('/auth/v1/recover', {'email': email});
  }

  /// Set a new password with the emailed recovery code: verify the OTP for a
  /// short-lived session, then update the password with it. GoTrue revokes
  /// the other sessions itself.
  Future<void> resetPassword({
    required String email,
    required String token,
    required String newPassword,
  }) async {
    final r = await _post('/auth/v1/verify', {
      'type': 'recovery',
      'email': email,
      'token': token,
    });
    if (r.statusCode != 200) {
      throw const AuthException('That reset code is invalid or expired');
    }
    final session = _parseSession(jsonDecode(r.body) as Map<String, dynamic>);
    final http.Response update;
    try {
      update = await _client.put(
        _uri('/auth/v1/user'),
        headers: _headers(session.accessToken),
        body: jsonEncode({'password': newPassword}),
      );
    } catch (e) {
      throw AuthException('Backend unreachable: $e');
    }
    if (update.statusCode != 200) {
      final error = _error(update);
      throw AuthException(error.message.isNotEmpty
          ? error.message
          : 'Password reset failed (${update.statusCode})');
    }
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
