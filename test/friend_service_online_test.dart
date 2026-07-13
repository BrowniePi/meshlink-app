import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/friends/friend_state.dart';
import 'package:meshlink_app/friends/friend_store.dart';
import 'package:meshlink_app/online/online_client.dart';
import 'package:meshlink_app/online/online_service.dart';

import 'helpers/friend_fakes.dart';

/// Online-primary flows: two phones joined by a fake online backend (no mesh
/// contact at all unless a test delivers packets explicitly). Covers friend
/// request/accept/decline over the backend, E2EE DM relay with mesh
/// fallback, and sealed location blobs.
void main() {
  late Map<String, Map<String, String>> registry;
  late FakeOnlineBackend backend;
  late FakePhone alice;
  late FakePhone bob;
  late OnlineService aliceOnline;
  late OnlineService bobOnline;

  OnlineService wireOnline(FakePhone phone, String username) {
    final service = OnlineService(
      client: OnlineClient(
        config: const BackendConfig(baseUrl: 'http://test', eventId: 'test'),
        accessToken: () async => username,
        client: backend.mockClient(registry),
      ),
      accessToken: () async => username,
      baseUrl: 'http://test',
    );
    phone.friends.attachOnline(service);
    service.debugSetConnected(true);
    return service;
  }

  setUp(() async {
    registry = {};
    backend = FakeOnlineBackend();
    alice = await FakePhone.create(registry);
    bob = await FakePhone.create(registry);
    await alice.friends.createAccount('alice');
    await bob.friends.createAccount('bob');
    aliceOnline = wireOnline(alice, 'alice');
    bobOnline = wireOnline(bob, 'bob');
  });

  tearDown(() {
    alice.friends.dispose();
    bob.friends.dispose();
    aliceOnline.dispose();
    bobOnline.dispose();
  });

  Future<void> befriendOnline() async {
    await alice.friends.sendFriendRequest('bob');
    await bobOnline.pollNow();
    await bob.friends.accept('alice');
    await aliceOnline.pollNow();
  }

  test('friend request goes via the backend when online — no mesh spray',
      () async {
    final reached = await alice.friends.sendFriendRequest('bob');
    expect(reached, 1);
    expect(alice.transport.sent, isEmpty); // nothing sprayed
    expect(backend.pendingFor('bob'), ['alice']);

    // Bob's poll surfaces it as an ordinary pending request (explicit
    // consent, keys pinned from the directory).
    await bobOnline.pollNow();
    expect(bob.friends.pendingRequests.map((e) => e.record.peerUsername),
        ['alice']);
  });

  test('accept over the backend completes the mutual-consent handshake',
      () async {
    await befriendOnline();
    expect(bob.friends.friends.single.record.peerUsername, 'alice');
    expect(alice.friends.friends.single.record.peerUsername, 'bob');
    // Neither side auto-shares location (separate consent, same as mesh).
    expect(alice.friends.friends.single.record.locationSharingEnabled, isFalse);
    expect(bob.friends.friends.single.record.locationSharingEnabled, isFalse);
  });

  test('decline over the backend lands as a decline, not silence', () async {
    await alice.friends.sendFriendRequest('bob');
    await bobOnline.pollNow();
    await bob.friends.decline('alice');
    await aliceOnline.pollNow();
    expect(alice.friends.friends, isEmpty);
    expect(
        alice.friends.store.byUsername('bob')!.record.state ==
            FriendshipState.requested,
        isFalse);
  });

  test('a mesh-only outbound request is NOT misread as declined', () async {
    // Alice sends while offline → mesh path.
    aliceOnline.debugSetConnected(false);
    await alice.friends.sendFriendRequest('bob');
    expect(backend.pendingFor('bob'), isEmpty);

    // Back online: the sync must not treat "absent from the server's
    // pending list" as an answer for a request the server never saw...
    aliceOnline.debugSetConnected(true);
    await alice.friends.onFriendEvent();
    expect(alice.friends.store.byUsername('bob')!.record.state,
        FriendshipState.requested);

    // ...instead the retry loop re-delivers it online.
    await alice.friends.resendPendingRequests();
    expect(backend.pendingFor('bob'), ['alice']);
  });

  test('DM rides the backend as ciphertext and lands decoded', () async {
    await befriendOnline();
    bob.transport.drain(); // accept's mesh copy is not what we're testing
    await bob.friends.sendDirectMessage('alice', 'see you at the gate');

    final sent = bob.friends.store.byUsername('alice')!.messages.single;
    expect(sent.via, DmVia.online);
    expect(sent.status, DmStatus.relayed);
    expect(bob.transport.sent, isEmpty); // never sprayed

    // The server saw only ciphertext.
    expect(backend.lastCiphertext, isNotNull);
    expect(utf8.decode(backend.lastCiphertext!, allowMalformed: true),
        isNot(contains('gate')));

    await aliceOnline.pollNow();
    final got = alice.friends.store.byUsername('bob')!.messages.single;
    expect(got.text, 'see you at the gate');
    expect(got.outgoing, isFalse);
    expect(got.via, DmVia.online);

    // Delivered = acked = gone from the server.
    expect(backend.inboxFor('alice'), isEmpty);
  });

  test('DM falls back to the mesh when the relay rejects', () async {
    await befriendOnline();
    backend.failMessages = true;
    await bob.friends.sendDirectMessage('alice', 'radio it is');
    final sent = bob.friends.store.byUsername('alice')!.messages.single;
    expect(sent.via, DmVia.mesh);
    expect(sent.status, DmStatus.relayed); // a peer took the packet
    expect(bob.transport.sent, isNotEmpty);
  });

  test('enabling sharing uploads a sealed blob the friend can open',
      () async {
    await befriendOnline();
    bob.position = (lat: 18.945, lon: 72.835, accuracyM: 8.0);
    await bob.friends.enableLocationSharing('alice');
    // The toggle fires the upload without blocking the UI; the beacon
    // cadence is the deterministic hook.
    await bob.friends.sendBeacon();
    // One blob, for alice only, and it is not plaintext.
    expect(backend.locationBlobs['bob']!.keys, ['alice']);

    final fix = await alice.friends.queryFriendLocation('bob');
    expect(fix, isNotNull);
    expect(fix!.latMicrodeg, 18945000);
    expect(fix.lonMicrodeg, 72835000);
    // Came from the blob, not a mesh query (alice holds no token and
    // sprayed nothing).
    expect(alice.friends.store.byUsername('bob')!.theirTokenToMe, isNull);
  });

  test('disabling sharing revokes the blob server-side', () async {
    await befriendOnline();
    bob.position = (lat: 18.945, lon: 72.835, accuracyM: 8.0);
    await bob.friends.enableLocationSharing('alice');
    await bob.friends.sendBeacon();
    await bob.friends.disableLocationSharing('alice');
    await bob.friends.sendBeacon(); // uploads the now-empty set
    expect(backend.locationBlobs['bob'] ?? const {}, isEmpty);

    final fix = await alice.friends.queryFriendLocation('bob');
    expect(fix, isNull); // uniformly unavailable
  });

  test('token delivery rides the online relay so mesh queries work later',
      () async {
    await befriendOnline();
    bob.position = (lat: 18.945, lon: 72.835, accuracyM: 8.0);
    await bob.friends.enableLocationSharing('alice');
    await aliceOnline.pollNow(); // pulls the FRIEND_ACCEPT token payload
    expect(alice.friends.store.byUsername('bob')!.theirTokenToMe, isNotNull);
  });
}

