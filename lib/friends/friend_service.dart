import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/capability_token.dart';
import '../core/friend_wire.dart';
import '../core/message.dart';
import '../core/message_factory.dart';
import '../core/pipeline.dart';
import '../debug/debug_log.dart' as dbg;
import '../identity/device_identity.dart';
import '../identity/encryption_identity.dart';
import '../transport/transport.dart';
import 'directory_client.dart';
import 'friend_state.dart';
import 'friend_store.dart';

/// How often the LOCATION beacon goes to the node while at least one friend
/// share is active. Matches the node's 120 s telemetry cadence. The beacon
/// runs ONLY while sharing — location sharing is opt-in; the (separate,
/// unsigned) MLPP1 telemetry pong keeps serving node ops regardless.
const Duration beaconInterval = Duration(minutes: 2);

/// Minimum spacing between LOCATION_QUERYs per friend — matches the node's
/// per-(requester, target) rate limit; the map screen shows last-known
/// between polls.
const Duration queryMinInterval = Duration(seconds: 60);

/// Re-mint my capability tokens when they are within this window of expiry
/// (checked hourly) so sharing survives the 24 h default expiry unattended.
const Duration tokenRefreshMargin = Duration(hours: 2);

typedef PositionReader = Future<({double lat, double lon, double accuracyM})?>
    Function();

/// Orchestrates the four friendship flows over the mesh: request/accept
/// (mutual consent), per-friend location sharing (capability tokens), and
/// friend-location queries. Pure protocol logic lives in the core ports
/// (friend_state / capability_token / friend_wire); this class does I/O and
/// persistence and notifies the UI.
class FriendService extends ChangeNotifier {
  FriendService({
    required this.store,
    required this.directory,
    required this.identity,
    required this.encryption,
    required this.transport,
    required this.pipeline,
    required PositionReader readPosition,
    DateTime Function()? now,
    // ignore: prefer_initializing_formals — private field, public param name
  })  : _readPosition = readPosition,
        _now = now ?? DateTime.now {
    final rng = Random.secure();
    _ephemId = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  }

  final FriendStore store;
  final DirectoryClient directory;
  final DeviceIdentity identity;
  final EncryptionIdentity encryption;
  final Transport transport;
  final RelayPipeline pipeline;
  final PositionReader _readPosition;
  final DateTime Function() _now;

  /// Present our attestation token to any not-yet-presented peer before we
  /// send friend/location traffic. An attestation-gated node drops this
  /// device's packets (pipeline step 7) until it has cached our token, and the
  /// friend path — a location poll, a beacon, a friend request — is often the
  /// first traffic a phone sends through a node, before any chat message ever
  /// triggers presentation. Wired by [ChatScreen], which owns the token and
  /// the per-peer presented-set; left null in tests (the loopback mesh has no
  /// attestation-gated node).
  Future<void> Function()? presentAttestation;

  late final Uint8List _ephemId;
  Timer? _beaconTimer;
  Timer? _refreshTimer;
  final Map<String, DateTime> _lastQueryAt = {};
  final Map<String, Completer<LocationResponsePayload?>> _pendingQueries = {};

  Uint8List get _myHint => pubkeyId(identity.publicKey);

  // ---- lifecycle ----

  Future<void> init() async {
    await store.load();
    _syncBeaconLoop();
    _refreshTimer =
        Timer.periodic(const Duration(hours: 1), (_) => _refreshTokens());
  }

