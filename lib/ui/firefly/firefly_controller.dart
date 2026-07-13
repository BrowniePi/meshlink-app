import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/friend_wire.dart';
import '../../core/message.dart';
import '../../core/message_factory.dart';
import '../../core/pipeline.dart';
import '../../debug/debug_log.dart' as dbg;
import '../../friends/friend_service.dart';
import '../../identity/device_identity.dart';
import '../../identity/token_storage.dart';
import '../../power/battery_tier_manager.dart';
import '../../telemetry/phone_ping_responder.dart';
import '../../transport/failover_transport.dart';
import '../../transport/spray_relay.dart';
import '../../transport/transport.dart';

/// Derived link quality to the mesh, driving the firefly's glow. There is no
/// RSSI-grade metric in the stack, so this is an honest approximation:
/// WiFi node link = strong, several BLE peers = good, one = weak, none =
/// offline (direct-radio only once someone comes in range).
enum LinkStrength { strong, good, weak, offline }

/// One friend's last-known position as the node reported it (lat/lon), plus
/// where that lands on the 800x800 venue-map world.
class FriendPosition {
  FriendPosition({
    required this.latMicrodeg,
    required this.lonMicrodeg,
    required this.accuracyM,
    required this.beaconAgeS,
    required this.zoneId,
    required this.receivedAt,
  });

  final int latMicrodeg;
  final int lonMicrodeg;
  final int accuracyM;
  final int beaconAgeS;
  final int zoneId;
  final DateTime receivedAt;

  /// Age of the coordinate right now: node-reported beacon age plus time
  /// since we received the response.
  int get ageS =>
      beaconAgeS + DateTime.now().difference(receivedAt).inSeconds;
}

/// A broadcast-chat entry (debug feature — the "message all nearby" chat).
class BroadcastEntry {
  BroadcastEntry({required this.text, required this.outgoing, this.packet});
  final String text;
  final bool outgoing;
  final Uint8List? packet;
  final DateTime at = DateTime.now();
}

/// Power modes shown in settings, mapped onto the Phase 7 battery tiers:
/// Saver pins Leaf (own messages only, no relaying), Balanced follows the
/// battery level automatically, Boost pins Active relay.
enum PowerMode { saver, balanced, boost }

/// The world is the design's 800x800 venue map; positions are px in it.
const double worldSize = 800;
const Offset worldCenter = Offset(400, 400);

/// Deterministically place a zone id on the venue map: hash → ring position
/// inside the stands. The same zone always lands on the same spot, so the
/// "random" mapping is at least stable across rebuilds and both theme modes.
Offset zoneAnchor(int zoneId) {
  var h = zoneId * 2654435761 & 0x7fffffff;
  final angle = (h % 3600) / 3600 * 2 * pi;
  h ~/= 3600;
  final radius = 180 + (h % 160).toDouble(); // between field edge and stands
  return worldCenter + Offset(cos(angle) * radius, sin(angle) * radius);
}

/// Owns the mesh side of the Firefly UI: transport lifecycle, the inbound
/// pipeline demux (friend traffic vs broadcast chat), attestation
/// presentation, unread counts, link strength, location polling and the
/// lat/lon → venue-map projection. Widgets listen and rebuild.
///
/// This replaces ChatScreen as the transport's single owner; the debug panel
/// reads the broadcast feed from here instead of running its own receive
/// path.
class FireflyController extends ChangeNotifier {
  FireflyController({
    required this.transport,
    required this.pipeline,
    required this.identity,
    required this.friends,
    required this.attestationToken,
    required this.onTokenExpired,
    required this.readPosition,
    this.batteryTier,
  }) {
    final rng = Random.secure();
    _ephemId = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  }

  final Transport transport;
  final RelayPipeline pipeline;
  final DeviceIdentity identity;
  final FriendService friends;
  final AttestationToken attestationToken;
  final VoidCallback onTokenExpired;
  final BatteryTierManager? batteryTier;
  final PositionReader readPosition;

  late final Uint8List _ephemId;
  final Set<String> _presentedPeers = {};
  Timer? _pollTimer;
  Timer? _tickTimer;
  String? _transportError;

