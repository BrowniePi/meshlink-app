import 'dart:convert';

import 'secure_storage.dart';

/// The organiser-issued attestation token as the app holds it: an opaque JWT
/// string plus its expiry. The app never decodes or verifies the JWT — that
/// is the node's job (Phase 5 §3); here it is just a bearer credential to
/// present and to know when to re-fetch.
class AttestationToken {
  const AttestationToken({required this.token, required this.expiresAt});

  /// Compact EdDSA JWT, presented verbatim in the attestation message payload.
  final String token;

  /// Token expiry (from the backend's `expires_at`, Unix seconds).
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Map<String, dynamic> _toJson() => {
        'token': token,
        'expires_at': expiresAt.millisecondsSinceEpoch ~/ 1000,
      };

  static AttestationToken _fromJson(Map<String, dynamic> json) =>
      AttestationToken(
        token: json['token'] as String,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (json['expires_at'] as int) * 1000,
        ),
      );
}

/// Persists the attestation token in the same Phase 4 secure storage that
/// holds the identity seed (Keychain / Keystore via [SecureStorage]). The
/// Phase 5 brief names flutter_secure_storage, but this repo's Phase 4 built
/// a native-bridge [SecureStorage] instead of that package — reusing it keeps
/// one secure store, not two.
class TokenStorage {
  TokenStorage(this._storage);

  final SecureStorage _storage;

  static const String _key = 'meshlink_attestation_token_v1';

  Future<AttestationToken?> read() async {
    final raw = await _storage.read(_key);
    if (raw == null) return null;
    return AttestationToken._fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> write(AttestationToken token) =>
      _storage.write(_key, jsonEncode(token._toJson()));

  Future<void> clear() => _storage.delete(_key);
}