  @override
  void dispose() {
    _beaconTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  // ---- flow 1: account (username registration) ----

  bool get hasAccount => store.ownUsername != null;

  /// Direct directory registration (POST /account) — used by the test harness
  /// and any directory-only path. The production flow goes through
  /// /auth/signup instead and calls [bindAccount].
  Future<void> createAccount(String username) async {
    await directory.createAccount(
      username: username,
      curve25519Pub: encryption.publicKey,
      ed25519Pub: identity.publicKey,
    );
    await store.setOwnUsername(username);
    notifyListeners();
  }

  /// Record the account's mesh handle after auth. The directory row was
  /// already created by POST /auth/signup, so this only sets the local
  /// username — it must NOT re-POST /account (that would 409 on the taken
  /// name). Login rebinds the device keys server-side.
  Future<void> bindAccount(String username) async {
    await store.setOwnUsername(username);
    notifyListeners();
  }

  // ---- flow 2: friend request / accept (mutual consent) ----

  /// "Add friend": resolve the username, pin their keys locally (TOFU — a
  /// later directory answer never overwrites what we pinned), send
  /// FRIEND_REQUEST encrypted to them.
  Future<void> sendFriendRequest(String username) async {
    final existing = store.byUsername(username);
    if (existing != null && existing.record.state != FriendshipState.none) {
      throw DirectoryException('Already have a "$username" entry');
    }
    final resolved = await directory.resolve(username);
    final record = FriendshipRecord(
      peerUsername: resolved.username,
      peerCurve25519Pub: resolved.curve25519Pub,
      peerEd25519Pub: resolved.ed25519Pub,
    );
    final (next, effects) = transition(record, FriendEvent.sendRequest);
    assert(effects.contains(FriendEffect.emitFriendRequest));
    final payload = await encodeFriendRequest(
      FriendRequestPayload(
          store.ownUsername!, encryption.publicKey, identity.publicKey),
      pubkeyId(resolved.ed25519Pub),
      resolved.curve25519Pub,
    );
    await _sendToPeers(msgTypeFriendRequest, payload);
    await store.put(FriendEntry(record: next));
    notifyListeners();
  }

  /// Inbound requests awaiting our explicit consent. Never auto-accepted.
  List<FriendEntry> get pendingRequests => [
        for (final e in store.entries)
          if (e.record.state == FriendshipState.pending) e
      ];

  List<FriendEntry> get friends => [
        for (final e in store.entries)
          if (e.record.state == FriendshipState.friends) e
      ];

  /// Accept an inbound request. [shareLocation] optionally enables sharing at
  /// accept time, embedding the initial capability token in the accept.
  Future<void> accept(String username, {bool shareLocation = false}) async {
    final entry = store.byUsername(username);
    if (entry == null) throw StateError('no request from $username');
    var (record, effects) = transition(entry.record, FriendEvent.accept);
    assert(effects.contains(FriendEffect.emitFriendAccept));

    Uint8List? token;
    if (shareLocation) {
      final (r2, e2) = transition(record, FriendEvent.enableLocation);
      record = r2;
      assert(e2.contains(FriendEffect.issueCapabilityToken));
      token = await _mintToken(record);
    }
    final payload = await encodeFriendAccept(
      FriendAcceptPayload(
          store.ownUsername!, encryption.publicKey, identity.publicKey, token),
      pubkeyId(record.peerEd25519Pub),
      record.peerCurve25519Pub,
    );
    await _sendToPeers(msgTypeFriendAccept, payload);
    entry.record = record;
    entry.myTokenToThem = token;
    entry.pendingRequestMsgId = null;
    await store.put(entry);
    _syncBeaconLoop();
    unawaited(_mirror(record));
    notifyListeners();
  }

  Future<void> decline(String username) async {
    final entry = store.byUsername(username);
    if (entry == null) throw StateError('no request from $username');
    final (record, effects) = transition(entry.record, FriendEvent.decline);
    assert(effects.contains(FriendEffect.emitFriendDecline));
    final msgId = entry.pendingRequestMsgId ?? Uint8List(16);
    await _sendToPeers(msgTypeFriendDecline,
        encodeFriendDecline(msgId, pubkeyId(entry.record.peerEd25519Pub)));
    entry.record = record;
    entry.pendingRequestMsgId = null;
    await store.put(entry);
    notifyListeners();
  }

  // ---- flow 3: per-friend location sharing toggle ----

  /// Enable "Share my location with {friend}": mint a capability token signed
  /// with OUR long-term Ed25519 key and deliver it via a FRIEND_ACCEPT
  /// follow-up (the token-refresh edge). Auto-refreshed hourly while on.
  Future<void> enableLocationSharing(String username) async {
    final entry = store.byUsername(username);
    if (entry == null) throw StateError('not friends with $username');
    final (record, effects) =
        transition(entry.record, FriendEvent.enableLocation);
    assert(effects.contains(FriendEffect.issueCapabilityToken));
    entry.record = record;
    entry.myTokenToThem = await _mintToken(record);
    await _deliverToken(entry);
    await store.put(entry);
    _syncBeaconLoop();
    unawaited(_mirror(record));
    notifyListeners();
  }

  /// Disable: send LOCATION_REVOKE (to the node's revocation set AND to the
  /// friend — the relay fans it out) and stop refreshing/beaconing.
  Future<void> disableLocationSharing(String username) async {
    final entry = store.byUsername(username);
    if (entry == null) throw StateError('not friends with $username');
    final (record, effects) =
        transition(entry.record, FriendEvent.disableLocation);
    final token = entry.myTokenToThem;
    if (effects.contains(FriendEffect.emitLocationRevoke) && token != null) {
      final parsed = parseToken(token);
      await _sendToPeers(
          msgTypeLocationRevoke,
          encodeLocationRevoke(
            issuerPubkeyId: parsed.issuerPubkeyId,
            granteePubkeyId: parsed.granteePubkeyId,
            issuedAt: parsed.issuedAt,
            nonce: parsed.nonce,
          ));
    }
    entry.record = record;
    entry.myTokenToThem = null;
    await store.put(entry);
    _syncBeaconLoop();
    unawaited(_mirror(record));
    notifyListeners();
  }

  // ---- flow 5: direct messages ----

  /// Send [text] to a friend, sealed to their pinned X25519 key. Best-effort
  /// like all mesh traffic (spray-and-wait, no delivery receipt); the local
  /// copy is appended to the conversation immediately with [DmStatus.sending],
  /// then flipped to [DmStatus.relayed] once at least one peer took the
  /// packet ([DmStatus.failed] when no peer was reachable).
  Future<void> sendDirectMessage(String username, String text) async {
    final entry = store.byUsername(username);
    if (entry == null || entry.record.state != FriendshipState.friends) {
      throw StateError('not friends with $username');
    }
    final payload = await encodeDirectMessage(
      text,
      pubkeyId(entry.record.peerEd25519Pub),
      entry.record.peerCurve25519Pub,
    );
    final message = DirectMessage(
        text: text, outgoing: true, at: _now(), status: DmStatus.sending);
    entry.addMessage(message);
    notifyListeners();
    final reached = await _sendToPeers(msgTypeDirectMessage, payload);
    message.status = reached > 0 ? DmStatus.relayed : DmStatus.failed;
    await store.put(entry);
    notifyListeners();
  }

  // ---- flow 4: see a friend's location ----

  /// Query the node for [username]'s last-known coordinate using the
  /// capability token they granted us. Returns null — indistinguishably —
  /// when never granted, revoked, expired, rate-limited, or unknown: the UI
  /// shows "Location not available" for all of them, matching the node's
  /// non-leaking refusals.
  Future<LocationResponsePayload?> queryFriendLocation(String username) async {
    final entry = store.byUsername(username);
    final token = entry?.theirTokenToMe;
    if (entry == null || token == null) return null;

    final last = _lastQueryAt[username];
    if (last != null && _now().difference(last) < queryMinInterval) {
      return null; // respect the node's rate limit; UI keeps last-known
    }
    _lastQueryAt[username] = _now();

    final completer = Completer<LocationResponsePayload?>();
    _pendingQueries[username] = completer;
    await _sendToPeers(msgTypeLocationQuery, encodeLocationQuery(token));

    // A refused query is a silent drop node-side — timeout means unavailable.
    final result = await completer.future
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    _pendingQueries.remove(username);
    return result;
  }

  // ---- inbound demux (fed by the chat screen's single pipeline) ----

  /// Handle a pipeline-DELIVERed message. Returns true when consumed (it was
  /// friendship/location traffic addressed to us); false to let the caller
  /// treat it as ordinary chat.
  Future<bool> handleMessage(Message msg) async {
    switch (msg.msgType) {
      case msgTypeFriendRequest:
        return _onFriendRequest(msg);
      case msgTypeFriendAccept:
        return _onFriendAccept(msg);
      case msgTypeFriendDecline:
        return _onFriendDecline(msg);
      case msgTypeLocationResponse:
        return _onLocationResponse(msg);
      case msgTypeLocationRevoke:
        return _onLocationRevoke(msg);
      case msgTypeDirectMessage:
        return _onDirectMessage(msg);
      case msgTypeLocationQuery:
      case msgTypeLocation:
        return true; // node-terminated types; nothing for a phone to do
      default:
        return false;
    }
  }

  bool _isForMe(Message msg) {
    try {
      return _hex(recipientHintOf(msg.payload)) == _hex(_myHint);
    } on FormatException {
      return false;
    }
  }

  Future<bool> _onFriendRequest(Message msg) async {
    if (!_isForMe(msg)) return true; // someone else's mail; already relayed
    final FriendRequestPayload payload;
    try {
      payload = await decodeFriendRequest(msg.payload, encryption.keyPair);
    } catch (e) {
      _log('undecodable FRIEND_REQUEST: $e');
      return true;
    }
    // The sender must be the identity it claims: envelope sender_key was
    // Ed25519-verified at pipeline step 6 and must match the payload keys.
    if (_hex(payload.ed25519Pub) != _hex(msg.senderKey)) {
      _log('FRIEND_REQUEST sender/payload key mismatch — dropped');
      return true;
    }
    final existing = store.byUsername(payload.username);
    final record = existing?.record ??
        FriendshipRecord(
          peerUsername: payload.username,
          peerCurve25519Pub: payload.curve25519Pub, // TOFU pin
          peerEd25519Pub: payload.ed25519Pub,
        );
    final (next, _) = _tryTransition(record, FriendEvent.recvRequest);
    if (next == null) return true; // duplicate/out-of-order request
    await store.put(FriendEntry(
      record: next,
      theirTokenToMe: existing?.theirTokenToMe,
      pendingRequestMsgId: Uint8List.fromList(msg.msgId),
    ));
    notifyListeners();
    return true;
  }

  Future<bool> _onFriendAccept(Message msg) async {
    if (!_isForMe(msg)) return true;
    final FriendAcceptPayload payload;
    try {
      payload = await decodeFriendAccept(msg.payload, encryption.keyPair);
    } catch (e) {
      _log('undecodable FRIEND_ACCEPT: $e');
      return true;
    }
    if (_hex(payload.ed25519Pub) != _hex(msg.senderKey)) {
      _log('FRIEND_ACCEPT sender/payload key mismatch — dropped');
      return true;
    }
    final entry = store.byUsername(payload.username);
    if (entry == null) return true; // accept for a request we never sent
    // TOFU: keys were pinned when we sent the request; a mismatching accept
    // is an impersonation attempt, not a key update.
    if (_hex(entry.record.peerEd25519Pub) != _hex(payload.ed25519Pub)) {
      _log('FRIEND_ACCEPT key differs from pinned — dropped');
      return true;
    }
    final (next, _) = _tryTransition(entry.record, FriendEvent.recvAccept);
    if (next == null) return true;
    entry.record = next;
    if (payload.capabilityToken != null) {
      // Their grant to us — initial share-at-accept or a refresh.
      entry.theirTokenToMe = payload.capabilityToken;
    }
    await store.put(entry);
    unawaited(_mirror(next));
    notifyListeners();
    return true;
  }

  Future<bool> _onFriendDecline(Message msg) async {
    if (!_isForMe(msg)) return true;
    final entry = store.byEd25519Pub(Uint8List.fromList(msg.senderKey));
    if (entry == null) return true;
    final (next, _) = _tryTransition(entry.record, FriendEvent.recvDecline);
    if (next == null) return true;
    entry.record = next;
    await store.put(entry);
    notifyListeners();
    return true;
  }

  Future<bool> _onDirectMessage(Message msg) async {
    if (!_isForMe(msg)) return true; // someone else's mail; already relayed
    // Mutual consent gates messaging too: the envelope sender (Ed25519-
    // verified at pipeline step 6) must be a pinned friend in FRIENDS state.
    // Anything else — stranger, declined, unfriended — is a silent drop.
    final entry = store.byEd25519Pub(Uint8List.fromList(msg.senderKey));
    if (entry == null || entry.record.state != FriendshipState.friends) {
      _log('DIRECT_MESSAGE from non-friend — dropped');
      return true;
    }
    final String text;
    try {
      text = await decodeDirectMessage(msg.payload, encryption.keyPair);
    } catch (e) {
      _log('undecodable DIRECT_MESSAGE: $e');
      return true;
    }
    entry.addMessage(DirectMessage(text: text, outgoing: false, at: _now()));
    await store.put(entry);
    notifyListeners();
    return true;
  }

  Future<bool> _onLocationResponse(Message msg) async {
    if (!_isForMe(msg)) return true;
    final LocationResponsePayload payload;
    try {
      payload = await decodeLocationResponse(msg.payload, encryption.keyPair);
    } catch (e) {
      _log('undecodable LOCATION_RESPONSE: $e');
      return true;
    }
    // Resolve which pending query this answers; with one outstanding query
    // per friend the earliest pending completer wins.
    for (final entry in _pendingQueries.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(payload);
        break;
      }
    }
    return true;
  }