/// In-memory stand-in for the backend's /online endpoints (plus the
/// friendships mirror read). Auth is the Bearer token itself — the tests
/// mint tokens equal to usernames.
class FakeOnlineBackend {
  /// (from, to) → 'pending' | 'accepted' | 'declined'
  final Map<String, String> requests = {};

  /// canonical "a|b" → state
  final Map<String, String> friendships = {};

  final List<Map<String, String>> messages = [];
  final Map<String, Map<String, String>> locationBlobs = {};
  bool failMessages = false;
  List<int>? lastCiphertext;
  int _nextId = 0;

  List<String> pendingFor(String user) => [
        for (final e in requests.entries)
          if (e.key.endsWith('>$user') && e.value == 'pending')
            e.key.split('>').first
      ];

  List<Map<String, String>> inboxFor(String user) =>
      [for (final m in messages) if (m['to'] == user) m];

  String _pair(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  MockClient mockClient(Map<String, Map<String, String>> registry) {
    return MockClient((request) async {
      final me = request.headers['Authorization']
              ?.replaceFirst('Bearer ', '') ??
          '';
      final path = request.url.path;
      Map<String, dynamic> body() =>
          jsonDecode(request.body) as Map<String, dynamic>;

      if (request.method == 'POST' && path == '/online/friend-requests') {
        final to = body()['to_username'] as String;
        if (!registry.containsKey(to)) return http.Response('{}', 404);
        if (friendships[_pair(me, to)] == 'friends') {
          return http.Response('{}', 409);
        }
        requests['$me>$to'] = 'pending';
        return http.Response(
            jsonEncode({'from_user': me, 'to_user': to, 'state': 'pending',
                        'created_at': 0}),
            201);
      }
      if (request.method == 'GET' && path == '/online/friend-requests') {
        return http.Response(
            jsonEncode({
              'incoming': [
                for (final e in requests.entries)
                  if (e.key.endsWith('>$me') && e.value == 'pending')
                    {'from_user': e.key.split('>').first, 'created_at': 0}
              ],
              'outgoing': [
                for (final e in requests.entries)
                  if (e.key.startsWith('$me>') && e.value == 'pending')
                    {'to_user': e.key.split('>').last, 'created_at': 0}
              ],
            }),
            200);
      }
      final accept = RegExp(r'^/online/friend-requests/([^/]+)/accept$')
          .firstMatch(path);
      if (request.method == 'POST' && accept != null) {
        final from = accept.group(1)!;
        if (requests['$from>$me'] != 'pending') {
          return http.Response('{}', 404);
        }
        requests['$from>$me'] = 'accepted';
        friendships[_pair(from, me)] = 'friends';
        return http.Response(jsonEncode({'friend': registry[from]}), 200);
      }
      final decline = RegExp(r'^/online/friend-requests/([^/]+)/decline$')
          .firstMatch(path);
      if (request.method == 'POST' && decline != null) {
        final from = decline.group(1)!;
        if (requests['$from>$me'] != 'pending') {
          return http.Response('{}', 404);
        }
        requests['$from>$me'] = 'declined';
        return http.Response('{}', 200);
      }

      if (request.method == 'POST' && path == '/online/messages') {
        if (failMessages) return http.Response('{}', 500);
        final to = body()['to_username'] as String;
        if (friendships[_pair(me, to)] != 'friends') {
          return http.Response('{}', 403);
        }
        final ciphertext = body()['ciphertext'] as String;
        lastCiphertext = base64Decode(ciphertext);
        messages.add({
          'id': '${_nextId++}',
          'from': me,
          'to': to,
          'ciphertext': ciphertext,
        });
        return http.Response('{"id":"x","created_at":0}', 201);
      }
      if (request.method == 'GET' && path == '/online/messages') {
        return http.Response(
            jsonEncode({
              'messages': [
                for (final m in inboxFor(me))
                  {'id': m['id'], 'from_user': m['from'],
                   'ciphertext': m['ciphertext'], 'created_at': 0}
              ],
              'count': inboxFor(me).length,
            }),
            200);
      }
      if (request.method == 'POST' && path == '/online/messages/ack') {
        final ids = (body()['ids'] as List).cast<String>();
        messages.removeWhere(
            (m) => m['to'] == me && ids.contains(m['id']));
        return http.Response('{"acked":0}', 200);
      }

      if (request.method == 'PUT' && path == '/online/location') {
        locationBlobs[me] = {
          for (final b in (body()['blobs'] as List)
              .cast<Map<String, dynamic>>())
            b['friend_username'] as String: b['ciphertext'] as String
        };
        return http.Response('{"stored":0}', 200);
      }
      final loc = RegExp(r'^/online/location/([^/]+)$').firstMatch(path);
      if (request.method == 'GET' && loc != null) {
        final blob = locationBlobs[loc.group(1)]?[me];
        if (blob == null) return http.Response('{}', 404);
        return http.Response(
            jsonEncode({
              'ciphertext': blob,
              'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            }),
            200);
      }

      final mirror = RegExp(r'^/friendships/([^/]+)$').firstMatch(path);
      if (request.method == 'GET' && mirror != null) {
        final user = mirror.group(1)!;
        return http.Response(
            jsonEncode({
              'friendships': [
                for (final e in friendships.entries)
                  if (e.key.split('|').contains(user))
                    {
                      'user_a': e.key.split('|').first,
                      'user_b': e.key.split('|').last,
                      'state': e.value,
                    }
              ],
            }),
            200);
      }
      return http.Response('not found', 404);
    });
  }
}
