import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/backend_config.dart';

/// Raised when a directory call cannot complete. [usernameTaken] is the one
/// definitive rejection onboarding needs to distinguish (pick another name);
/// everything else is retryable.
class DirectoryException implements Exception {
  const DirectoryException(this.message,
      {this.usernameTaken = false, this.notFound = false});
  final String message;
  final bool usernameTaken;
  final bool notFound;
  @override
  String toString() => message;
}

class DirectoryEntry {
  DirectoryEntry(this.username, this.curve25519Pub, this.ed25519Pub);
  final String username;
  final Uint8List curve25519Pub;
  final Uint8List ed25519Pub;
}

/// Client for the backend account/directory endpoints (Phase 5 extension).
/// The backend holds identity + social graph only — nothing here ever sends
/// a location anywhere.
class DirectoryClient {
  DirectoryClient({required this.config, http.Client? client})
      : _client = client ?? http.Client();

  final BackendConfig config;
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('${config.baseUrl}$path');

  /// POST /account — register our username + both public keys.
  Future<void> createAccount({
    required String username,
    required Uint8List curve25519Pub,
    required Uint8List ed25519Pub,
  }) async {
    final http.Response response;
    try {
      response = await _client.post(
        _uri('/account'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'curve25519_pub': _hex(curve25519Pub),
          'ed25519_pub': _hex(ed25519Pub),
        }),
      );
    } catch (e) {
      throw DirectoryException('Backend unreachable: $e');
    }
    if (response.statusCode == 409) {
      throw const DirectoryException('That username is taken',
          usernameTaken: true);
    }
    if (response.statusCode == 422) {
      throw const DirectoryException(
          'Usernames are 1-32 characters of a-z, 0-9, dots, dashes, underscores',
          usernameTaken: true);
    }
    if (response.statusCode != 201) {
      throw DirectoryException('Account creation failed (${response.statusCode})');
    }
  }

  /// GET /directory/{username} — resolve a username to its public keys.
  /// The caller pins these locally (TOFU) — later lookups never overwrite.
  Future<DirectoryEntry> resolve(String username) async {
    final http.Response response;
    try {
      response = await _client.get(_uri('/directory/$username'));
    } catch (e) {
      throw DirectoryException('Backend unreachable: $e');
    }
    if (response.statusCode == 404) {
      throw DirectoryException('No user named "$username"', notFound: true);
    }
    if (response.statusCode != 200) {
      throw DirectoryException('Directory lookup failed (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return DirectoryEntry(
      body['username'] as String,
      _fromHex(body['curve25519_pub'] as String),
      _fromHex(body['ed25519_pub'] as String),
    );
  }

  /// POST /friendships — mirror phone-authoritative state for recovery.
  /// Fire-and-forget: the mesh works without the backend; the mirror is
  /// best-effort (phones remain the source of truth).
  Future<void> mirrorFriendship({
    required String userA,
    required String userB,
    required String state,
    required bool aSharesLoc,
    required bool bSharesLoc,
  }) async {
    try {
      await _client.post(
        _uri('/friendships'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'user_a': userA,
          'user_b': userB,
          'state': state,
          'a_shares_loc': aSharesLoc,
          'b_shares_loc': bSharesLoc,
        }),
      );
    } catch (_) {
      // Offline at the event is normal; the mirror catches up next time.
    }
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