  Future<bool> _onLocationRevoke(Message msg) async {
    // The friend stopped sharing with us: envelope sender must be the friend
    // (and the token issuer). Drop our stored grant so the map stops asking.
    final entry = store.byEd25519Pub(Uint8List.fromList(msg.senderKey));
    if (entry == null) return true;
    final (next, effects) =
        _tryTransition(entry.record, FriendEvent.recvRevoke);
    if (next == null) return true;
    if (effects!.contains(FriendEffect.peerStoppedSharing)) {
      entry.theirTokenToMe = null;
      await store.put(entry);
      notifyListeners();
    }
    return true;
  }

  // ---- internals ----

  (FriendshipRecord?, List<FriendEffect>?) _tryTransition(
      FriendshipRecord record, FriendEvent event) {
    try {
      final (next, effects) = transition(record, event);
      return (next, effects);
    } on InvalidTransition catch (e) {
      _log('ignored: $e');
      return (null, null);
    }
  }

  Future<Uint8List> _mintToken(FriendshipRecord record) => issueToken(
        issuerKeyPair: identity.keyPair,
        issuerPub: identity.publicKey,
        granteeEd25519Pub: record.peerEd25519Pub,
      );

  Future<void> _deliverToken(FriendEntry entry) async {
    final payload = await encodeFriendAccept(
      FriendAcceptPayload(store.ownUsername!, encryption.publicKey,
          identity.publicKey, entry.myTokenToThem),
      pubkeyId(entry.record.peerEd25519Pub),
      entry.record.peerCurve25519Pub,
    );
    await _sendToPeers(msgTypeFriendAccept, payload);
  }

