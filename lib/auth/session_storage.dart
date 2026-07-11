import 'dart:convert';

import '../identity/secure_storage.dart';
import 'auth_client.dart';

/// Persists the account [Session] in the same native secure store
/// (Keychain / Keystore via [SecureStorage]) that holds the identity seed and
/// attestation token — one secure store for all credentials, mirroring
/// [TokenStorage].
class SessionStorage {
  SessionStorage(this._storage);

  final SecureStorage _storage;

  static const String _key = 'meshlink_session_v1';

  Future<Session?> read() async {
    final raw = await _storage.read(_key);
    if (raw == null) return null;
    return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> write(Session session) =>
      _storage.write(_key, jsonEncode(session.toJson()));

  Future<void> clear() => _storage.delete(_key);
}