  // ---- UI-observed state ----

  /// Broadcast ("nearby") chat feed — debug feature.
  final List<BroadcastEntry> broadcast = [];

  /// Last packet we broadcast — source for the replay attack (debug).
  Uint8List? lastSentPacket;

  /// Last pipeline drop reason seen on this device (debug footer).
  String? lastDrop;

  /// Per-friend unread DM count; cleared when their chat opens.
  final Map<String, int> unread = {};

  /// Per-friend "show on map" preference (client-side filter, default on).
  final Map<String, bool> showOnMap = {};

  /// Friend username → last known position.
  final Map<String, FriendPosition> positions = {};

  /// Our own GPS fix, when permission granted; anchors the projection.
  ({double lat, double lon, double accuracyM})? ownPosition;

  /// Zone id of the node we're connected through, learned from the zone
  /// field of inbound non-broadcast packets. Null until any node traffic.
  int? ownZoneId;

  /// The chat currently on screen (username, or 'group:<a>,<b>' key); its
  /// incoming messages don't count as unread.
  String? openChatId;

  /// Theme preference (session-scoped).
  final ValueNotifier<bool> darkMode = ValueNotifier(true);

  /// Real-world map (streets around you) vs the venue-art backdrop.
  bool realWorldMap = true;

  void setRealWorldMap(bool on) {
    realWorldMap = on;
    notifyListeners();
  }

  String? get transportError => _transportError;

  // ---- lifecycle ----