  /// Hourly: re-mint any of my tokens inside the refresh margin and
  /// re-deliver them, so sharing stays alive across the 24 h expiry.
  Future<void> _refreshTokens() async {
    final nowS = _now().millisecondsSinceEpoch ~/ 1000;
    for (final entry in store.entries) {
      final token = entry.myTokenToThem;
      if (!entry.record.locationSharingEnabled || token == null) continue;
      if (parseToken(token).expiresAt - nowS > tokenRefreshMargin.inSeconds) {
        continue;
      }
      entry.myTokenToThem = await _mintToken(entry.record);
      await _deliverToken(entry);
      await store.put(entry);
    }
  }

  /// The 120 s LOCATION beacon runs only while at least one share is active
  /// — sharing is opt-in, and no share means the node has nothing of ours to
  /// serve (or retain).
  void _syncBeaconLoop() {
    final anySharing =
        store.entries.any((e) => e.record.locationSharingEnabled);
    if (anySharing && _beaconTimer == null) {
      _beaconTimer = Timer.periodic(beaconInterval, (_) => sendBeacon());
      unawaited(sendBeacon());
    } else if (!anySharing) {
      _beaconTimer?.cancel();
      _beaconTimer = null;
    }
  }

  @visibleForTesting
  Future<void> sendBeacon() async {
    final position = await _readPosition();
    if (position == null) return;
    await _sendToPeers(
      msgTypeLocation,
      encodeLocationBeacon(
        (position.lat * 1e6).round(),
        (position.lon * 1e6).round(),
        position.accuracyM.round().clamp(0, 0xFFFF),
      ),
    );
  }

