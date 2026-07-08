import 'dart:typed_data';

/// Pure friendship state machine — Dart mirror of
/// meshlink-core/friends/state.py; the transition table must stay identical
/// (test/friend_state_test.dart replays every edge).
///
/// Friendship is mutual-consent and is the master switch for DMs and
/// location. [FriendshipRecord.locationSharingEnabled] is a separate
/// per-friend flag: being friends never auto-shares location, and nothing in
/// this machine auto-accepts a request — consent is explicit both directions.
enum FriendshipState { none, requested, pending, friends, revoked }

enum FriendEvent {
  // Local user actions:
  sendRequest,
  accept,
  decline,
  enableLocation,
  disableLocation,
  unfriend,
  // Inbound messages from the peer:
  recvRequest,
  recvAccept,
  recvDecline,
  recvRevoke,
}

enum FriendEffect {
  emitFriendRequest,
  emitFriendAccept,
  emitFriendDecline,
  issueCapabilityToken,
  emitLocationRevoke,
  peerStoppedSharing,
}

class InvalidTransition implements Exception {
  InvalidTransition(this.state, this.event);
  final FriendshipState state;
  final FriendEvent event;
  @override
  String toString() =>
      'event ${event.name} is illegal in state ${state.name}';
}

class FriendshipRecord {
  const FriendshipRecord({
    required this.peerUsername,
    required this.peerCurve25519Pub,
    required this.peerEd25519Pub,
    this.state = FriendshipState.none,
    this.locationSharingEnabled = false,
    this.capabilityTokensIssued = const [],
  });

  final String peerUsername;
  final Uint8List peerCurve25519Pub;
  final Uint8List peerEd25519Pub;
  final FriendshipState state;

  /// *I* share my location with *them* — unilateral opt-in per friend.
  final bool locationSharingEnabled;
  final List<Uint8List> capabilityTokensIssued;

  FriendshipRecord copyWith({
    FriendshipState? state,
    bool? locationSharingEnabled,
    List<Uint8List>? capabilityTokensIssued,
  }) =>
      FriendshipRecord(
        peerUsername: peerUsername,
        peerCurve25519Pub: peerCurve25519Pub,
        peerEd25519Pub: peerEd25519Pub,
        state: state ?? this.state,
        locationSharingEnabled:
            locationSharingEnabled ?? this.locationSharingEnabled,
        capabilityTokensIssued:
            capabilityTokensIssued ?? this.capabilityTokensIssued,
      );
}

/// Apply one event; returns the new record and the side effects the caller
/// must perform. Throws [InvalidTransition] for every edge not explicitly
/// allowed — a replayed or out-of-order message cannot corrupt consent.
(FriendshipRecord, List<FriendEffect>) transition(
    FriendshipRecord record, FriendEvent event) {
  final s = record.state;

  if (event == FriendEvent.sendRequest && s == FriendshipState.none) {
    return (
      record.copyWith(state: FriendshipState.requested),
      [FriendEffect.emitFriendRequest],
    );
  }
  if (event == FriendEvent.recvRequest && s == FriendshipState.none) {
    return (record.copyWith(state: FriendshipState.pending), []);
  }
  // Simultaneous cross-request: surfaced for explicit accept, never auto.
  if (event == FriendEvent.recvRequest && s == FriendshipState.requested) {
    return (record.copyWith(state: FriendshipState.pending), []);
  }
  if (event == FriendEvent.recvAccept && s == FriendshipState.requested) {
    return (record.copyWith(state: FriendshipState.friends), []);
  }
  // Token refresh / duplicate accept while already friends: idempotent, the
  // caller just stores the embedded capability token if present.
  if (event == FriendEvent.recvAccept && s == FriendshipState.friends) {
    return (record, []);
  }
  if (event == FriendEvent.recvDecline && s == FriendshipState.requested) {
    return (record.copyWith(state: FriendshipState.none), []);
  }
  if (event == FriendEvent.accept && s == FriendshipState.pending) {
    return (
      record.copyWith(state: FriendshipState.friends),
      [FriendEffect.emitFriendAccept],
    );
  }
  if (event == FriendEvent.decline && s == FriendshipState.pending) {
    return (
      record.copyWith(state: FriendshipState.none),
      [FriendEffect.emitFriendDecline],
    );
  }
  if (event == FriendEvent.enableLocation && s == FriendshipState.friends) {
    return (
      record.copyWith(locationSharingEnabled: true),
      [FriendEffect.issueCapabilityToken],
    );
  }
  if (event == FriendEvent.disableLocation && s == FriendshipState.friends) {
    if (!record.locationSharingEnabled) return (record, []);
    return (
      record.copyWith(
          locationSharingEnabled: false, capabilityTokensIssued: const []),
      [FriendEffect.emitLocationRevoke],
    );
  }
  if (event == FriendEvent.recvRevoke && s == FriendshipState.friends) {
    return (record, [FriendEffect.peerStoppedSharing]);
  }
  if (event == FriendEvent.unfriend && s == FriendshipState.friends) {
    return (
      record.copyWith(
          state: FriendshipState.revoked,
          locationSharingEnabled: false,
          capabilityTokensIssued: const []),
      [if (record.locationSharingEnabled) FriendEffect.emitLocationRevoke],
    );
  }
  throw InvalidTransition(s, event);
}
