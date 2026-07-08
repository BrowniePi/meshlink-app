import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/friends/friend_state.dart';

FriendshipRecord _record(FriendshipState state, {bool sharing = false}) =>
    FriendshipRecord(
      peerUsername: 'peer',
      peerCurve25519Pub: Uint8List(32),
      peerEd25519Pub: Uint8List(32),
      state: state,
      locationSharingEnabled: sharing,
    );

/// Mirror of meshlink-core tests/test_friend_state.py LEGAL_EDGES: the two
/// transition tables must stay identical (the parity is by-table, not
/// by-wire, since the machine is pure logic).
const legalEdges = [
  (FriendshipState.none, FriendEvent.sendRequest, FriendshipState.requested),
  (FriendshipState.none, FriendEvent.recvRequest, FriendshipState.pending),
  (FriendshipState.requested, FriendEvent.recvRequest, FriendshipState.pending),
  (FriendshipState.requested, FriendEvent.recvAccept, FriendshipState.friends),
  (FriendshipState.requested, FriendEvent.recvDecline, FriendshipState.none),
  (FriendshipState.pending, FriendEvent.accept, FriendshipState.friends),
  (FriendshipState.pending, FriendEvent.decline, FriendshipState.none),
  (FriendshipState.friends, FriendEvent.recvAccept, FriendshipState.friends),
  (FriendshipState.friends, FriendEvent.enableLocation, FriendshipState.friends),
  (FriendshipState.friends, FriendEvent.disableLocation, FriendshipState.friends),
  (FriendshipState.friends, FriendEvent.recvRevoke, FriendshipState.friends),
  (FriendshipState.friends, FriendEvent.unfriend, FriendshipState.revoked),
];

void main() {
  test('every legal edge lands in its documented state', () {
    for (final (from, event, to) in legalEdges) {
      final (next, _) = transition(_record(from), event);
      expect(next.state, to, reason: '${from.name} --${event.name}-->');
    }
  });

  test('every edge NOT in the table throws InvalidTransition', () {
    // Invariant 1 support: no replayed/out-of-order message can move the
    // machine along an edge that wasn't explicitly designed.
    final legal = {
      for (final (from, event, _) in legalEdges) '${from.name}/${event.name}'
    };
    for (final state in FriendshipState.values) {
      for (final event in FriendEvent.values) {
        if (legal.contains('${state.name}/${event.name}')) continue;
        expect(
          () => transition(_record(state), event),
          throwsA(isA<InvalidTransition>()),
          reason: 'expected ${state.name} --${event.name}--> to be illegal',
        );
      }
    }
  });

  test('becoming friends never auto-enables location sharing', () {
    // Consent invariant: friendship consent and location consent are
    // separate; every path into FRIENDS keeps the sharing flag false.
    final (viaAccept, _) =
        transition(_record(FriendshipState.pending), FriendEvent.accept);
    expect(viaAccept.locationSharingEnabled, isFalse);
    final (viaRecv, _) =
        transition(_record(FriendshipState.requested), FriendEvent.recvAccept);
    expect(viaRecv.locationSharingEnabled, isFalse);
  });

  test('recvRequest never auto-accepts', () {
    final (next, effects) =
        transition(_record(FriendshipState.none), FriendEvent.recvRequest);
    expect(next.state, FriendshipState.pending);
    expect(effects, isNot(contains(FriendEffect.emitFriendAccept)));
  });

  test('enableLocation issues a token; disable emits a revoke', () {
    final (on, onEffects) =
        transition(_record(FriendshipState.friends), FriendEvent.enableLocation);
    expect(on.locationSharingEnabled, isTrue);
    expect(onEffects, contains(FriendEffect.issueCapabilityToken));

    final (off, offEffects) = transition(
        _record(FriendshipState.friends, sharing: true),
        FriendEvent.disableLocation);
    expect(off.locationSharingEnabled, isFalse);
    expect(offEffects, contains(FriendEffect.emitLocationRevoke));
  });

  test('recvAccept while friends is idempotent (token refresh path)', () {
    final before = _record(FriendshipState.friends, sharing: true);
    final (after, effects) = transition(before, FriendEvent.recvAccept);
    expect(after.state, FriendshipState.friends);
    expect(after.locationSharingEnabled, isTrue);
    expect(effects, isEmpty);
  });

  test('unfriend while sharing revokes the grant', () {
    final (next, effects) = transition(
        _record(FriendshipState.friends, sharing: true), FriendEvent.unfriend);
    expect(next.state, FriendshipState.revoked);
    expect(next.locationSharingEnabled, isFalse);
    expect(effects, contains(FriendEffect.emitLocationRevoke));
  });
}
