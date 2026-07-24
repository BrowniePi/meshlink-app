import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/core/pipeline.dart';
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
  late bool backendFallback;

  OnlineService wireOnline(FakePhone phone, String username) {
    final service = OnlineService(
      client: OnlineClient(
        config: const BackendConfig(baseUrl: 'http://test', eventId: 'test'),
        accessToken: () async => username,
        fallbackAvailable: () => backendFallback,
        client: backend.mockClient(registry),
      ),
      accessToken: () async => username,
      config: const BackendConfig(baseUrl: 'http://test', eventId: 'test'),
    );
    phone.friends.attachOnline(service);
    service.debugSetConnected(true);
    return service;
  }

  setUp(() async {
    registry = {};
    backend = FakeOnlineBackend();
    backendFallback = true;
    alice = await FakePhone.create(registry);
    bob = await FakePhone.create(registry);
    await alice.createAccount('alice');
    await bob.createAccount('bob');
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

  test('friend request goes to the backend AND the mesh simultaneously',
      () async {
    final reached = await alice.friends.sendFriendRequest('bob');
    expect(reached, 2); // the backend + one mesh peer
    expect(alice.transport.sent, isNotEmpty); // sprayed too
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

  test('friendship changes use the backend fallback without internet',
      () async {
    aliceOnline.debugSetConnected(false);
    bobOnline.debugSetConnected(false);

    expect(alice.friends.isOnline, isFalse);
    expect(alice.friends.canReachBackend, isTrue);
    expect(await alice.friends.sendFriendRequest('bob'), 2);
    await bobOnline.pollNow();
    expect(bob.friends.receivedRequests.single.record.peerUsername, 'alice');

    await bob.friends.accept('alice');
    await aliceOnline.pollNow();
    expect(alice.friends.friends.single.record.peerUsername, 'bob');
    expect(bob.friends.friends.single.record.peerUsername, 'alice');
  });

  test('online poll restores a Supabase friendship missing locally', () async {
    backend.friendships[backend.pairForTest('alice', 'bob')] = 'friends';

    await aliceOnline.pollNow();

    expect(alice.friends.friends.single.record.peerUsername, 'bob');
  });

  test('online poll removes a local friendship absent from Supabase',
      () async {
    await befriendOnline();
    backend.friendships.clear();

    await aliceOnline.pollNow();

    expect(alice.friends.friends, isEmpty);
    expect(alice.friends.store.byUsername('bob'), isNull);
  });

  test('clearing account data removes memory and persisted friend state',
      () async {
    await befriendOnline();

    await alice.friends.clearAccountData();
    final reloaded = FriendStore(alice.storage);
    await reloaded.load();

    expect(alice.friends.store.ownUsername, isNull);
    expect(alice.friends.store.entries, isEmpty);
    expect(reloaded.ownUsername, isNull);
    expect(reloaded.entries, isEmpty);
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
    backendFallback = false;
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
    expect(sent.via, DmVia.both); // backend AND mesh, simultaneously
    expect(sent.status, DmStatus.relayed);
    expect(bob.transport.sent, isNotEmpty); // the mesh copy

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

  test('DM still goes out over the mesh when the relay rejects', () async {
    await befriendOnline();
    backend.failMessages = true;
    await bob.friends.sendDirectMessage('alice', 'radio it is');
    final sent = bob.friends.store.byUsername('alice')!.messages.single;
    expect(sent.via, DmVia.mesh);
    expect(sent.status, DmStatus.relayed); // a peer took the packet
    expect(bob.transport.sent, isNotEmpty);
  });

  test('a DM arriving over BOTH transports lands exactly once (online first)',
      () async {
    await befriendOnline();
    bob.transport.drain();
    final notified = <String>[];
    alice.friends.onDmReceived = (from, text, key) => notified.add(key);

    await bob.friends.sendDirectMessage('alice', 'double delivery');
    await aliceOnline.pollNow(); // online copy lands first...
    await bob.deliverTo(alice); // ...then the mesh copy of the SAME message

    final got = alice.friends.store.byUsername('bob')!.messages;
    expect(got, hasLength(1));
    expect(got.single.text, 'double delivery');
    expect(notified, hasLength(1)); // one notification, not two
  });

  test('a DM arriving over BOTH transports lands exactly once (mesh first)',
      () async {
    await befriendOnline();
    bob.transport.drain();

    await bob.friends.sendDirectMessage('alice', 'double delivery');
    await bob.deliverTo(alice); // mesh copy lands first...
    await aliceOnline.pollNow(); // ...then the online copy

    final got = alice.friends.store.byUsername('bob')!.messages;
    expect(got, hasLength(1));
    expect(got.single.text, 'double delivery');
  });

  test('dedup keys survive an app relaunch', () async {
    await befriendOnline();
    bob.transport.drain();
    await bob.friends.sendDirectMessage('alice', 'persist me');
    final meshCopies = bob.transport.drain();
    await aliceOnline.pollNow(); // online copy lands and is recorded

    // Relaunch alice's phone on the same storage; the mesh copy of the
    // pre-relaunch message must still be recognized as a duplicate.
    final alice2 = await FakePhone.createWithStorage(alice.storage, registry);
    for (final packet in meshCopies) {
      final result = await alice2.pipeline.process(packet);
      if (result.outcome == Outcome.deliver) {
        await alice2.friends.handleMessage(result.message!);
      }
    }
    expect(alice2.friends.store.byUsername('bob')!.messages, hasLength(1));
    alice2.friends.dispose();
  });

  test('a friend request arriving over BOTH transports lands once', () async {
    await alice.friends.sendFriendRequest('bob'); // backend + mesh spray
    await bobOnline.pollNow(); // online copy first
    await alice.deliverTo(bob); // mesh copy second — must be ignored

    expect(bob.friends.receivedRequests, hasLength(1));
    expect(bob.friends.receivedRequests.single.record.peerUsername, 'alice');
  });

  test('enabling sharing uploads a sealed blob the friend can open',
      () async {
    await befriendOnline();
    bob.position = (lat: 18.945, lon: 72.835, accuracyM: 8.0);
    await bob.friends.enableLocationSharing('alice');
    // The toggle does not complete until the initial blob is uploaded.
    // One blob, for alice only, and it is not plaintext.
    expect(backend.locationBlobs['bob']!.keys, ['alice']);

    final fix = await alice.friends.queryFriendLocation('bob');
    expect(fix, isNotNull);
    expect(fix!.latMicrodeg, 18945000);
    expect(fix.lonMicrodeg, 72835000);
    // Came from the blob, not a mesh query (alice holds no token and
    // sprayed nothing).
    expect(alice.friends.store.byUsername('bob')!.theirTokenToMe, isNull);

    // A rate-limited refresh still returns the last available fix.
    bob.position = null;
    final last = await alice.friends.queryFriendLocation('bob');
    expect(last, isNotNull);
    expect(last!.latMicrodeg, 18945000);
  });

  test('a new share uploads the last fix when fresh GPS is unavailable',
      () async {
    await befriendOnline();
    bob.position = (lat: 18.945, lon: 72.835, accuracyM: 8.0);
    await bob.friends.sendBeacon(); // remembers the device's last fix
    bob.position = null;

    await bob.friends.enableLocationSharing('alice');

    final fix = await alice.friends.queryFriendLocation('bob');
    expect(fix, isNotNull);
    expect(fix!.latMicrodeg, 18945000);
    expect(fix.lonMicrodeg, 72835000);
  });

  test('disabling sharing revokes the blob server-side', () async {
    await befriendOnline();
    bob.position = (lat: 18.945, lon: 72.835, accuracyM: 8.0);
    await bob.friends.enableLocationSharing('alice');
    await aliceOnline.pollNow();
    expect(alice.friends.store.byUsername('bob')!.theirTokenToMe, isNotNull);
    await bob.friends.disableLocationSharing('alice');
    expect(backend.locationBlobs['bob'] ?? const {}, isEmpty);
    await aliceOnline.pollNow();
    expect(alice.friends.store.byUsername('bob')!.theirTokenToMe, isNull);

    final fix = await alice.friends.queryFriendLocation('bob');
    expect(fix, isNull); // uniformly unavailable
  });

  test('both copies of a DM racing in the SAME tick still land once',
      () async {
    await befriendOnline();
    bob.transport.drain();
    final notified = <String>[];
    alice.friends.onDmReceived = (from, text, key) => notified.add(key);

    await bob.friends.sendDirectMessage('alice', 'simultaneous');
    // Neither delivery is awaited before the other starts, so both run
    // their decode/hash awaits interleaved — the arrival order the
    // parallelized send actually produces.
    await Future.wait([aliceOnline.pollNow(), bob.deliverTo(alice)]);

    final got = alice.friends.store.byUsername('bob')!.messages;
    expect(got, hasLength(1));
    expect(got.single.text, 'simultaneous');
    expect(notified, hasLength(1));
  });

  test('a DM sprays over the mesh without waiting on the backend', () async {
    await befriendOnline();
    alice.transport.sent.clear();

    // Backend held open: a sequential send would still be blocked here.
    final gate = Completer<void>();
    backend.holdMessages = gate;
    final send = alice.friends.sendDirectMessage('bob', 'hi');
    await pumpEventQueue();

    expect(alice.transport.sent, isNotEmpty); // sprayed already
    final dm = alice.friends.store.byUsername('bob')!.messages.last;
    expect(dm.status, DmStatus.relayed); // and shown as sent, not pending
    expect(dm.via, DmVia.mesh);

    gate.complete();
    await send;
    expect(dm.via, DmVia.both); // reconciled once the backend answered
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

  /// When set, send_message blocks until completed — lets a test hold the
  /// online path open and check the mesh path did not wait on it.
  Completer<void>? holdMessages;
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

  String pairForTest(String a, String b) => _pair(a, b);

  MockClient mockClient(Map<String, Map<String, String>> registry) {
    return MockClient((request) async {
      final me = request.headers['Authorization']
              ?.replaceFirst('Bearer ', '') ??
          '';
      final path = request.url.path;
      Map<String, dynamic> body() =>
          jsonDecode(request.body) as Map<String, dynamic>;

      if (request.method == 'POST' &&
          path == '/rest/v1/rpc/send_friend_request') {
        final to = body()['to_username'] as String;
        if (!registry.containsKey(to)) return http.Response('{}', 404);
        if (friendships[_pair(me, to)] == 'friends') {
          return http.Response('{}', 409);
        }
        requests['$me>$to'] = 'pending';
        return http.Response(
            jsonEncode({'from_user': me, 'to_user': to, 'state': 'pending',
                        'created_at': 0}),
            200);
      }
      if (request.method == 'POST' &&
          path == '/rest/v1/rpc/get_friend_requests') {
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
      if (request.method == 'POST' &&
          path == '/rest/v1/rpc/accept_friend_request') {
        final from = body()['from_username'] as String;
        if (requests['$from>$me'] != 'pending') {
          return http.Response('{}', 404);
        }
        requests['$from>$me'] = 'accepted';
        friendships[_pair(from, me)] = 'friends';
        return http.Response(jsonEncode({'friend': registry[from]}), 200);
      }
      if (request.method == 'POST' &&
          path == '/rest/v1/rpc/decline_friend_request') {
        final from = body()['from_username'] as String;
        if (requests['$from>$me'] != 'pending') {
          return http.Response('{}', 404);
        }
        requests['$from>$me'] = 'declined';
        return http.Response('{}', 200);
      }

      if (request.method == 'POST' && path == '/rest/v1/rpc/send_message') {
        if (holdMessages != null) await holdMessages!.future;
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
        return http.Response('{"id":"x","created_at":0}', 200);
      }
      if (request.method == 'GET' && path == '/rest/v1/relay_messages') {
        return http.Response(
            jsonEncode([
              for (final m in inboxFor(me))
                {'id': m['id'], 'from_user': m['from'],
                 'ciphertext': m['ciphertext'], 'created_at': 0}
            ]),
            200);
      }
      if (request.method == 'POST' && path == '/rest/v1/rpc/ack_messages') {
        final ids = (body()['ids'] as List).cast<String>();
        messages.removeWhere(
            (m) => m['to'] == me && ids.contains(m['id']));
        return http.Response('{"acked":0}', 200);
      }

      if (request.method == 'POST' &&
          path == '/rest/v1/rpc/put_location_blobs') {
        locationBlobs[me] = {
          for (final b in (body()['blobs'] as List)
              .cast<Map<String, dynamic>>())
            b['friend_username'] as String: b['ciphertext'] as String
        };
        return http.Response('{"stored":0}', 200);
      }
      if (request.method == 'POST' && path == '/rest/v1/rpc/get_location') {
        final owner = body()['owner_username'] as String;
        final blob = locationBlobs[owner]?[me];
        if (blob == null) return http.Response('{}', 404);
        return http.Response(
            jsonEncode({
              'ciphertext': blob,
              'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            }),
            200);
      }

      if (request.method == 'GET' && path == '/rest/v1/friendships') {
        return http.Response(
            jsonEncode([
              for (final e in friendships.entries)
                if (e.key.split('|').contains(me))
                  {
                    'user_a': e.key.split('|').first,
                    'user_b': e.key.split('|').last,
                    'state': e.value,
                  }
            ]),
            200);
      }
      return http.Response('not found', 404);
    });
  }
}
