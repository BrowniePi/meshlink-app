import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/backend_config.dart';

/// Raised when an online-mode call cannot complete. [notFound] flags the
/// uniform 404 (unknown user / no pending request / location not available);
/// [notFriends] the 403 mutual-consent rejection. Everything else is
/// retryable — the caller falls back to the mesh path.
class OnlineException implements Exception {
  const OnlineException(this.message,
      {this.notFound = false, this.notFriends = false});
  final String message;
  final bool notFound;
  final bool notFriends;
  @override
  String toString() => message;
}

/// One pending friend request, as the backend lists them.
class PendingRequests {
  const PendingRequests({required this.incoming, required this.outgoing});

  /// Usernames who asked to friend ME.
  final List<String> incoming;

  /// Usernames I asked and who haven't answered yet.
  final List<String> outgoing;
}

/// One relayed E2EE message pulled from the inbox.
class RelayedMessage {
  const RelayedMessage({
    required this.id,
    required this.fromUser,
    required this.body,
    required this.createdAt,
  });
  final String id;
  final String fromUser;

  /// Decoded relay body: [1-byte msgType][wire payload] — the same sealed
  /// payloads the mesh carries, so both transports share one decode path.
  final Uint8List body;
  final DateTime createdAt;
}

/// A friend's sealed location blob as stored server-side (latest only).
class LocationBlobResult {
  const LocationBlobResult({required this.payload, required this.updatedAt});

  /// encodeLocationResponse output (hint + sealed coordinate struct).
  final Uint8List payload;
  final DateTime updatedAt;
}

/// Client for the online-mode Supabase surface (PostgREST RPCs + RLS-scoped
/// table reads) — the internet-primary counterpart of the mesh flows. Every
/// call is account-scoped: the access token comes from [accessToken] per
/// request (AuthService rotates it). The server only ever sees ciphertext for
/// messages and locations, and the RPCs keep the old API's status codes
/// (PTxxx SQLSTATEs map straight to HTTP).
class OnlineClient {
  OnlineClient({
    required this.config,
    required this.accessToken,
    bool Function()? fallbackAvailable,
    http.Client? client,
  })  : _fallbackAvailable = fallbackAvailable ?? (() => false),
        _client = client ?? http.Client();

  final BackendConfig config;
  final Future<String> Function() accessToken;
  final bool Function() _fallbackAvailable;
  final http.Client _client;

  /// Whether authenticated REST can currently travel through the mesh node
  /// even though the direct realtime socket is offline.
  bool get fallbackAvailable => _fallbackAvailable();

  Uri _uri(String path) => Uri.parse('${config.baseUrl}$path');

  Future<Map<String, String>> _headers() async => {
        'Content-Type': 'application/json',
        'apikey': config.anonKey,
        'Authorization': 'Bearer ${await accessToken()}',
      };

  Future<http.Response> _get(String path) async {
    try {
      return await _client.get(_uri(path), headers: await _headers());
    } on OnlineException {
      rethrow;
    } catch (e) {
      throw OnlineException('Backend unreachable: $e');
    }
  }

  Future<http.Response> _rpc(String fn, Map<String, dynamic> body) async {
    try {
      return await _client.post(
        _uri('/rest/v1/rpc/$fn'),
        headers: await _headers(),
        body: jsonEncode(body),
      );
    } on OnlineException {
      rethrow;
    } catch (e) {
      throw OnlineException('Backend unreachable: $e');
    }
  }

  Never _fail(http.Response r, String what) {
    if (r.statusCode == 404) {
      throw OnlineException('$what: not found', notFound: true);
    }
    if (r.statusCode == 403) {
      throw OnlineException('$what: not friends', notFriends: true);
    }
    throw OnlineException('$what failed (${r.statusCode})');
  }

  // ---- friend requests ----

  Future<void> sendFriendRequest(String toUsername) async {
    final r = await _rpc('send_friend_request', {'to_username': toUsername});
    if (r.statusCode == 409) return; // already friends — nothing to send
    if (r.statusCode != 200) _fail(r, 'friend request');
  }

