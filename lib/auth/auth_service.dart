import 'package:flutter/foundation.dart';

import '../debug/debug_log.dart' as dbg;
import '../friends/friend_service.dart';
import '../identity/device_identity.dart';
import '../identity/encryption_identity.dart';
import '../identity/token_storage.dart';
import 'auth_client.dart';
import 'session_storage.dart';

/// Re-mint the access token when it is within this window of expiry, so a
/// call that needs a bearer token never presents one about to lapse.
const Duration _accessRefreshMargin = Duration(seconds: 60);

/// Owns the account session (email + password auth), independent of the
/// device's mesh keypairs and the attestation token. The account is the
/// durable identity: signup/login send THIS device's fresh public keys so the
/// backend binds them to the account (a new device = a new mesh identity under
/// the same account).
class AuthService extends ChangeNotifier {
  AuthService({
    required this.client,
    required this.sessionStorage,
    required this.identity,
    required this.encryption,
    required this.tokenStorage,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AuthClient client;
  final SessionStorage sessionStorage;
  final DeviceIdentity identity;
  final EncryptionIdentity encryption;
  final TokenStorage tokenStorage;
  final DateTime Function() _now;

  /// The FriendService is built in the widget tree (it needs the transport and
  /// pipeline), so it's attached after construction. Binding the account's
  /// username into the FriendStore happens through it on login/refresh.
  FriendService? _friends;
  void attachFriends(FriendService friends) => _friends = friends;

  Session? _session;
  Session? get session => _session;
  bool get isLoggedIn => _session != null;

  /// Load any persisted session at startup. The device keys bound to it may be
  /// stale (e.g. after a reinstall) — the next login rebinds them.
  Future<void> init() async {
    _session = await sessionStorage.read();
    dbg.DebugLog.instance.log(
        'auth',
        _session == null
            ? 'init: no persisted session'
            : 'init: restored session for ${_session!.username} '
                '(expires ${_session!.expiresAt.toIso8601String()})');
    notifyListeners();
  }

  /// Create an account. No session results — the caller routes to the
  /// verify-pending screen; login is blocked until the email is verified.
  Future<void> signup({
    required String email,
    required String username,
    required String password,
  }) async {
    dbg.DebugLog.instance
        .log('auth', 'signup: requesting account $username <$email>');
    try {
      await client.signup(
        email: email,
        username: username,
        password: password,
        curve25519Pub: encryption.publicKey,
        ed25519Pub: identity.publicKey,
      );
    } on AuthException catch (e) {
      dbg.DebugLog.instance
          .log('auth', 'signup failed for <$email>: ${e.message}',
              level: dbg.LogLevel.warn);
      rethrow;
    }
    dbg.DebugLog.instance.log(
        'auth', 'signup ok for <$email> — verification email sent');
  }

  /// Log in, binding this device's fresh keypairs to the account, then persist
  /// the session and record the username as our mesh handle.
  Future<void> login({
    required String email,
    required String password,
  }) async {
    dbg.DebugLog.instance.log('auth', 'login: authenticating <$email>');
    final Session session;
    try {
      session = await client.login(
        email: email,
        password: password,
        curve25519Pub: encryption.publicKey,
        ed25519Pub: identity.publicKey,
      );
    } on AuthException catch (e) {
      dbg.DebugLog.instance.log('auth', 'login failed for <$email>: ${e.message}',
          level: e.unverified ? dbg.LogLevel.warn : dbg.LogLevel.error);
      rethrow;
    }
    dbg.DebugLog.instance
        .log('auth', 'login ok — bound device keys for ${session.username}');
    await _adopt(session);
  }

  /// Clears the account session and the attestation token only. Device
  /// keypairs and the FriendStore friend list are intentionally left intact
  /// (re-login rebinds the same identity to the account).
  Future<void> logout() async {
    dbg.DebugLog.instance.log(
        'auth', 'logout: clearing session for ${_session?.username ?? '?'} '
            'and attestation token');
    _session = null;
    await sessionStorage.clear();
    await tokenStorage.clear();
    notifyListeners();
  }

  Future<void> verifyEmail({required String email, required String token}) async {
    dbg.DebugLog.instance.log('auth', 'verify-email: submitting code');
    try {
      await client.verifyEmail(email: email, token: token);
    } on AuthException catch (e) {
      dbg.DebugLog.instance.log('auth', 'verify-email failed: ${e.message}',
          level: dbg.LogLevel.warn);
      rethrow;
    }
    dbg.DebugLog.instance.log('auth', 'verify-email ok');
  }

  Future<void> resendVerification(String email) {
    dbg.DebugLog.instance
        .log('auth', 'resend-verification requested for <$email>');
    return client.resendVerification(email);
  }

  Future<void> requestReset(String email) {
    dbg.DebugLog.instance
        .log('auth', 'password-reset requested for <$email>');
    return client.requestPasswordReset(email);
  }

  Future<void> resetPassword({
    required String email,
    required String token,
    required String newPassword,
  }) async {
    dbg.DebugLog.instance.log('auth', 'reset-password: submitting new password');
    try {
      await client.resetPassword(
          email: email, token: token, newPassword: newPassword);
    } on AuthException catch (e) {
      dbg.DebugLog.instance.log('auth', 'reset-password failed: ${e.message}',
          level: dbg.LogLevel.warn);
      rethrow;
    }
    dbg.DebugLog.instance.log('auth', 'reset-password ok');
  }

  /// Return a usable access token, transparently rotating the session when the
  /// current access token is at/near expiry. Throws [AuthException] (and logs
  /// the caller out) if the refresh token is no longer valid.
  Future<String> validAccessToken() async {
    final session = _session;
    if (session == null) {
      throw const AuthException('Not logged in');
    }
    if (_now().add(_accessRefreshMargin).isBefore(session.expiresAt)) {
      return session.accessToken;
    }
    dbg.DebugLog.instance.log(
        'auth', 'access token near expiry — rotating for ${session.username}');
    try {
      final rotated =
          await client.refresh(session.refreshToken, username: session.username);
      await _adopt(rotated);
      dbg.DebugLog.instance.log('auth',
          'token refresh ok (new expiry ${rotated.expiresAt.toIso8601String()})');
      return rotated.accessToken;
    } on AuthException catch (e) {
      dbg.DebugLog.instance.log('auth',
          'token refresh failed: ${e.message} — logging out',
          level: dbg.LogLevel.error);
      await logout();
      rethrow;
    }
  }

  Future<void> _adopt(Session session) async {
    _session = session;
    await sessionStorage.write(session);
    await _friends?.bindAccount(session.username);
    dbg.DebugLog.instance
        .log('auth', 'session persisted, mesh handle = ${session.username}');
    notifyListeners();
  }
}
