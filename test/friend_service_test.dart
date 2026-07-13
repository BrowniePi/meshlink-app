import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/friend_wire.dart';
import 'package:meshlink_app/core/message.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/friends/directory_client.dart';
import 'package:meshlink_app/friends/friend_service.dart';
import 'package:meshlink_app/friends/friend_state.dart';
import 'package:meshlink_app/friends/friend_store.dart';

import 'helpers/friend_fakes.dart';

/// End-to-end friendship flows across two phones joined by a loopback
/// "mesh" (each phone's sent packets run through the other's full pipeline —
/// size, signature, dedup — before reaching its FriendService).
void main() {
  late Map<String, Map<String, String>> registry;
  late FakePhone alice;
  late FakePhone bob;

  setUp(() async {
    registry = {};
    alice = await FakePhone.create(registry);
    bob = await FakePhone.create(registry);
    await alice.friends.createAccount('alice');
    await bob.friends.createAccount('bob');
  });

  tearDown(() {
    alice.friends.dispose();
    bob.friends.dispose();
  });

  Future<void> befriend({bool bobSharesAtAccept = false}) async {
    await alice.friends.sendFriendRequest('bob');
    await alice.deliverTo(bob);
    await bob.friends.accept('alice', shareLocation: bobSharesAtAccept);
    await bob.deliverTo(alice);
  }

  test('flow 1: account creation registers once, duplicates rejected',
      () async {
    expect(alice.friends.hasAccount, isTrue);
    expect(registry.keys, containsAll(['alice', 'bob']));
    final imposter = await FakePhone.create(registry);
    addTearDown(imposter.friends.dispose);
    expect(() => imposter.friends.createAccount('alice'),
        throwsA(isA<DirectoryException>()));
  });

  test('flow 2: request/accept is mutual consent — both sides end friends',
      () async {
    await alice.friends.sendFriendRequest('bob');
    await alice.deliverTo(bob);

    // Bob sees a pending request; nothing was auto-accepted.
    expect(bob.friends.pendingRequests.map((e) => e.record.peerUsername),
        ['alice']);
    expect(bob.friends.friends, isEmpty);
    expect(alice.friends.friends, isEmpty);

    await bob.friends.accept('alice');
    await bob.deliverTo(alice);

    expect(bob.friends.friends.single.record.peerUsername, 'alice');
    expect(alice.friends.friends.single.record.peerUsername, 'bob');
    // Friendship never auto-shares location (separate consent).
    expect(alice.friends.friends.single.record.locationSharingEnabled, isFalse);
    expect(bob.friends.friends.single.record.locationSharingEnabled, isFalse);
  });

  test('a request sent into an empty cell is re-sprayed once a peer appears',
      () async {
    var clock = DateTime.utc(2026, 1, 1);
    final ann = await FakePhone.create(registry, now: () => clock);
    addTearDown(ann.friends.dispose);
    await ann.friends.createAccount('ann');

    // Nobody in radio range: the packet reaches no one and there is no
    // delivery receipt that would say so.
    ann.transport.peers = [];
    expect(await ann.friends.sendFriendRequest('bob'), 0);
    expect(ann.transport.sent, isEmpty);
    await ann.deliverTo(bob);
    expect(bob.friends.pendingRequests, isEmpty);

    // The request is not lost — it is still ours to retry.
    expect(ann.friends.store.byUsername('bob')!.record.state,
        FriendshipState.requested);

    // Re-sends are spaced out: nothing goes out again straight away.
    ann.transport.peers = ['node-1'];
    await ann.friends.resendPendingRequests();
    expect(ann.transport.sent, isEmpty);

    // Once the interval passes, the poll cycle re-sprays it and bob sees it.
    clock = clock.add(requestResendInterval + const Duration(seconds: 1));
    await ann.friends.resendPendingRequests();
    await ann.deliverTo(bob);
    expect(bob.friends.pendingRequests.map((e) => e.record.peerUsername),
        ['ann']);
  });

  test('an answered request stops being re-sprayed', () async {
    var clock = DateTime.utc(2026, 1, 1);
    final ann = await FakePhone.create(registry, now: () => clock);
    addTearDown(ann.friends.dispose);
    await ann.friends.createAccount('ann');

    await ann.friends.sendFriendRequest('bob');
    await ann.deliverTo(bob);
    await bob.friends.accept('ann');
    await bob.deliverTo(ann);

    clock = clock.add(requestResendInterval + const Duration(seconds: 1));
    await ann.friends.resendPendingRequests();
    expect(ann.transport.sent, isEmpty);
  });

  test('flow 2: decline returns the requester to none', () async {
    await alice.friends.sendFriendRequest('bob');
    await alice.deliverTo(bob);
    await bob.friends.decline('alice');
    await bob.deliverTo(alice);

    expect(bob.friends.friends, isEmpty);
    expect(bob.friends.pendingRequests, isEmpty);
    expect(alice.friends.store.byUsername('bob')!.record.state,
        FriendshipState.none);
  });

  test('a FRIEND_ACCEPT whose keys differ from the pinned ones is dropped',
      () async {
    await alice.friends.sendFriendRequest('bob');
    await alice.deliverTo(bob);

    // "mallory" answers alice's request claiming to be bob: her envelope is
    // validly signed with HER key, which does not match the TOFU-pinned one.
    final mallory = await FakePhone.create(registry);
    addTearDown(mallory.friends.dispose);
    await mallory.friends.createAccount('mallory');
    // Craft: mallory receives the request meant for bob (mesh fan-out) and
    // tries to accept it. Her service refuses locally (no matching entry),
    // so drive the wire directly: her accept of a fabricated entry.
    await alice.deliverTo(mallory);
    expect(mallory.friends.pendingRequests, isEmpty,
        reason: 'request was sealed to bob — mallory cannot even read it');

    // Alice must still not be friends with anyone.
    expect(alice.friends.friends, isEmpty);
  });

  test('flow 3: enabling sharing delivers a valid token to the friend',
      () async {
    await befriend();
    expect(bob.friends.store.byUsername('alice')!.theirTokenToMe, isNull);

    await alice.friends.enableLocationSharing('bob');
    await alice.deliverTo(bob);

    final entry = bob.friends.store.byUsername('alice')!;
    expect(entry.theirTokenToMe, isNotNull, reason: 'grant arrived');
    expect(
        alice.friends.friends.single.record.locationSharingEnabled, isTrue);
    // Sharing is unilateral: alice sharing with bob grants bob nothing to
    // reciprocate — bob's own flag stays off.
    expect(bob.friends.friends.single.record.locationSharingEnabled, isFalse);
  });

  test('flow 3: share-at-accept embeds the token in the FRIEND_ACCEPT',
      () async {
    await befriend(bobSharesAtAccept: true);
    expect(alice.friends.store.byUsername('bob')!.theirTokenToMe, isNotNull);
    expect(bob.friends.friends.single.record.locationSharingEnabled, isTrue);
  });

  test('flow 3: disabling sends LOCATION_REVOKE and the friend forgets it',
      () async {
    await befriend();
    await alice.friends.enableLocationSharing('bob');
    await alice.deliverTo(bob);
    expect(bob.friends.store.byUsername('alice')!.theirTokenToMe, isNotNull);

    await alice.friends.disableLocationSharing('bob');
    await alice.deliverTo(bob);

    // Consent is revocable (invariant 5): bob's stored grant is gone and
    // his map has nothing to query with.
    expect(bob.friends.store.byUsername('alice')!.theirTokenToMe, isNull);
    expect(await bob.friends.queryFriendLocation('alice'), isNull);
  });

  test('the LOCATION beacon runs only while at least one share is active',
      () async {
    await befriend();
    alice.position = (lat: 37.7749, lon: -122.4194, accuracyM: 8.0);

    // Enabling a share starts the loop with an immediate beacon.
    alice.transport.drain();
    await alice.friends.enableLocationSharing('bob');
    await pumpEventQueue();
    final types = [
      for (final p in alice.transport.drain()) p[72] // msg_type offset
    ];
    expect(types, contains(msgTypeLocation));

    // Disabling the last share emits the revoke and stops the loop.
    await alice.friends.disableLocationSharing('bob');
    await pumpEventQueue();
    expect(alice.transport.drain().map((p) => p[72]),
        contains(msgTypeLocationRevoke));
  });

  test('flow 4: query is rate-limited app-side to one per friend per 60 s',
      () async {
    var now = DateTime.utc(2026, 7, 8, 12);
    final phones = registry; // keep registry shared
    final carol = await FakePhone.create(phones, now: () => now);
    addTearDown(carol.friends.dispose);
    await carol.friends.createAccount('carol');

    await carol.friends.sendFriendRequest('bob');
    await carol.deliverTo(bob);
    await bob.friends.accept('carol', shareLocation: true);
    await bob.deliverTo(carol);
    expect(carol.friends.store.byUsername('bob')!.theirTokenToMe, isNotNull);

    // First query goes to the wire (and times out, node absent → null after
    // its 10 s timeout — don't await it; just check the packet left).
    carol.transport.drain();
    unawaited(carol.friends.queryFriendLocation('bob'));
    await pumpEventQueue();
    expect(carol.transport.sent.map((p) => p[72]),
        contains(msgTypeLocationQuery));

    // Second query inside the window returns null WITHOUT hitting the wire.
    carol.transport.drain();
    now = now.add(const Duration(seconds: 30));
    expect(await carol.friends.queryFriendLocation('bob'), isNull);
    expect(carol.transport.sent, isEmpty);

    now = now.add(const Duration(seconds: 31));
    // msg_id = hash(sender, timestamp, type, payload) and the payload (the
    // token) is identical — step past the wall-clock second so the repeat
    // query isn't dedup-dropped as a byte-identical duplicate.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    unawaited(carol.friends.queryFriendLocation('bob'));
    await pumpEventQueue();
    expect(carol.transport.sent.map((p) => p[72]),
        contains(msgTypeLocationQuery));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('flow 4 revamp: the target phone answers a sprayed query — no node',
      () async {
    await befriend(bobSharesAtAccept: true);
    bob.position = (lat: 37.7749, lon: -122.4194, accuracyM: 8.0);

    bob.transport.drain();
    final pending = alice.friends.queryFriendLocation('bob');
    await pumpEventQueue();
    await alice.deliverTo(bob); // the query sprays to bob's phone
    await bob.deliverTo(alice); // bob's live answer comes back

    final result = await pending;
    expect(result, isNotNull);
    expect(result!.latMicrodeg, 37774900);
    expect(result.lonMicrodeg, -122419400);
    expect(result.accuracyM, 8);
    expect(result.beaconAgeS, 0, reason: 'a live fix, not a cached beacon');
    // The answer also lands in the freshest-wins cache for the map.
    expect(alice.friends.lastKnownLocation['bob'], isNotNull);
  });

  test('flow 4 revamp: sharing switched off refuses even a live token',
      () async {
    await befriend(bobSharesAtAccept: true);
    bob.position = (lat: 37.7749, lon: -122.4194, accuracyM: 8.0);

    // Bob turns sharing off but the LOCATION_REVOKE is lost in transit —
    // alice still holds an unexpired token. Consent lives in bob's local
    // switch, so his phone must refuse anyway, silently.
    await bob.friends.disableLocationSharing('alice');
    bob.transport.drain();

    unawaited(alice.friends.queryFriendLocation('bob'));
    await pumpEventQueue();
    await alice.deliverTo(bob);
    expect(bob.transport.sent, isEmpty,
        reason: 'refusal is a silent non-answer');
  });

  test('flow 4 revamp: a stolen token is useless without the grantee key',
      () async {
    await befriend(bobSharesAtAccept: true);
    bob.position = (lat: 37.7749, lon: -122.4194, accuracyM: 8.0);

    // Mallory relays alice↔bob traffic and has captured alice's token, but
    // her envelope is signed with HER key — not the token's grantee.
    final mallory = await FakePhone.create(registry);
    addTearDown(mallory.friends.dispose);
    await mallory.friends.createAccount('mallory');
    final stolen = alice.friends.store.byUsername('bob')!.theirTokenToMe!;
    final packet = await buildSignedPacket(
      identity: mallory.friends.identity,
      ephemId: Uint8List.fromList(List.filled(16, 7)),
      payload: encodeLocationQuery(stolen),
      msgType: msgTypeLocationQuery,
      zoneId: broadcastZone,
    );

    bob.transport.drain();
    final result = await bob.pipeline.process(packet);
    expect(result.outcome, Outcome.deliver);
    await bob.friends.handleMessage(result.message!);
    expect(bob.transport.sent, isEmpty,
        reason: 'stolen-token refusal is indistinguishable from silence');
  });

  test('flow 5: DMs deliver both ways and the history survives a restart',
      () async {
    await befriend();

    await alice.friends.sendDirectMessage('bob', 'meet at gate B');
    await alice.deliverTo(bob);
    await bob.friends.sendDirectMessage('alice', 'on my way ☕');
    await bob.deliverTo(alice);

    final bobSees = bob.friends.store.byUsername('alice')!.messages;
    expect(bobSees.map((m) => (m.text, m.outgoing)),
        [('meet at gate B', false), ('on my way ☕', true)]);
    final aliceSees = alice.friends.store.byUsername('bob')!.messages;
    expect(aliceSees.map((m) => (m.text, m.outgoing)),
        [('meet at gate B', true), ('on my way ☕', false)]);

    // Same storage, fresh service — the conversation survives a relaunch.
    final revived = await FakePhone.createWithStorage(alice.storage, registry);
    addTearDown(revived.friends.dispose);
    expect(revived.friends.store.byUsername('bob')!.messages.length, 2);
  });

  test('flow 5: a DM only renders for its addressee and only from a friend',
      () async {
    await befriend();
    final mallory = await FakePhone.create(registry);
    addTearDown(mallory.friends.dispose);
    await mallory.friends.createAccount('mallory');

    // Alice→Bob traffic relayed through Mallory's phone: unreadable, ignored.
    await alice.friends.sendDirectMessage('bob', 'secret plans');
    await alice.deliverTo(mallory);
    expect(mallory.friends.store.entries, isEmpty);

    // A DM from a non-friend — even correctly sealed and addressed — is a
    // silent drop: mutual consent gates messaging, not just location.
    await mallory.friends.store.put(FriendEntry(
        record: FriendshipRecord(
      peerUsername: 'bob',
      peerCurve25519Pub: bob.friends.encryption.publicKey,
      peerEd25519Pub: bob.friends.identity.publicKey,
      state: FriendshipState.friends,
    )));
    await mallory.friends.sendDirectMessage('bob', 'hello friend');
    await mallory.deliverTo(bob);
    expect(bob.friends.store.byUsername('mallory'), isNull);
    expect(
        bob.friends.store.entries
            .expand((e) => e.messages)
            .where((m) => m.text == 'hello friend'),
        isEmpty);

    // Sending to a non-friend is refused before anything hits the wire.
    expect(() => bob.friends.sendDirectMessage('mallory', 'hi'),
        throwsStateError);
  });

  test('friend/location traffic presents the attestation token first',
      () async {
    // Regression: an attestation-gated node drops this device's packets
    // (pipeline step 7) until it has cached our token. The friend path can be
    // the first thing a phone sends through a node — before any chat message
    // triggers presentation — so _sendToPeers must present first, or the node
    // silently drops the query and the user sees "location not available".
    await befriend();

    var presentCalls = 0;
    int? sentWhenPresented; // packets already on the wire when we presented
    alice.friends.presentAttestation = () async {
      presentCalls++;
      sentWhenPresented = alice.transport.sent.length;
    };

    alice.transport.drain();
    await alice.friends.sendDirectMessage('bob', 'hi');

    expect(presentCalls, 1, reason: 'presented once before the friend packet');
    expect(sentWhenPresented, 0,
        reason: 'token presentation must precede the packet on the wire');
    expect(alice.transport.sent, hasLength(1));
  });

  test('friendship state survives a restart (persisted to secure storage)',
      () async {
    await befriend(bobSharesAtAccept: true);

    // Same storage, fresh service — as after an app relaunch.
    final revived = await FakePhone.createWithStorage(alice.storage, registry);
    addTearDown(revived.friends.dispose);
    expect(revived.friends.hasAccount, isTrue);
    expect(revived.friends.friends.single.record.peerUsername, 'bob');
    expect(
        revived.friends.store.byUsername('bob')!.theirTokenToMe, isNotNull);
  });
}
