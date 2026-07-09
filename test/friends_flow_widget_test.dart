import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/core/friend_wire.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/friends/directory_client.dart';
import 'package:meshlink_app/friends/friend_service.dart';
import 'package:meshlink_app/friends/friend_state.dart';
import 'package:meshlink_app/friends/friend_store.dart';
import 'package:meshlink_app/identity/device_identity.dart';
import 'package:meshlink_app/identity/encryption_identity.dart';
import 'package:meshlink_app/onboarding/account_screen.dart';
import 'package:meshlink_app/ui/direct_message_screen.dart';
import 'package:meshlink_app/ui/friend_map_screen.dart';
import 'package:meshlink_app/ui/friends_screen.dart';

import 'helpers/friend_fakes.dart';

/// A FriendService whose location query is canned — the map screen contract
/// (poll, show age, "Location not available") is UI behaviour, not protocol.
class _StubFriends extends FriendService {
  _StubFriends({
    required super.store,
    required super.directory,
    required super.identity,
    required super.encryption,
    required super.transport,
    required super.pipeline,
    required super.readPosition,
  });

  LocationResponsePayload? response;

  @override
  Future<LocationResponsePayload?> queryFriendLocation(String username) async =>
      response;
}

void main() {
  // Widget tests for the four user-facing flows. Everything below the UI is
  // real (state machine, wire codecs, crypto) except radio, backend, and GPS.
  late Map<String, Map<String, String>> registry;
  late FakePhone me;
  late FakePhone peer; // supplies genuine keys for seeded friend entries

  setUp(() async {
    registry = {};
    // init: false — no FriendService timers; widget tests fail on timers
    // still pending when the body ends.
    me = await FakePhone.create(registry, init: false);
    peer = await FakePhone.create(registry, init: false);
    await peer.friends.createAccount('alice');
  });

  tearDown(() {
    me.friends.dispose();
    peer.friends.dispose();
  });

  Future<FriendEntry> seedEntry(FriendshipState state) async {
    await me.friends.createAccount('bob');
    final entry = FriendEntry(
      record: FriendshipRecord(
        peerUsername: 'alice',
        peerCurve25519Pub: peer.friends.encryption.publicKey,
        peerEd25519Pub: peer.friends.identity.publicKey,
        state: state,
      ),
    );
    await me.friends.store.put(entry);
    return entry;
  }

  group('flow 1 — create account', () {
    testWidgets('registers the username and moves on', (tester) async {
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: AccountScreen(friends: me.friends, onDone: () => done = true),
      ));
      await tester.enterText(find.byType(TextField), 'bob');
      await tester.tap(find.text('Create account'));
      // pump, not pumpAndSettle: the button's progress spinner animates
      // indefinitely while the screen stays mounted after onDone.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(done, isTrue);
      expect(registry.containsKey('bob'), isTrue);
      expect(me.friends.hasAccount, isTrue);
    });

    testWidgets('a taken username shows an inline error, no navigation',
        (tester) async {
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: AccountScreen(friends: me.friends, onDone: () => done = true),
      ));
      await tester.enterText(find.byType(TextField), 'alice'); // peer's name
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(done, isFalse);
      expect(find.text('That username is taken'), findsOneWidget);
    });
  });

  group('flow 2 — friend request / accept (mutual consent)', () {
    testWidgets('an inbound request needs an explicit Accept', (tester) async {
      await seedEntry(FriendshipState.pending);
      await tester.pumpWidget(
          MaterialApp(home: FriendsScreen(friends: me.friends)));
      await tester.pump();

      expect(find.text('wants to be friends'), findsOneWidget);
      await tester.tap(find.byTooltip('Accept'));
      await tester.pumpAndSettle();
      // Accept-time location opt-in is a separate question.
      expect(find.text('Accept + share location'), findsOneWidget);
      await tester.tap(find.text('Accept')); // accept WITHOUT sharing
      await tester.pumpAndSettle();

      final record = me.friends.store.byUsername('alice')!.record;
      expect(record.state, FriendshipState.friends);
      expect(record.locationSharingEnabled, isFalse,
          reason: 'accepting friendship never auto-shares location');
    });

    testWidgets('Decline drops the request', (tester) async {
      await seedEntry(FriendshipState.pending);
      await tester.pumpWidget(
          MaterialApp(home: FriendsScreen(friends: me.friends)));
      await tester.pump();

      await tester.tap(find.byTooltip('Decline'));
      await tester.pumpAndSettle();
      expect(find.text('wants to be friends'), findsNothing);
      expect(me.friends.store.byUsername('alice')!.record.state,
          FriendshipState.none);
    });
  });

  group('flow 3 — per-friend location sharing toggle', () {
    testWidgets('the switch mints a grant on, revokes it off', (tester) async {
      await seedEntry(FriendshipState.friends);
      await tester.pumpWidget(
          MaterialApp(home: FriendsScreen(friends: me.friends)));
      await tester.pump();

      expect(find.text('Share my location with alice'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      final entry = me.friends.store.byUsername('alice')!;
      expect(entry.record.locationSharingEnabled, isTrue);
      expect(entry.myTokenToThem, isNotNull);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(entry.record.locationSharingEnabled, isFalse);
      expect(entry.myTokenToThem, isNull);
    });
  });

  group('flow 4 — friend location on the map', () {
    Future<_StubFriends> stubService() async {
      final storage = InMemorySecureStorage();
      return _StubFriends(
        store: FriendStore(storage),
        directory: DirectoryClient(
          config: const BackendConfig(baseUrl: 'http://test', eventId: 't'),
          client: directoryMockClient(registry),
        ),
        identity: await DeviceIdentity.loadOrGenerate(storage),
        encryption: await EncryptionIdentity.loadOrGenerate(storage),
        transport: CapturingTransport(),
        pipeline: RelayPipeline(),
        readPosition: () async => null,
      );
    }

    testWidgets('shows the coordinate with its beacon age', (tester) async {
      final friends = await stubService();
      friends.response = LocationResponsePayload(
        latMicrodeg: 37774900,
        lonMicrodeg: -122419400,
        accuracyM: 12,
        beaconAgeS: 40,
        zoneId: 0xFFFF,
      );
      await tester.pumpWidget(MaterialApp(
          home: FriendMapScreen(friends: friends, username: 'alice')));
      await tester.pump();

      expect(find.textContaining('37.774900'), findsOneWidget);
      expect(find.textContaining('updated 40s ago'), findsOneWidget);
      expect(find.textContaining('±12 m'), findsOneWidget);

      await tester.pumpWidget(const SizedBox()); // dispose → cancel poll timer
      friends.dispose();
    });

    testWidgets('a refusal shows only "Location not available"',
        (tester) async {
      final friends = await stubService(); // response stays null
      await tester.pumpWidget(MaterialApp(
          home: FriendMapScreen(friends: friends, username: 'alice')));
      await tester.pump();

      // Denied, revoked, expired, and unknown all look like this — the UI
      // must not distinguish them (mirrors the node's silent refusals).
      expect(find.text('Location not available'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      friends.dispose();
    });
  });

  group('flow 5 — direct messages', () {
    testWidgets('sending renders an outgoing bubble; inbound appears live',
        (tester) async {
      await seedEntry(FriendshipState.friends);
      await tester.pumpWidget(MaterialApp(
        home: DirectMessageScreen(friends: me.friends, username: 'alice'),
      ));
      expect(find.textContaining('No messages yet'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'meet at gate B');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(find.text('meet at gate B'), findsOneWidget);

      // An inbound message lands via the service listener, no navigation.
      me.friends.store
          .byUsername('alice')!
          .addMessage(DirectMessage(
              text: 'on my way', outgoing: false, at: DateTime.now()));
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      me.friends.notifyListeners();
      await tester.pump();
      expect(find.text('on my way'), findsOneWidget);
    });
  });
}
