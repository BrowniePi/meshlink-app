import 'dart:async';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../core/capability_token.dart';
import '../core/friend_wire.dart';
import '../core/message.dart';
import '../core/message_factory.dart';
import '../core/pipeline.dart';
import '../debug/debug_log.dart' as dbg;
import '../identity/device_identity.dart';
import '../identity/encryption_identity.dart';
import '../online/online_client.dart';
import '../online/online_service.dart';
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

/// Minimum spacing between re-sends of an unanswered outbound FRIEND_REQUEST.
/// The mesh has no delivery receipt: a request sent while the other phone is
/// out of the cell reaches nobody and is simply gone, so it is re-sprayed
/// until they answer (accept/decline) instead of being fired once and lost.
const Duration requestResendInterval = Duration(minutes: 2);

typedef PositionReader = Future<({double lat, double lon, double accuracyM})?>
    Function();

/// Orchestrates the four friendship flows over the mesh AND the online
/// backend: request/accept (mutual consent), per-friend location sharing
/// (capability tokens offline, sealed blobs online), and friend-location
/// queries. Friend requests and DMs go out on BOTH transports at once when
/// the backend is reachable ([attachOnline]) — the receiving device may be
/// on the mesh but not online, or the reverse — and the receiver dedups the
/// second copy by ciphertext hash. Location reads are online-first with the
/// mesh as fallback. Pure protocol logic lives in the core ports
/// (friend_state / capability_token / friend_wire); this class does I/O and
/// persistence and notifies the UI.
class FriendService extends ChangeNotifier implements OnlineHandler {
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

  /// The online (backend) channel, attached post-construction like
  /// [presentAttestation] — null in mesh-only tests. While its socket is up,
  /// friend requests and DMs go out on it AND the mesh simultaneously (the
  /// receiver may be mesh-reachable but offline, or vice versa); location
  /// reads stay online-first with the mesh as fallback.
  OnlineService? _online;

  /// Fired after an inbound DM lands (either transport, post-dedup) — the
  /// notification hook. [dedupKey] is the ciphertext hash, the same key an
  /// FCM push for this message carries, so the notifier can de-duplicate.
  void Function(String fromUsername, String text, String dedupKey)?
      onDmReceived;

  /// Fired when an inbound friend request first appears (either transport).
  void Function(String fromUsername)? onFriendRequestReceived;

  /// Wire the online channel in and become its event handler. Connectivity
  /// flips are re-broadcast to our own listeners so the UI indicator updates
  /// through the one listener chain screens already have.
  void attachOnline(OnlineService online) {
    _online = online;
    online.handler = this;
    online.addListener(notifyListeners);
  }

  /// Whether the backend channel is usable right now (the mode indicator).
  bool get isOnline => _online?.connected ?? false;

  /// Authenticated REST can also travel through a connected node to the
  /// venue-local backend while the phone itself has no internet.
  bool get canReachBackend => _online?.canRequest ?? false;

  late final Uint8List _ephemId;
  Timer? _beaconTimer;
  Timer? _refreshTimer;
  final Map<String, DateTime> _lastQueryAt = {};
  final Map<String, Completer<LocationResponsePayload?>> _pendingQueries = {};

  /// When each unanswered outbound FRIEND_REQUEST was last sprayed, so the
  /// retry in [resendPendingRequests] respects [requestResendInterval].
  final Map<String, DateTime> _lastRequestSentAt = {};

  /// Freshest location answer seen per friend (keyed by username). With two
  /// possible answerers per query — the target phone (live fix) and a node
  /// (cached beacon) — a fresher answer can land after the query future
  /// already completed; it is recorded here and listeners are notified.
  final Map<String, LocationResponsePayload> lastKnownLocation = {};

  /// When each friend's [lastKnownLocation] fix was actually taken
  /// (arrival time minus beacon_age_s) — the freshest-wins comparison key.
  final Map<String, DateTime> _lastFixAt = {};

  /// Per-requester answer rate limit for queries about ME — same 60 s
  /// contract the node enforces per (requester, target).
  final Map<String, DateTime> _lastAnsweredAt = {};