  /// Returns how many peers actually took the packet (0 = not transmitted).
  Future<int> _sendToPeers(int msgType, Uint8List payload) async {
    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: _ephemId,
      payload: payload,
      msgType: msgType,
      zoneId: broadcastZone,
    );
    // Outgoing obeys the same pipeline as incoming (seeds dedup so our own
    // echo isn't re-processed) — same rule as the chat send path.
    final result = await pipeline.process(packet);
    if (result.outcome != Outcome.deliver) {
      _log('not sent (own pipeline): ${result.dropReason}');
      return 0;
    }
    // Make sure the node has our attestation token before this packet — the
    // friend/location path can be the first thing we send through a node, and
    // step 7 drops us as unattested otherwise (a silent "location not
    // available"). No-op once presented, and null in tests.
    await presentAttestation?.call();
    var reached = 0;
    for (final peer in transport.listPeers()) {
      try {
        await transport.send(peer, packet);
        reached++;
      } catch (_) {
        // Peer vanished mid-send; dedup makes retries safe.
      }
    }
    return reached;
  }

  Future<void> _mirror(FriendshipRecord record) async {
    final me = store.ownUsername;
    if (me == null) return;
    await directory.mirrorFriendship(
      userA: me,
      userB: record.peerUsername,
      state: record.state.name,
      aSharesLoc: record.locationSharingEnabled,
      bSharesLoc: store.byUsername(record.peerUsername)?.theirTokenToMe != null,
    );
  }

  void _log(String message) =>
      dbg.DebugLog.instance.log('friends', message);
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
