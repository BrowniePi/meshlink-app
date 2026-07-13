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

/// Client for the public directory (a Supabase view over profiles) and the
/// friendship mirror RPC. The backend holds identity + social graph only —
/// nothing here ever sends a location anywhere.
class DirectoryClient {
  DirectoryClient({
    required this.config,
    this.accessToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final BackendConfig config;

  /// Bearer supplier for the authenticated mirror RPC (AuthService rotates
  /// it). Null → the mirror silently skips, matching its best-effort nature.
  final Future<String> Function()? accessToken;

  final http.Client _client;

  Uri _uri(String path) => Uri.parse('${config.baseUrl}$path');

  Map<String, String> _headers([String? bearer]) => {
        'Content-Type': 'application/json',
        'apikey': config.anonKey,
        'Authorization': 'Bearer ${bearer ?? config.anonKey}',
      };

  /// Directory rows are created by the signup trigger now; this legacy
  /// registration path only surfaces a taken name early (test harness /
  /// directory-only flows).
  Future<void> createAccount({
    required String username,
    required Uint8List curve25519Pub,
    required Uint8List ed25519Pub,
  }) async {
    final http.Response response;
    try {
      response = await _client.post(
        _uri('/rest/v1/rpc/username_available'),
        headers: _headers(),
        body: jsonEncode({'name': username}),
      );
    } catch (e) {
      throw DirectoryException('Backend unreachable: $e');
    }
    if (response.statusCode == 200 && response.body.trim() == 'false') {
      throw const DirectoryException('That username is taken',
          usernameTaken: true);
    }
  }

  /// Resolve a username to its public keys. The caller pins these locally
  /// (TOFU) — later lookups never overwrite.
  Future<DirectoryEntry> resolve(String username) async {
    final http.Response response;
    try {
      response = await _client.get(
        _uri('/rest/v1/directory?username=eq.$username'),
        headers: _headers(),
      );
    } catch (e) {
      throw DirectoryException('Backend unreachable: $e');
    }
    if (response.statusCode != 200) {
      throw DirectoryException('Directory lookup failed (${response.statusCode})');
    }
    final rows = jsonDecode(response.body) as List;
    if (rows.isEmpty) {
      throw DirectoryException('No user named "$username"', notFound: true);
    }
    final body = rows.first as Map<String, dynamic>;
    return DirectoryEntry(
      body['username'] as String,
      _fromHex(body['curve25519_pub'] as String),
      _fromHex(body['ed25519_pub'] as String),
    );
  }

  /// Mirror phone-authoritative friendship state for recovery
  /// (rpc/mirror_friendship — the caller must be one of the pair).
  /// Fire-and-forget: the mesh works without the backend; the mirror is
  /// best-effort (phones remain the source of truth).
  Future<void> mirrorFriendship({
    required String userA,
    required String userB,
    required String state,
    required bool aSharesLoc,
    required bool bSharesLoc,
  }) async {
    final token = accessToken;
    if (token == null) return;
    try {
      await _client.post(
        _uri('/rest/v1/rpc/mirror_friendship'),
        headers: _headers(await token()),
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

Uint8List _fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