  Future<void> start() async {
    transport.onReceive(_onPacket);
    try {
      await transport.start();
    } catch (e) {
      _transportError = 'Transport: $e';
      notifyListeners();
    }
    friends.presentAttestation = presentToPeers;
    friends.addListener(_onFriendsChanged);
    _rememberCounts();
    _pollTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _pollCycle());
    // Slow UI tick: peers list / beacon ages have no change notifications.
    _tickTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => notifyListeners());
    unawaited(_pollCycle());
  }

  @override
  void dispose() {
    friends.presentAttestation = null;
    friends.removeListener(_onFriendsChanged);
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    transport.stop();
    super.dispose();
  }

  // ---- derived state ----

  List<String> get peers => transport.listPeers();

  bool get wifiOn => transport is FailoverTransport &&
      (transport as FailoverTransport).wifiEnabled.value;

  /// The node identity carried on its telemetry pings, while fresh. The node
  /// pings every 2 minutes and ages a phone out after 3 missed pings; the
  /// same 3-interval window keeps this honest across a brief disconnect.
  NodeInfo? get nodeInfo {
    final t = transport;
    if (t is! FailoverTransport) return null;
    final info = t.phonePing?.nodeInfo.value;
    if (info == null) return null;
    final age = DateTime.now().difference(info.receivedAt);
    return age > const Duration(minutes: 6) ? null : info;
  }

  LinkStrength get strength {
    final t = transport;
    if (t is FailoverTransport && t.wifiEnabled.value && t.wifi.connected) {
      return LinkStrength.strong;
    }
    final n = peers.length;
    if (n >= 2) return LinkStrength.good;
    if (n == 1) return LinkStrength.weak;
    return LinkStrength.offline;
  }

  PowerMode get powerMode {
    final forced = batteryTier?.forced;
    if (forced == BatteryTier.leaf || forced == BatteryTier.ticketOnly) {
      return PowerMode.saver;
    }
    if (forced == BatteryTier.activeRelay) return PowerMode.boost;
    return PowerMode.balanced;
  }

  void setPowerMode(PowerMode mode) {
    final manager = batteryTier;
    if (manager == null) return;
    switch (mode) {
      case PowerMode.saver:
        manager.force(BatteryTier.leaf);
      case PowerMode.balanced:
        manager.force(null);
      case PowerMode.boost:
        manager.force(BatteryTier.activeRelay);
    }
    notifyListeners();
  }

  bool get messagingDisabled =>
      batteryTier?.tier.value == BatteryTier.ticketOnly;

  int totalUnread() =>
      unread.values.fold(0, (a, b) => a + b);

  bool isVisible(String username) => showOnMap[username] ?? true;

  void setVisible(String username, bool visible) {
    showOnMap[username] = visible;
    notifyListeners();
  }

  void markRead(String username) {
    if ((unread[username] ?? 0) != 0) {
      unread[username] = 0;
      notifyListeners();
    }
  }

  /// Master "share my location" switch: on iff any friend currently gets our
  /// beacon. Turning it off revokes every active share (remembering the
  /// set); turning it back on restores exactly that set.
  bool get sharingAny =>
      friends.friends.any((e) => e.record.locationSharingEnabled);

  Set<String> _rememberedShares = {};

  Future<void> setSharingMaster(bool on) async {
    if (on) {
      for (final username in _rememberedShares) {
        final entry = friends.store.byUsername(username);
        if (entry != null && !entry.record.locationSharingEnabled) {
          await friends.enableLocationSharing(username);
        }
      }
    } else {
      _rememberedShares = {
        for (final e in friends.friends)
          if (e.record.locationSharingEnabled) e.record.peerUsername
      };
      for (final username in _rememberedShares) {
        await friends.disableLocationSharing(username);
      }
    }
    notifyListeners();
  }

  // ---- venue-map projection ----

  /// Where WE are on the venue map. The node tells us only a zone id, so the
  /// zone is hashed to a stable spot near the stands; before any node
  /// traffic we sit at the map centre.
  Offset get youWorld => ownZoneId == null
      ? worldCenter
      : zoneAnchor(ownZoneId!) + const Offset(24, 30);

  /// Metres per world-map pixel. 800 px ≈ 480 m — stadium-ish scale.
  static const double metersPerPx = 0.6;

  /// Project a friend's lat/lon onto the venue map relative to our own GPS
  /// fix (equirectangular — fine at venue scale). Without our own fix the
  /// offsets are anchored to the centroid of everyone we can see, so
  /// relative placement between friends stays truthful.
  Offset? worldOf(String username) {
    final p = positions[username];
    if (p == null) return null;
    final own = ownPosition;
    double dxM, dyM;
    if (own != null) {
      dxM = (p.lonMicrodeg / 1e6 - own.lon) *
          cos(own.lat * pi / 180) * 111320;
      dyM = -(p.latMicrodeg / 1e6 - own.lat) * 110540;
      final anchor = youWorld;
      return _clampToBowl(
          anchor + Offset(dxM / metersPerPx, dyM / metersPerPx));
    }
    // No own fix: anchor the group of friends around the map centre.
    final all = positions.values.toList();
    final cLat = all.map((e) => e.latMicrodeg).reduce((a, b) => a + b) /
        all.length / 1e6;
    final cLon = all.map((e) => e.lonMicrodeg).reduce((a, b) => a + b) /
        all.length / 1e6;
    dxM = (p.lonMicrodeg / 1e6 - cLon) * cos(cLat * pi / 180) * 111320;
    dyM = -(p.latMicrodeg / 1e6 - cLat) * 110540;
    return _clampToBowl(
        worldCenter + Offset(dxM / metersPerPx, dyM / metersPerPx));
  }

  Offset _clampToBowl(Offset world) {
    final v = world - worldCenter;
    const maxR = 355.0;
    if (v.distance <= maxR) return world;
    return worldCenter + v * (maxR / v.distance);
  }

  /// Straight-line distance to a friend in metres, when both fixes exist.
  int? distanceM(String username) {
    final p = positions[username];
    final own = ownPosition;
    if (p == null || own == null) return null;
    final dx = (p.lonMicrodeg / 1e6 - own.lon) *
        cos(own.lat * pi / 180) * 111320;
    final dy = (p.latMicrodeg / 1e6 - own.lat) * 110540;
    return sqrt(dx * dx + dy * dy).round();
  }

  /// Compass direction from us to the friend (N/NE/…), when both fixes exist.
  String? bearing(String username) {
    final p = positions[username];
    final own = ownPosition;
    if (p == null || own == null) return null;
    final dx = (p.lonMicrodeg / 1e6 - own.lon) * cos(own.lat * pi / 180);
    final dy = p.latMicrodeg / 1e6 - own.lat;
    const dirs = ['E', 'NE', 'N', 'NW', 'W', 'SW', 'S', 'SE'];
    final a = ((atan2(dy, dx) * 180 / pi) + 360) % 360;
    return dirs[((a + 22.5) ~/ 45) % 8];
  }

  /// Human status line for a friend, used on cards / rows / chat headers.
  String detailOf(String username) {
    final entry = friends.store.byUsername(username);
    if (entry == null) return '';
    if (entry.theirTokenToMe == null) return 'not sharing their location';
    final p = positions[username];
    if (p == null) return 'sharing · asking the node…';
    final d = distanceM(username);
    final b = bearing(username);
    final age = p.ageS < 120 ? '${p.ageS}s ago' : '${p.ageS ~/ 60}m ago';
    if (d != null) return '${d}m $b of you · $age';
    return 'zone ${p.zoneId} · updated $age';
  }

  // ---- polling ----

  Future<void> _pollCycle() async {
    // Own GPS fix (permission-aware; null on denial — never an error).
    unawaited(readPosition().then((p) {
      if (p != null) {
        ownPosition = p;
        notifyListeners();
      }
    }));
    // A request sent into an empty cell reached nobody; re-spray it until the
    // peer answers (the service spaces the re-sends out itself).
    unawaited(friends.resendPendingRequests());
    // One location query per friend who granted us a token; the service
    // rate-limits to the node's 60 s minimum, so a 30 s cycle just retries
    // sooner after failures. Answers land in the service's freshest-wins
    // cache and reach [positions] via _onFriendsChanged — updating here too
    // could overwrite a fresher racing answer with the first one back.
    for (final entry in friends.friends) {
      final username = entry.record.peerUsername;
      // A capability token gates the mesh path only; online, the friend's
      // sealed blob (or its absence) is the consent check.
      if ((entry.theirTokenToMe == null && !friends.isOnline) ||
          !isVisible(username)) {
        continue;
      }
      unawaited(friends.queryFriendLocation(username));
    }
  }

  // ---- inbound path (ported from ChatScreen, the previous transport owner) --

  Map<String, int> _dmCounts = {};

  void _rememberCounts() {
    _dmCounts = {
      for (final e in friends.store.entries)
        e.record.peerUsername: e.messages.length
    };
  }

  /// Payload objects already adopted from the service's freshest-wins cache,
  /// so a notify for something else doesn't re-stamp receivedAt.
  final Map<String, LocationResponsePayload> _adoptedLocation = {};

  /// FriendService notified: adopt any fresher location answer (two can race
  /// per query — the friend's phone live, a node cached; the service only
  /// replaces its cache with a fresher fix), then detect newly-arrived
  /// incoming DMs to bump unread badges, and re-render.
  void _onFriendsChanged() {
    friends.lastKnownLocation.forEach((username, payload) {
      if (identical(_adoptedLocation[username], payload)) return;
      _adoptedLocation[username] = payload;
      positions[username] = FriendPosition(
        latMicrodeg: payload.latMicrodeg,
        lonMicrodeg: payload.lonMicrodeg,
        accuracyM: payload.accuracyM,
        beaconAgeS: payload.beaconAgeS,
        zoneId: payload.zoneId,
        receivedAt: DateTime.now(),
      );
    });
    for (final e in friends.store.entries) {
      final username = e.record.peerUsername;
      final before = _dmCounts[username] ?? 0;
      if (e.messages.length > before) {
        final fresh = e.messages.sublist(before);
        final incoming = fresh.where((m) => !m.outgoing).length;
        if (incoming > 0 && openChatId != username) {
          unread[username] = (unread[username] ?? 0) + incoming;
        }
      }
    }
    _rememberCounts();
    notifyListeners();
  }

  bool _handleExpiredToken() {
    if (!attestationToken.isExpiredAt(DateTime.now())) return false;
    onTokenExpired();
    return true;
  }

  /// Present our attestation token to every peer that hasn't seen it — a
  /// node drops this device's packets until it has cached our token.
  Future<void> presentToPeers() async {
    if (_handleExpiredToken()) return;
    final unpresented =
        peers.where((p) => !_presentedPeers.contains(p)).toList();
    if (unpresented.isEmpty) return;
    final Uint8List packet;
    try {
      packet = await buildSignedPacket(
        identity: identity,
        ephemId: _ephemId,
        payload: utf8.encode(attestationToken.token),
        msgType: msgTypeAttestation,
        zoneId: broadcastZone,
      );
    } catch (e) {
      dbg.DebugLog.instance.log('attest', 'failed to build presentation: $e',
          level: dbg.LogLevel.error);
      return;
    }
    for (final peer in unpresented) {
      try {
        await transport.send(peer, packet);
        _presentedPeers.add(peer);
        dbg.DebugLog.instance.log('attest', 'presented token to $peer');
      } catch (_) {
        // Peer dropped mid-send; re-presented when it reappears.
      }
    }
  }

  Future<void> _onPacket(String peerId, Uint8List data) async {
    unawaited(presentToPeers());
    final result = await pipeline.process(data);
    if (result.outcome == Outcome.deliver) {
      dbg.DebugLog.instance
          .log('pipeline', 'delivered ${data.length}B from $peerId');
    } else {
      dbg.DebugLog.instance.log('pipeline',
          'DROPPED ${data.length}B from $peerId: ${result.dropReason}',
          level: dbg.LogLevel.warn);
      lastDrop = result.dropReason;
      notifyListeners();
      return;
    }

    // Spray-and-Wait: pass the pipeline's onward copy to our other peers
    // (battery-tier gated). Runs before local handling so relaying never
    // waits on UI work.
    unawaited(sprayRelay(
      transport: transport,
      fromPeer: peerId,
      result: result,
      batteryTier: batteryTier,
    ));

    final message = result.message!;
    // Learn our zone from node traffic: a node stamps its own zone id on
    // packets it originates/relays; broadcast (0xFFFF) says nothing.
    if (message.zoneId != 0xFFFF && message.zoneId != ownZoneId) {
      ownZoneId = message.zoneId;
    }
    if (message.msgType != msgTypeText) {
      await friends.handleMessage(message);
      notifyListeners();
      return;
    }
    broadcast.add(BroadcastEntry(
      text: utf8.decode(message.payload, allowMalformed: true),
      outgoing: false,
      packet: data,
    ));
    notifyListeners();
  }

  /// Broadcast "message all nearby devices" send (debug feature). Returns an
  /// error string for the UI, or null on success.
  Future<String?> sendBroadcast(String text) async {
    if (text.isEmpty) return null;
    if (messagingDisabled) {
      return 'Battery critical — messaging disabled (Ticket-only mode)';
    }
    if (_handleExpiredToken()) {
      return 'Your event pass expired — getting a new one…';
    }
    final packet = await buildSignedPacket(
      identity: identity,
      ephemId: _ephemId,
      payload: utf8.encode(text),
      zoneId: broadcastZone,
    );
    final result = await pipeline.process(packet);
    if (result.outcome != Outcome.deliver) {
      return 'Not sent: ${result.dropReason}';
    }
    lastSentPacket = packet;
    await presentToPeers();
    final currentPeers = peers;
    var failures = 0;
    for (final peer in currentPeers) {
      try {
        await transport.send(peer, packet);
      } catch (_) {
        failures++;
      }
    }
    broadcast.add(BroadcastEntry(text: text, outgoing: true, packet: packet));
    notifyListeners();
    if (currentPeers.isEmpty) {
      return 'No peers in range — message not transmitted';
    }
    if (failures > 0) {
      return 'Send failed to $failures of ${currentPeers.length} peer(s)';
    }
    return null;
  }

  /// DM send with the ticket-only and expired-token gates applied.
  Future<String?> sendDm(String username, String text) async {
    if (messagingDisabled) {
      return 'Battery critical — messaging disabled (Ticket-only mode)';
    }
    if (_handleExpiredToken()) {
      return 'Your event pass expired — getting a new one…';
    }
    try {
      await friends.sendDirectMessage(username, text);
      return null;
    } on ArgumentError {
      return 'Message too long — max $maxDmTextBytes bytes';
    } on StateError {
      return 'You are no longer friends with $username';
    }
  }
}