  /// Most recent fix obtained on this device. Used for online sharing when a
  /// fresh GPS read temporarily fails; its original age is preserved.
  ({double lat, double lon, double accuracyM, DateTime at})? _lastOwnPosition;

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
    _online?.removeListener(notifyListeners);
    super.dispose();
  }

  /// Record the account's mesh handle after Supabase auth. The signup trigger
  /// already created the directory row; login rebinds this device's keys.
  Future<void> bindAccount(String username) async {
    await store.setOwnUsername(username);
    notifyListeners();
  }

  /// Clear friendship state belonging to the signed-out account. Device
  /// identities are deliberately owned elsewhere and survive logout.
  Future<void> clearAccountData() async {
    await store.clear();
    _lastQueryAt.clear();
    for (final query in _pendingQueries.values) {
      if (!query.isCompleted) query.complete(null);
    }
    _pendingQueries.clear();
    _lastRequestSentAt.clear();
    lastKnownLocation.clear();
    _lastFixAt.clear();
    _lastAnsweredAt.clear();
    _lastOwnPosition = null;
    _syncBeaconLoop();
    notifyListeners();
  }

  // ---- flow 2: friend request / accept (mutual consent) ----

  /// "Add friend": resolve the username, pin their keys locally (TOFU — a
  /// later directory answer never overwrites what we pinned), then deliver
  /// the request BOTH ways at once — to the backend (the server holds it
  /// until the friend sees it) and sprayed over the mesh (the friend may be
  /// in radio range but offline). The duplicate is harmless: the receiving
  /// state machine ignores a second recvRequest.
  ///
  /// Returns how many carriers took the request (peers + 1 for the
  /// backend). Zero is not a failure — the request stays in
  /// [FriendshipState.requested] and [resendPendingRequests] retries — but
  /// the caller should say so rather than claim it was delivered.
  Future<int> sendFriendRequest(String username) async {
    final existing = store.byUsername(username);
    if (existing != null) {
      if (existing.record.state == FriendshipState.requested) {
        var reached = 0;
        if (!existing.requestSentOnline || !canReachBackend) {
          if (await _sendRequestOnline(existing)) {
            await store.put(existing);
            reached = 1;
          }
        } else {
          reached = 1; // server already holds it
        }
        return reached + await _sprayRequest(existing.record);
      }
      if (existing.record.state == FriendshipState.friends) {
        throw DirectoryException('You are already friends with @$username');
      }
      if (existing.record.state == FriendshipState.pending) {
        throw DirectoryException('@$username already sent you a request');
      }
      if (existing.record.state == FriendshipState.revoked) {
        throw DirectoryException('Friendship with @$username was revoked');
      }
    }
    final resolved = await directory.resolve(username);
    final record = FriendshipRecord(
      peerUsername: resolved.username,
      peerCurve25519Pub: resolved.curve25519Pub,
      peerEd25519Pub: resolved.ed25519Pub,
    );
    final (next, effects) = transition(record, FriendEvent.sendRequest);
    assert(effects.contains(FriendEffect.emitFriendRequest));
    final entry = FriendEntry(record: next);
    var reached = 0;
    if (await _sendRequestOnline(entry)) {
      _lastRequestSentAt[next.peerUsername] = _now();
      reached = 1;
    }
    reached += await _sprayRequest(next);
    await store.put(entry);
    notifyListeners();
    return reached;
  }

  /// Deliver an outbound request to the backend. True on success (the
  /// server now holds it — no re-sends needed); false offline or on error.
  Future<bool> _sendRequestOnline(FriendEntry entry) async {
    final online = _online;
    if (online == null || !online.canRequest) return false;
    try {
      await online.client.sendFriendRequest(entry.record.peerUsername);
      entry.requestSentOnline = true;
      return true;
    } on OnlineException catch (e) {
      _log('online friend request failed ($e) — mesh fallback');
      return false;
    }
  }

  /// Retry any outbound request the peer has not answered yet. Called on
  /// the UI poll cycle. A request not yet delivered online is re-POSTed once
  /// we're online; the mesh re-spray keeps going regardless — the server
  /// holding the request only reaches a friend who comes online, not one in
  /// radio range, and the mesh has no delivery receipt either way.
  Future<void> resendPendingRequests() async {
    for (final entry in store.entries) {
      if (entry.record.state != FriendshipState.requested) continue;
      if (!entry.requestSentOnline && await _sendRequestOnline(entry)) {
        await store.put(entry);
      }
      final last = _lastRequestSentAt[entry.record.peerUsername];
      if (last != null && _now().difference(last) < requestResendInterval) {
        continue;
      }
      await _sprayRequest(entry.record);
    }
  }

  Future<int> _sprayRequest(FriendshipRecord record) async {
    final payload = await encodeFriendRequest(
      FriendRequestPayload(
          store.ownUsername!, encryption.publicKey, identity.publicKey),
      pubkeyId(record.peerEd25519Pub),
      record.peerCurve25519Pub,
    );
    _lastRequestSentAt[record.peerUsername] = _now();
    return _sendToPeers(msgTypeFriendRequest, payload);
  }

  /// Inbound requests awaiting our explicit consent. Never auto-accepted.
  List<FriendEntry> get receivedRequests => [
        for (final e in store.entries)
          if (e.record.state == FriendshipState.pending) e
      ];

  /// Outbound requests awaiting the other person's response.
  List<FriendEntry> get sentRequests => [
        for (final e in store.entries)
          if (e.record.state == FriendshipState.requested) e
      ];

  /// Backwards-compatible name used by request badges and older screens.
  List<FriendEntry> get pendingRequests => receivedRequests;

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
    // The mirror runs first so the server-side friendship row exists before
    // the online paths below (message relay requires it).
    await _mirror(record);
    final online = _online;
    if (online != null && online.canRequest) {
      try {
        await online.client.acceptFriendRequest(username);
      } on OnlineException catch (e) {
        // notFound = the request only ever existed on the mesh; fine.
        if (!e.notFound) _log('online accept failed: $e');
      }
      if (token != null) {
        // Deliver the capability token online too — the sealed accept
        // payload doubles as the relay body, so a friend we never meet on
        // the mesh can still be granted (their map falls back to the node
        // path whenever BOTH end up offline later).
        try {
          await online.client.sendRelay(username,
              Uint8List.fromList([msgTypeFriendAccept, ...payload]));
        } on OnlineException catch (e) {
          _log('online token delivery failed: $e');
        }
      }
      unawaited(_uploadLocationBlobs());
    }
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
    final online = _online;
    if (online != null && online.canRequest) {
      try {
        await online.client.declineFriendRequest(username);
      } on OnlineException catch (e) {
        if (!e.notFound) _log('online decline failed: $e');
      }
    }
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
    await store.put(entry);
    _syncBeaconLoop();
    notifyListeners();
    await _mirror(record);
    await _deliverToken(entry);
    await _uploadLocationBlobs();
  }

  /// Disable: send LOCATION_REVOKE (to the node's revocation set AND to the
  /// friend — the relay fans it out) and stop refreshing/beaconing.
  Future<void> disableLocationSharing(String username) async {
    final entry = store.byUsername(username);
    if (entry == null) throw StateError('not friends with $username');
    final (record, effects) =
        transition(entry.record, FriendEvent.disableLocation);
    final token = entry.myTokenToThem;
    Uint8List? revokePayload;
    if (effects.contains(FriendEffect.emitLocationRevoke) && token != null) {
      final parsed = parseToken(token);
      revokePayload = encodeLocationRevoke(
        issuerPubkeyId: parsed.issuerPubkeyId,
        granteePubkeyId: parsed.granteePubkeyId,
        issuedAt: parsed.issuedAt,
        nonce: parsed.nonce,
      );
    }
    entry.record = record;
    entry.myTokenToThem = null;
    await store.put(entry);
    _syncBeaconLoop();
    notifyListeners();
    await _mirror(record);
    if (revokePayload != null) {
      await _sendToPeers(msgTypeLocationRevoke, revokePayload);
      final online = _online;
      if (online != null && online.canRequest) {
        try {
          await online.client.sendRelay(username,
              Uint8List.fromList([msgTypeLocationRevoke, ...revokePayload]));
        } on OnlineException catch (e) {
          _log('online location revoke failed: $e');
        }
      }
    }
    // Re-upload without this friend — replacing the whole blob set IS the
    // online revoke.
    await _uploadLocationBlobs();
  }

  // ---- flow 5: direct messages ----

  /// Send [text] to a friend, sealed to their pinned X25519 key — once —
  /// then hand the SAME ciphertext to both transports at the same time: the
  /// backend stores it until the friend's next poll (it never sees the
  /// text), and the mesh sprays it in case the friend is in radio range but
  /// offline. Whichever copy lands second is dropped by the receiver's
  /// ciphertext-hash dedup ([FriendEntry.markDmSeen]). The local copy is
  /// appended immediately with [DmStatus.sending], then flipped to
  /// [DmStatus.relayed] once any carrier took it ([DmStatus.failed] when
  /// neither the backend nor any peer was reachable).
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
    final online = _online;
    var viaOnline = false;
    if (online != null && online.canRequest) {
      try {
        await online.client.sendRelay(username,
            Uint8List.fromList([msgTypeDirectMessage, ...payload]));
        viaOnline = true;
      } on OnlineException catch (e) {
        _log('online DM failed ($e) — mesh only');
      }
    }
    final viaMesh = await _sendToPeers(msgTypeDirectMessage, payload) > 0;
    message.via = viaOnline && viaMesh
        ? DmVia.both
        : viaOnline
            ? DmVia.online
            : DmVia.mesh;
    message.status =
        viaOnline || viaMesh ? DmStatus.relayed : DmStatus.failed;
    await store.put(entry);
    notifyListeners();
  }

  // ---- flow 4: see a friend's location ----

  /// Query [username]'s last-known coordinate. Online first: fetch the
  /// sealed blob they uploaded for us (its existence IS the consent — no
  /// capability token needed). Otherwise the mesh path: spray a
  /// LOCATION_QUERY carrying the token they granted us. Returns null —
  /// indistinguishably — when never granted, revoked, expired, rate-limited,
  /// or unknown: the UI shows "Location not available" for all of them,
  /// matching the node's non-leaking refusals.
  Future<LocationResponsePayload?> queryFriendLocation(String username) async {
    final entry = store.byUsername(username);
    if (entry == null) return null;

    final last = _lastQueryAt[username];
    if (last != null && _now().difference(last) < queryMinInterval) {
      return lastKnownLocation[username];
    }
    _lastQueryAt[username] = _now();

    final onlineResult = await _queryLocationOnline(entry);
    if (onlineResult != null) return onlineResult;

    final token = entry.theirTokenToMe;
    if (token == null) return lastKnownLocation[username];
    final completer = Completer<LocationResponsePayload?>();
    _pendingQueries[username] = completer;
    await _sendToPeers(msgTypeLocationQuery, encodeLocationQuery(token));

    // A refused query is a silent drop node-side — timeout means unavailable.
    final result = await completer.future
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    _pendingQueries.remove(username);
    return result ?? lastKnownLocation[username];
  }

  /// Fetch and open the sealed location blob [entry]'s friend uploaded for
  /// us. Null (silently) when offline, not shared, or undecodable — the
  /// caller falls through to the mesh path.
  Future<LocationResponsePayload?> _queryLocationOnline(
      FriendEntry entry) async {
    final online = _online;
    if (online == null || !online.canRequest) return null;
    final username = entry.record.peerUsername;
    try {
      final blob = await online.client.getLocationBlob(username);
      final payload =
          await decodeLocationResponse(blob.payload, encryption.keyPair);
      // The sealed body must name the friend we asked about (TOFU keys) —
      // the server cannot forge this without breaking the seal.
      if (_hex(payload.targetPubkeyId) !=
          _hex(pubkeyId(entry.record.peerEd25519Pub))) {
        _log('online location blob subject mismatch — dropped');
        return null;
      }
      // Staleness comes from the server's updated_at, not the sealed body
      // (the blob was fresh when uploaded).
      final serverAgeS = _now().difference(blob.updatedAt).inSeconds;
      final ageS = payload.beaconAgeS + (serverAgeS < 0 ? 0 : serverAgeS);
      final aged = LocationResponsePayload(
        targetPubkeyId: payload.targetPubkeyId,
        latMicrodeg: payload.latMicrodeg,
        lonMicrodeg: payload.lonMicrodeg,
        accuracyM: payload.accuracyM,
        beaconAgeS: ageS,
        zoneId: payload.zoneId,
      );
      _recordLocation(username, aged);
      return aged;
    } on OnlineException catch (e) {
      if (!e.notFound) _log('online location fetch failed: $e');
      return null;
    } on FormatException catch (e) {
      _log('undecodable online location blob: $e');
      return null;
    }
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
        return _onLocationQuery(msg);
      case msgTypeLocation:
        return true; // node-terminated beacon; nothing for a phone to do
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
    onFriendRequestReceived?.call(payload.username);
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
    final key = await _dmDedupKey(msgTypeDirectMessage, msg.payload);
    if (!entry.markDmSeen(key)) {
      _log('duplicate DM (already landed online) — dropped');
      return true;
    }
    entry.addMessage(DirectMessage(text: text, outgoing: false, at: _now()));
    await store.put(entry);
    notifyListeners();
    onDmReceived?.call(entry.record.peerUsername, text, key);
    return true;
  }

  /// A LOCATION_QUERY sprayed across the mesh reaches every phone; only the
  /// token's issuer — the friend being asked about — answers, with a live
  /// fix (beacon_age_s ≈ 0). Queries about anyone else are consumed here at
  /// the app layer (the transport-level spray relay forwards them onward).
  ///
  /// Refusals are silent and uniform, matching the node: a stranger, a
  /// stolen token, an expired grant, a disabled sharing switch, and a
  /// rate-limited poll all look identical to a prober — no response.
  Future<bool> _onLocationQuery(Message msg) async {
    final CapabilityToken token;
    try {
      token = parseToken(decodeLocationQuery(msg.payload));
    } on FormatException {
      return true;
    }
    if (_hex(token.issuerPubkeyId) != _hex(_myHint)) {
      return true; // about someone else — not ours to answer
    }
    // The envelope sender (Ed25519-verified at pipeline step 6) must BE the
    // grantee — a stolen token is useless without the grantee's key.
    final senderKey = Uint8List.fromList(msg.senderKey);
    if (_hex(token.granteePubkeyId) != _hex(pubkeyId(senderKey))) {
      return _refuseQuery('sender is not the grantee');
    }
    // Consent lives in the local switch, not just the token: sharing turned
    // off since the token was minted means no answer, even before expiry.
    final entry = store.byEd25519Pub(senderKey);
    if (entry == null || !entry.record.locationSharingEnabled) {
      return _refuseQuery('sharing not enabled for requester');
    }
    // Full verification: signed by OUR long-term key, grantee binding,
    // scope, time window — same pure check the node runs.
    final valid = await verifyToken(
        token.raw, identity.publicKey, senderKey,
        _now().millisecondsSinceEpoch ~/ 1000);
    if (!valid) return _refuseQuery('token verification failed');

    final requester = _hex(token.granteePubkeyId);
    final last = _lastAnsweredAt[requester];
    if (last != null && _now().difference(last) < queryMinInterval) {
      return _refuseQuery('answer rate limit');
    }
    _lastAnsweredAt[requester] = _now();

    final position = await _readPosition();
    if (position == null) {
      return _refuseQuery('no position available');
    }
    final payload = await encodeLocationResponse(
      LocationResponsePayload(
        targetPubkeyId: _myHint,
        latMicrodeg: (position.lat * 1e6).round(),
        lonMicrodeg: (position.lon * 1e6).round(),
        accuracyM: position.accuracyM.round().clamp(0, 0xFFFF),
        beaconAgeS: 0, // live fix, not a cached beacon
        zoneId: broadcastZone,
      ),
      pubkeyId(entry.record.peerEd25519Pub),
      entry.record.peerCurve25519Pub,
    );
    await _sendToPeers(msgTypeLocationResponse, payload);
    _log('answered location query from ${entry.record.peerUsername}');
    return true;
  }

  bool _refuseQuery(String reason) {
    // Uniform refusal: nothing is sent back, whatever the reason. The
    // reason exists only for the debug log (§8.3 — silent drop, log it).
    _log('location query refused: $reason');
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
    // The sealed body names its subject: resolve the friend whose pubkey_id
    // matches. Two answers can race for one query (target phone live,
    // node cached) — the first completes the pending future, and any
    // fresher one still lands in [lastKnownLocation].
    final entry = _entryByPubkeyId(payload.targetPubkeyId);
    if (entry == null) return true; // answer about nobody we know
    final username = entry.record.peerUsername;
    _recordLocation(username, payload);

    final pending = _pendingQueries[username];
    if (pending != null && !pending.isCompleted) pending.complete(payload);
    return true;
  }

  /// Freshest-wins location cache shared by every answer source — mesh
  /// responses (live phone or node cache) and online blobs alike.
  void _recordLocation(String username, LocationResponsePayload payload) {
    final fixAt = _now().subtract(Duration(seconds: payload.beaconAgeS));
    final priorFixAt = _lastFixAt[username];
    if (priorFixAt == null || fixAt.isAfter(priorFixAt)) {
      lastKnownLocation[username] = payload;
      _lastFixAt[username] = fixAt;
      notifyListeners();
    }
  }

  FriendEntry? _entryByPubkeyId(Uint8List id) {
    for (final entry in store.entries) {
      if (_hex(pubkeyId(entry.record.peerEd25519Pub)) == _hex(id)) {
        return entry;
      }
    }
    return null;
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
      await _forgetPeerLocation(entry);
    }
    return true;
  }

  Future<void> _forgetPeerLocation(FriendEntry entry) async {
    final username = entry.record.peerUsername;
    entry.theirTokenToMe = null;
    lastKnownLocation.remove(username);
    _lastFixAt.remove(username);
    await store.put(entry);
    notifyListeners();
  }

  // ---- inbound online path (fed by OnlineService) ----

  /// A store-and-forward relay body: [1-byte msgType][wire payload] — the
  /// exact sealed payloads the mesh carries, minus the signed envelope.
  /// Sender authenticity online is the account bearer token (the backend
  /// stamps `from_user`); content stays sealed to our X25519 key either way,
  /// and mutual consent still gates everything.
  @override
  Future<void> onOnlineRelay(String fromUser, Uint8List body) async {
    if (body.isEmpty) return;
    final payload = Uint8List.sublistView(body, 1);
    switch (body[0]) {
      case msgTypeDirectMessage:
        final entry = store.byUsername(fromUser);
        if (entry == null || entry.record.state != FriendshipState.friends) {
          _log('online DM from non-friend — dropped');
          return;
        }
        final String text;
        try {
          text = await decodeDirectMessage(payload, encryption.keyPair);
        } catch (e) {
          _log('undecodable online DM: $e');
          return;
        }
        final key = await _dmDedupKey(msgTypeDirectMessage, payload);
        if (!entry.markDmSeen(key)) {
          _log('duplicate DM (already landed via mesh) — dropped');
          return;
        }
        entry.addMessage(DirectMessage(
            text: text, outgoing: false, at: _now(), via: DmVia.online));
        await store.put(entry);
        notifyListeners();
        onDmReceived?.call(fromUser, text, key);
      case msgTypeFriendAccept:
        // Capability-token delivery/refresh (the sealed accept payload).
        final FriendAcceptPayload accept;
        try {
          accept = await decodeFriendAccept(payload, encryption.keyPair);
        } catch (e) {
          _log('undecodable online FRIEND_ACCEPT: $e');
          return;
        }
        final entry = store.byUsername(fromUser);
        if (entry == null) return;
        // TOFU: the sealed payload's keys must match what we pinned — a
        // mismatch is impersonation, never a key update (same rule as mesh).
        if (_hex(entry.record.peerEd25519Pub) != _hex(accept.ed25519Pub) ||
            accept.username != fromUser) {
          _log('online FRIEND_ACCEPT key/name differs from pinned — dropped');
          return;
        }
        final (next, _) = _tryTransition(entry.record, FriendEvent.recvAccept);
        if (next == null) return;
        entry.record = next;
        if (accept.capabilityToken != null) {
          entry.theirTokenToMe = accept.capabilityToken;
        }
        await store.put(entry);
        unawaited(_mirror(next));
        notifyListeners();
      case msgTypeLocationRevoke:
        final entry = store.byUsername(fromUser);
        if (entry == null || entry.record.state != FriendshipState.friends) {
          return;
        }
        await _forgetPeerLocation(entry);
      default:
        _log('online relay with unknown type ${body[0]} — dropped');
    }
  }

  /// Friend-request state may have changed server-side: sync the pending
  /// lists both ways. Runs on the push events and on every poll cycle.
  @override
  Future<void> onFriendEvent() async {
    final online = _online;
    final me = store.ownUsername;
    if (online == null || !online.canRequest || me == null) return;
    final PendingRequests pending;
    try {
      pending = await online.client.pendingFriendRequests();
    } on OnlineException catch (e) {
      _log('friend-request sync failed: $e');
      return;
    }

    // Inbound: surface new requests for explicit consent (never
    // auto-accepted), pinning keys from the directory (TOFU).
    for (final username in pending.incoming) {
      final existing = store.byUsername(username);
      if (existing != null &&
          existing.record.state != FriendshipState.none) {
        continue; // already tracked (perhaps it also arrived over the mesh)
      }
      final DirectoryEntry resolved;
      try {
        resolved = await directory.resolve(username);
      } on DirectoryException catch (e) {
        _log('cannot resolve online requester $username: $e');
        continue;
      }
      final record = FriendshipRecord(
        peerUsername: resolved.username,
        peerCurve25519Pub: resolved.curve25519Pub, // TOFU pin
        peerEd25519Pub: resolved.ed25519Pub,
      );
      final (next, _) = _tryTransition(record, FriendEvent.recvRequest);
      if (next == null) continue;
      await store.put(FriendEntry(record: next));
      notifyListeners();
      onFriendRequestReceived?.call(username);
    }

    // Supabase is the durable social graph. Reconcile every row on every
    // poll so a fresh install/login can recover friends and changes made by
    // another device do not leave stale local state behind.
    final Map<String, String> states;
    try {
      states = await online.client.friendshipStates(me);
    } on OnlineException catch (e) {
      _log('friendship-state sync failed: $e');
      return;
    }
    for (final state in states.entries) {
      await _applyOnlineFriendshipState(state.key, state.value);
    }
    final stale = [
      for (final entry in store.entries)
        if ((entry.record.state == FriendshipState.friends ||
                entry.record.state == FriendshipState.revoked) &&
            !states.containsKey(entry.record.peerUsername))
          entry.record.peerUsername,
    ];
    for (final username in stale) {
      await store.remove(username);
      lastKnownLocation.remove(username);
      _lastFixAt.remove(username);
      notifyListeners();
    }
    if (stale.isNotEmpty) _syncBeaconLoop();

    // Outbound: a request we delivered online that is no longer pending was
    // answered — friends in the mirror means accepted, otherwise declined.
    // (Requests never delivered online say nothing here; the mesh answer
    // arrives as a FRIEND_ACCEPT/DECLINE message.)
    final stillPending = pending.outgoing.toSet();
    final answered = [
      for (final e in store.entries)
        if (e.record.state == FriendshipState.requested &&
            e.requestSentOnline &&
            !stillPending.contains(e.record.peerUsername))
          e
    ];
    for (final entry in answered) {
      final username = entry.record.peerUsername;
      final event = states[username] == 'friends'
          ? FriendEvent.recvAccept
          : FriendEvent.recvDecline;
      final (next, _) = _tryTransition(entry.record, event);
      if (next == null) continue;
      entry.record = next;
      await store.put(entry);
      notifyListeners();
    }
  }

  Future<void> _applyOnlineFriendshipState(
      String username, String serverState) async {
    final state = switch (serverState) {
      'friends' => FriendshipState.friends,
      'revoked' => FriendshipState.revoked,
      _ => null,
    };
    if (state == null) return;

    var entry = store.byUsername(username);
    if (entry == null) {
      if (state != FriendshipState.friends) return;
      final DirectoryEntry resolved;
      try {
        resolved = await directory.resolve(username);
      } on DirectoryException catch (e) {
        _log('cannot recover online friend $username: $e');
        return;
      }
      entry = FriendEntry(
        record: FriendshipRecord(
          peerUsername: resolved.username,
          peerCurve25519Pub: resolved.curve25519Pub,
          peerEd25519Pub: resolved.ed25519Pub,
          state: state,
        ),
      );
    } else if (entry.record.state == state) {
      return;
    } else {
      entry.record = entry.record.copyWith(
        state: state,
        locationSharingEnabled:
            state == FriendshipState.friends ? null : false,
      );
      if (state != FriendshipState.friends) {
        entry.myTokenToThem = null;
        entry.theirTokenToMe = null;
      }
      entry.pendingRequestMsgId = null;
      entry.requestSentOnline = false;
    }
    await store.put(entry);
    _syncBeaconLoop();
    notifyListeners();
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

  /// Cross-transport DM dedup key: SHA-256 (hex) over [msgType][sealed
  /// payload] — exactly the relay body / ciphertext column server-side, so
  /// the backend's FCM push and both local receive paths derive the same key
  /// for one message. SHA-256 because Postgres (pgcrypto) computes it too.
  Future<String> _dmDedupKey(int msgType, Uint8List payload) async {
    final digest =
        await Sha256().hash(Uint8List.fromList([msgType, ...payload]));
    return _hex(digest.bytes);
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
    // Same sealed payload through the online relay, so a grant/refresh
    // reaches a friend we never meet on the mesh.
    final online = _online;
    if (online != null && online.canRequest) {
      try {
        await online.client.sendRelay(entry.record.peerUsername,
            Uint8List.fromList([msgTypeFriendAccept, ...payload]));
      } on OnlineException catch (e) {
        _log('online token delivery failed: $e');
      }
    }
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
    if (position == null) {
      await _uploadLocationBlobs(useCachedOnly: true);
      return;
    }
    _lastOwnPosition = (
      lat: position.lat,
      lon: position.lon,
      accuracyM: position.accuracyM,
      at: _now(),
    );
    await _sendToPeers(
      msgTypeLocation,
      encodeLocationBeacon(
        (position.lat * 1e6).round(),
        (position.lon * 1e6).round(),
        position.accuracyM.round().clamp(0, 0xFFFF),
      ),
    );
    // Same cadence feeds the online side: one sealed blob per sharing
    // friend, latest-only server-side.
    await _uploadLocationBlobs(position: position);
  }

  /// Replace my server-side location blobs with the current sharing set —
  /// one coordinate sealed per friend (the server can't read them). An empty
  /// set is uploaded even without a GPS fix: that IS the online revoke.
  Future<void> _uploadLocationBlobs(
      {({double lat, double lon, double accuracyM})? position,
      bool useCachedOnly = false}) async {
    final online = _online;
    if (online == null || !online.canRequest) return;
    final sharing = [
      for (final e in store.entries)
        if (e.record.locationSharingEnabled) e
    ];
    final blobs = <String, Uint8List>{};
    if (sharing.isNotEmpty) {
      if (position != null) {
        _lastOwnPosition = (
          lat: position.lat,
          lon: position.lon,
          accuracyM: position.accuracyM,
          at: _now(),
        );
      } else if (!useCachedOnly) {
        position = await _readPosition();
        if (position != null) {
          _lastOwnPosition = (
            lat: position.lat,
            lon: position.lon,
            accuracyM: position.accuracyM,
            at: _now(),
          );
        }
      }
      final cached = _lastOwnPosition;
      if (position == null && cached != null) {
        position = (
          lat: cached.lat,
          lon: cached.lon,
          accuracyM: cached.accuracyM,
        );
      }
      if (position == null) return; // no current or last-known fix
      final ageS = cached == null
          ? 0
          : _now()
              .difference(cached.at)
              .inSeconds
              .clamp(0, 0xFFFFFFFF)
              .toInt();
      for (final entry in sharing) {
        blobs[entry.record.peerUsername] = await encodeLocationResponse(
          LocationResponsePayload(
            targetPubkeyId: _myHint,
            latMicrodeg: (position.lat * 1e6).round(),
            lonMicrodeg: (position.lon * 1e6).round(),
            accuracyM: position.accuracyM.round().clamp(0, 0xFFFF),
            beaconAgeS: ageS,
            zoneId: broadcastZone,
          ),
          pubkeyId(entry.record.peerEd25519Pub),
          entry.record.peerCurve25519Pub,
        );
      }
    }
    try {
      await online.client.putLocationBlobs(blobs);
    } on OnlineException catch (e) {
      _log('location blob upload failed: $e');
    }
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