  Future<PendingRequests> pendingFriendRequests() async {
    final r = await _rpc('get_friend_requests', {});
    if (r.statusCode != 200) _fail(r, 'friend-request list');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return PendingRequests(
      incoming: [
        for (final m in (body['incoming'] as List).cast<Map<String, dynamic>>())
          m['from_user'] as String
      ],
      outgoing: [
        for (final m in (body['outgoing'] as List).cast<Map<String, dynamic>>())
          m['to_user'] as String
      ],
    );
  }

  Future<void> acceptFriendRequest(String fromUsername) async {
    final r = await _rpc('accept_friend_request', {'from_username': fromUsername});
    if (r.statusCode != 200) _fail(r, 'accept');
  }

  Future<void> declineFriendRequest(String fromUsername) async {
    final r =
        await _rpc('decline_friend_request', {'from_username': fromUsername});
    if (r.statusCode != 200) _fail(r, 'decline');
  }

  /// Server-side friendship state per peer (from the friendships mirror) —
  /// how a requester learns their outbound request was accepted while the
  /// push socket was down. RLS scopes the rows to me; [me] picks the peer
  /// column out of each canonical pair.
  Future<Map<String, String>> friendshipStates(String me) async {
    final r = await _get('/rest/v1/friendships');
    if (r.statusCode != 200) _fail(r, 'friendships');
    final rows = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    return {
      for (final m in rows)
        (m['user_a'] == me ? m['user_b'] : m['user_a']) as String:
            m['state'] as String,
    };
  }

  // ---- E2EE message relay ----

  Future<void> sendRelay(String toUsername, Uint8List body) async {
    final r = await _rpc('send_message', {
      'to_username': toUsername,
      'ciphertext': base64Encode(body),
    });
    if (r.statusCode != 200) _fail(r, 'message');
  }

  Future<List<RelayedMessage>> inbox() async {
    final r = await _get(
        '/rest/v1/relay_messages?select=id,from_user,ciphertext,created_at'
        '&order=created_at.asc,id.asc');
    if (r.statusCode != 200) _fail(r, 'inbox');
    final rows = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
    return [
      for (final m in rows)
        RelayedMessage(
          id: m['id'] as String,
          fromUser: m['from_user'] as String,
          body: base64Decode(m['ciphertext'] as String),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              (m['created_at'] as int) * 1000),
        )
    ];
  }

  Future<void> ackMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final r = await _rpc('ack_messages', {'ids': ids});
    if (r.statusCode != 200) _fail(r, 'ack');
  }

  // ---- push notifications ----

  /// Bind this device's FCM registration token to my account so the backend
  /// can push "new message" wake-ups. Upsert — safe to call on every login
  /// and token rotation.
  Future<void> registerPushToken(String token, String platform) async {
    final r = await _rpc('register_push_token',
        {'push_token': token, 'platform': platform});
    if (r.statusCode != 200) _fail(r, 'push token register');
  }

  /// Unbind on logout so a signed-out device stops getting pushes.
  Future<void> unregisterPushToken(String token) async {
    final r = await _rpc('unregister_push_token', {'push_token': token});
    if (r.statusCode != 200) _fail(r, 'push token unregister');
  }

  // ---- sealed location ----

  /// Replace ALL my blobs — one per friend currently shared with. An empty
  /// map IS the revoke-everyone path.
  Future<void> putLocationBlobs(Map<String, Uint8List> blobsByFriend) async {
    final r = await _rpc('put_location_blobs', {
      'blobs': [
        for (final e in blobsByFriend.entries)
          {'friend_username': e.key, 'ciphertext': base64Encode(e.value)}
      ],
    });
    if (r.statusCode != 200) _fail(r, 'location upload');
  }

  /// The blob [owner] sealed for me. [OnlineException.notFound] uniformly
  /// covers not-sharing / unknown — mirrors the mesh's silent refusal.
  Future<LocationBlobResult> getLocationBlob(String owner) async {
    final r = await _rpc('get_location', {'owner_username': owner});
    if (r.statusCode != 200) _fail(r, 'location');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return LocationBlobResult(
      payload: base64Decode(body['ciphertext'] as String),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (body['updated_at'] as int) * 1000),
    );
  }
}
