import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../../core/pipeline.dart';
import '../../map/firefly_map_style.dart';
import '../../map/map_tile_store.dart';
import '../../map/offline_tile_provider.dart';
import '../../map/region_prefetcher.dart';
import '../../friends/friend_service.dart';
import '../../identity/device_identity.dart';
import '../../identity/token_storage.dart';
import '../../power/battery_tier_manager.dart';
import '../../transport/transport.dart';
import 'firefly_controller.dart';
import 'firefly_logo.dart';
import 'firefly_theme.dart';
import 'glass.dart';
import 'panels/cards.dart';
import 'panels/chat_panel.dart';
import 'panels/debug_panel.dart';
import 'panels/friends_panel.dart';
import 'panels/settings_panel.dart';
import 'venue_map.dart';

/// Debug features (broadcast chat, attack menu, BLE logs, battery force)
/// appear in the dock only when running with --dart-define=FF_DEBUG=true.
const bool ffDebug = bool.fromEnvironment('FF_DEBUG');

/// Centre of the tiles bundled in assets/map_tiles/ — where the real-world
/// map opens before the first GPS fix (tool/fetch_map_tiles.dart default).
const LatLng _bundledAreaCenter = LatLng(18.945, 72.835);

enum _Panel { none, card, group, friends, settings, chat, debug }

/// Firefly home — the full-screen venue map with friends, the glassy chrome
/// and every overlay panel, per the "Firefly v5" Claude Design mockup. Owns
/// a [FireflyController] which in turn owns the transport.
class FireflyHome extends StatefulWidget {
  const FireflyHome({
    super.key,
    required this.transport,
    required this.pipeline,
    required this.identity,
    required this.friendService,
    required this.attestationToken,
    required this.onTokenExpired,
    required this.onLogout,
    required this.readPosition,
    this.batteryTier,
  });

  final Transport transport;
  final RelayPipeline pipeline;
  final DeviceIdentity identity;
  final FriendService friendService;
  final AttestationToken attestationToken;
  final VoidCallback onTokenExpired;
  final VoidCallback onLogout;
  final PositionReader readPosition;
  final BatteryTierManager? batteryTier;

  @override
  State<FireflyHome> createState() => _FireflyHomeState();
}

class _FireflyHomeState extends State<FireflyHome>
    with TickerProviderStateMixin {
  late final FireflyController _c;

  // real-world map state
  final MapController _mapController = MapController();
  OfflineFirstTileProvider? _mapTiles;
  MapRegionPrefetcher? _prefetcher;
  final Map<Brightness, vtr.Theme> _mapThemes = {};
  bool _mapTouched = false; // user panned/zoomed; don't yank the camera
  bool _centeredOnFix = false;

  // venue-map view state (world px, design coordinates)
  double _mapX = 0, _mapY = 0, _zoom = 1;
  bool _smooth = false, _interacting = false, _dragging = false;
  Timer? _uiTimer;
  Offset _dragStart = Offset.zero, _dragOrigin = Offset.zero;
  double _pinchZoom0 = 1;
  double _moved = 0;

  _Panel _panel = _Panel.none;
  String? _cardUser;
  List<String> _groupUsers = const [];
  bool _chatIsGroup = false;
  _Panel _chatFrom = _Panel.none;

  /// `user:<name>` or `group` while find mode is active.
  String? _findTarget;
  List<String> _findGroup = const [];

  late final AnimationController _pulse; // ripples + dash + glow pulse

  @override
  void initState() {
    super.initState();
    _c = FireflyController(
      transport: widget.transport,
      pipeline: widget.pipeline,
      identity: widget.identity,
      friends: widget.friendService,
      attestationToken: widget.attestationToken,
      onTokenExpired: widget.onTokenExpired,
      readPosition: widget.readPosition,
      batteryTier: widget.batteryTier,
    );
    _c.addListener(_onModel);
    unawaited(_c.start());
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2400))
      ..repeat();
    unawaited(MapTileStore.open().then((store) {
      if (!mounted) return;
      final tiles = OfflineFirstTileProvider(store);
      setState(() {
        _mapTiles = tiles;
        _prefetcher = MapRegionPrefetcher(store, tiles);
      });
    }));
    WidgetsBinding.instance.addPostFrameCallback((_) => _recenter());
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _pulse.dispose();
    _mapController.dispose();
    _c.removeListener(_onModel);
    _c.dispose();
    super.dispose();
  }

  void _onModel() {
    if (!mounted) return;
    final own = _c.ownPosition;
    if (own != null) {
      // Top up offline coverage around wherever the user actually is.
      unawaited(_prefetcher?.maybePrefetch(own.lat, own.lon) ?? Future.value());
      // The map may have opened on the fallback area before the first GPS
      // fix; snap to the user once, unless they're already exploring.
      if (_c.realWorldMap && !_centeredOnFix && !_mapTouched) {
        _centeredOnFix = _moveMap(LatLng(own.lat, own.lon), 16);
      }
    }
    setState(() {});
  }

  // ---- map interaction ----

  double _clampZoom(double z) => z.clamp(0.55, 2.6);

  void _wakeMap() {
    if (!_interacting) setState(() => _interacting = true);
    _uiTimer?.cancel();
    _uiTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _interacting = false);
    });
  }

  void _panTo(Offset world, {double? zoom}) {
    final z = _clampZoom(zoom ?? _zoom);
    setState(() {
      _smooth = true;
      _zoom = z;
      _mapX = -(world.dx - 400) * z;
      _mapY = -(world.dy - 400) * z;
    });
  }

  void _zoomBy(int steps) {
    _wakeMap();
    if (_c.realWorldMap) {
      try {
        final cam = _mapController.camera;
        _moveMap(cam.center, cam.zoom + steps);
      } catch (_) {} // map not built yet
      return;
    }
    setState(() {
      _smooth = true;
      _zoom = _clampZoom(steps > 0 ? _zoom * 1.35 : _zoom / 1.35);
    });
  }

  void _recenter() {
    _wakeMap();
    if (_c.realWorldMap) {
      _moveMap(_ownLatLng ?? _bundledAreaCenter, 16);
      return;
    }
    _panTo(_c.youWorld, zoom: 1);
  }

  // ---- real-world map geometry ----

  LatLng? get _ownLatLng {
    final own = _c.ownPosition;
    return own == null ? null : LatLng(own.lat, own.lon);
  }

  LatLng? _friendLatLng(String username) {
    final p = _c.positions[username];
    return p == null
        ? null
        : LatLng(p.latMicrodeg / 1e6, p.lonMicrodeg / 1e6);
  }

  LatLng? _findLatLng() {
    final t = _findTarget;
    if (t == null) return null;
    final targets = t == 'group' ? _findGroup : [t.substring(5)];
    final pts = [
      for (final u in targets)
        if (_friendLatLng(u) != null) _friendLatLng(u)!
    ];
    if (pts.isEmpty) return null;
    return LatLng(
        pts.map((p) => p.latitude).reduce((a, b) => a + b) / pts.length,
        pts.map((p) => p.longitude).reduce((a, b) => a + b) / pts.length);
  }

  // ---- panel helpers ----

  void _closeAll() => setState(() {
        _panel = _Panel.none;
        _cardUser = null;
        _c.openChatId = null;
      });

  void _openCard(String username) {
    if (_moved > 8) return;
    setState(() {
      _cardUser = username;
      _panel = _Panel.card;
    });
  }

  void _openGroup(List<String> usernames) {
    if (_moved > 8) return;
    setState(() {
      _groupUsers = usernames;
      _panel = _Panel.group;
    });
  }

  void _openChat({required bool group, String? username, _Panel? from}) {
    setState(() {
      _chatIsGroup = group;
      if (username != null) _cardUser = username;
      _chatFrom = from ?? _panel;
      _panel = _Panel.chat;
      if (group) {
        for (final u in _groupUsers) {
          _c.markRead(u);
        }
        _c.openChatId = 'group:${_groupUsers.join(',')}';
      } else {
        _c.markRead(_cardUser!);
        _c.openChatId = _cardUser;
      }
    });
  }

  void _startFind({String? username, bool group = false}) {
    setState(() {
      _panel = _Panel.none;
      if (group) {
        _findTarget = 'group';
        _findGroup = List.of(_groupUsers);
      } else {
        _findTarget = 'user:$username';
      }
    });
    if (_c.realWorldMap) {
      final target = _findLatLng();
      final own = _ownLatLng;
      if (target != null) {
        final centre = own == null
            ? target
            : LatLng((target.latitude + own.latitude) / 2,
                (target.longitude + own.longitude) / 2);
        _moveMap(centre, 16);
      }
      return;
    }
    final target = _findWorld();
    if (target != null) {
      _panTo(Offset((target.dx + _c.youWorld.dx) / 2,
              (target.dy + _c.youWorld.dy) / 2),
          zoom: 1.05);
    }
  }

  Offset? _findWorld() {
    final t = _findTarget;
    if (t == null) return null;
    if (t == 'group') {
      final pts = [
        for (final u in _findGroup)
          if (_c.worldOf(u) != null) _c.worldOf(u)!
      ];
      if (pts.isEmpty) return null;
      return pts.reduce((a, b) => a + b) / pts.length.toDouble();
    }
    return _c.worldOf(t.substring(5));
  }

  String _findLabel() {
    final t = _findTarget;
    if (t == null) return '';
    if (t == 'group') {
      final d = _findGroup.isEmpty ? null : _c.distanceM(_findGroup.first);
      final b = _findGroup.isEmpty ? null : _c.bearing(_findGroup.first);
      return 'Finding group${d != null ? ' · ${d}m ${b ?? ''}' : ''}';
    }
    final u = t.substring(5);
    final d = _c.distanceM(u);
    final b = _c.bearing(u);
    return 'Finding ${u.split(' ').first}'
        '${d != null ? ' · ${d}m ${b ?? ''}' : ''}';
  }

  // ---- clustering (design: 85 world-px greedy clusters) ----

  /// Same greedy clustering as [_clusters], but over real coordinates for
  /// the real-world map: 85 world-px at the venue scale is ~51 m.
  ({List<List<String>> groups, List<String> singles}) _clustersGeo() {
    final vis = [
      for (final e in _c.friends.friends)
        if (_c.isVisible(e.record.peerUsername) &&
            _friendLatLng(e.record.peerUsername) != null)
          e.record.peerUsername
    ];
    Offset meters(String u) {
      final p = _friendLatLng(u)!;
      return Offset(p.longitude * cos(p.latitude * pi / 180) * 111320,
          p.latitude * 110540);
    }

    final used = <String>{};
    final groups = <List<String>>[];
    final singles = <String>[];
    for (final u in vis) {
      if (used.contains(u)) continue;
      final pu = meters(u);
      final members = [
        for (final o in vis)
          if (!used.contains(o) && (meters(o) - pu).distance < 51) o
      ];
      if (members.length >= 2) {
        used.addAll(members);
        groups.add(members);
      } else {
        used.add(u);
        singles.add(u);
      }
    }
    return (groups: groups, singles: singles);
  }

  ({List<List<String>> groups, List<String> singles}) _clusters() {
    final vis = [
      for (final e in _c.friends.friends)
        if (_c.isVisible(e.record.peerUsername) &&
            _c.worldOf(e.record.peerUsername) != null)
          e.record.peerUsername
    ];
    final used = <String>{};
    final groups = <List<String>>[];
    final singles = <String>[];
    for (final u in vis) {
      if (used.contains(u)) continue;
      final pu = _c.worldOf(u)!;
      final members = [
        for (final o in vis)
          if (!used.contains(o) && (_c.worldOf(o)! - pu).distance < 85) o
      ];
      if (members.length >= 2) {
        used.addAll(members);
        groups.add(members);
      } else {
        used.add(u);
        singles.add(u);
      }
    }
    return (groups: groups, singles: singles);
  }

  /// Status line under the wordmark — the mode indicator. "Online" means
  /// the backend push socket is up and carries friend requests, DMs and
  /// location; the mesh part describes the radio side, which keeps relaying
  /// either way.
  String _meshStatus() {
    final online = widget.friendService.isOnline;
    if (_c.strength == LinkStrength.offline) {
      return online ? 'Online · no mesh peers' : 'Direct radio only';
    }
    final node = _c.nodeInfo?.name;
    final n = _c.peers.length;
    return '${online ? 'Online · ' : 'Mesh only · '}'
        '${node != null ? 'via $node' : 'on mesh'}'
        ' · $n peer${n == 1 ? '' : 's'}'
        '${_c.wifiOn ? ' · turbo' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _c.darkMode,
      builder: (context, dark, _) => FireflyTheme(
        colors: dark ? FfColors.dark : FfColors.light,
        child: Builder(builder: (context) {
          final c = FireflyTheme.of(context);
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Container(
              decoration: BoxDecoration(gradient: c.bg),
              child: Stack(
                children: [
                  if (_c.realWorldMap)
                    _realMapViewport(context)
                  else
                    _mapViewport(context),
                  ..._chrome(context),
                  ..._overlays(context),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // ---- real-world map viewport ----

  /// Camera move that tolerates the map not being in the tree yet (mode
  /// toggles and async tile-store startup race the first build). Returns
  /// whether the move happened.
  bool _moveMap(LatLng center, double zoom) {
    try {
      return _mapController.move(center, zoom.clamp(3, 19));
    } catch (_) {
      return false;
    }
  }

  Widget _realMapViewport(BuildContext context) {
    final c = FireflyTheme.of(context);
    final tiles = _mapTiles;
    if (tiles == null) return const SizedBox.shrink(); // store still opening
    final clusters = _clustersGeo();
    final own = _ownLatLng;
    final findLL = _findLatLng();
    final node = _c.nodeInfo;
    final nodeLL = node?.lat != null && node?.lon != null
        ? LatLng(node!.lat!, node.lon!)
        : null;
    return Positioned.fill(
      child: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: own ?? _bundledAreaCenter,
          initialZoom: 16,
          minZoom: 3,
          maxZoom: 19,
          backgroundColor: Colors.transparent,
          interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          onMapEvent: (e) {
            // Layout events (first build, rotation, keyboard) are not the
            // user exploring: flutter_map fires nonRotatedSizeChange as soon
            // as the map gets its constraints, which would otherwise mark the
            // camera "touched" before the first GPS fix even lands and cancel
            // the snap to our own position.
            if (e.source == MapEventSource.mapController ||
                e.source == MapEventSource.nonRotatedSizeChange) {
              return;
            }
            _mapTouched = true;
            _moved = 0;
            _wakeMap();
          },
        ),
        children: [
          VectorTileLayer(
            key: ValueKey('firefly-map-${c.brightness.name}'),
            theme: _mapThemes.putIfAbsent(
                c.brightness, () => fireflyMapTheme(c)),
            tileProviders: TileProviders({mapSourceId: tiles}),
            layerMode: VectorTileLayerMode.vector,
          ),
          if (own != null && findLL != null)
            PolylineLayer(polylines: [
              Polyline(
                points: [own, findLL],
                color: c.accent,
                strokeWidth: 2,
                pattern: StrokePattern.dashed(segments: const [6, 8]),
              ),
            ]),
          MarkerLayer(markers: [
            if (findLL != null)
              Marker(
                point: findLL,
                width: 60,
                height: 60,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.accentLine, width: 1.5),
                    ),
                  ),
                ),
              ),
            if (nodeLL != null)
              Marker(
                point: nodeLL,
                width: 120,
                height: 64,
                child: _nodeMarkerBody(context, node!.name ?? 'Node'),
              ),
            for (final group in clusters.groups)
              Marker(
                point: _centroid([for (final u in group) _friendLatLng(u)!]),
                width: 140,
                height: 84,
                child: _groupMarkerBody(context, group),
              ),
            for (final u in clusters.singles)
              Marker(
                point: _friendLatLng(u)!,
                width: 80,
                height: 80,
                child: _singleMarkerBody(context, u),
              ),
            if (own != null)
              Marker(
                point: own,
                width: 160,
                height: 160,
                child: Center(child: _youMarkerBody(context)),
              ),
          ]),
        ],
      ),
    );
  }

  LatLng _centroid(List<LatLng> pts) => LatLng(
      pts.map((p) => p.latitude).reduce((a, b) => a + b) / pts.length,
      pts.map((p) => p.longitude).reduce((a, b) => a + b) / pts.length);

  // ---- venue map viewport ----

  Widget _mapViewport(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Positioned.fill(
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            setState(() {
              _zoom = _clampZoom(_zoom * exp(-event.scrollDelta.dy * 0.0015));
              _smooth = false;
            });
            _wakeMap();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) {
            _dragStart = d.focalPoint;
            _dragOrigin = Offset(_mapX, _mapY);
            _pinchZoom0 = _zoom;
            _moved = 0;
            setState(() {
              _dragging = true;
              _smooth = false;
            });
            _wakeMap();
          },
          onScaleUpdate: (d) {
            final delta = d.focalPoint - _dragStart;
            _moved = max(_moved, delta.dx.abs() + delta.dy.abs());
            setState(() {
              _mapX = _dragOrigin.dx + delta.dx;
              _mapY = _dragOrigin.dy + delta.dy;
              if (d.scale != 1) _zoom = _clampZoom(_pinchZoom0 * d.scale);
            });
            _wakeMap();
          },
          onScaleEnd: (_) => setState(() => _dragging = false),
          child: ClipRect(
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: _smooth && !_dragging
                      ? const Duration(milliseconds: 550)
                      : Duration.zero,
                  curve: Curves.easeOutCubic,
                  left: size.width / 2 - 400,
                  top: size.height / 2 - 400,
                  child: AnimatedContainer(
                    duration: _smooth && !_dragging
                        ? const Duration(milliseconds: 550)
                        : Duration.zero,
                    curve: Curves.easeOutCubic,
                    transform: Matrix4.identity()
                      ..translateByDouble(_mapX, _mapY, 0, 1)
                      ..translateByDouble(400, 400, 0, 1)
                      ..scaleByDouble(_zoom, _zoom, 1, 1)
                      ..translateByDouble(-400, -400, 0, 1),
                    child: _world(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _world(BuildContext context) {
    final c = FireflyTheme.of(context);
    final clusters = _clusters();
    final findWorld = _findWorld();
    final you = _c.youWorld;

    return SizedBox(
      width: 800,
      height: 800,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const VenueMapBackdrop(),
          if (_c.ownZoneId != null) _nodeMarker(context, _c.ownZoneId!),
          if (findWorld != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => CustomPaint(
                    painter: FindLinePainter(
                      from: you,
                      to: findWorld,
                      accent: c.accent,
                      accentLine: c.accentLine,
                      phase: (_pulse.value * 2.4) % 1,
                    ),
                  ),
                ),
              ),
            ),
          for (final group in clusters.groups) _groupMarker(context, group),
          for (final u in clusters.singles) _singleMarker(context, u),
          _youMarker(context, you),
        ],
      ),
    );
  }

  Widget _nodeMarker(BuildContext context, int zoneId) {
    final at = zoneAnchor(zoneId);
    return Positioned(
      left: at.dx - 60,
      top: at.dy - 16,
      child: SizedBox(
        width: 120,
        child: _nodeMarkerBody(
            context, _c.nodeInfo?.name ?? 'ZONE $zoneId'),
      ),
    );
  }

  /// Node marker body — a glassy hub tile with an accent-ringed name chip,
  /// visually distinct from the circular friend avatars.
  Widget _nodeMarkerBody(BuildContext context, String label) {
    final c = FireflyTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            gradient: c.glass(),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.accentLine),
            boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 14)],
          ),
          child: Icon(Icons.hub_rounded, size: 16, color: c.accent),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            gradient: c.glass(),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: c.accentLine),
          ),
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: c.accent)),
        ),
      ],
    );
  }

  Widget _rippleRing(double inset, double phase, Color color) {
    // ff-ripple: scale .35 → 3.2, opacity .7 → 0 over the cycle.
    final scale = .35 + 2.85 * phase;
    final opacity = (0.7 * (1 - phase)).clamp(0.0, 0.7);
    return Positioned.fill(
      child: IgnorePointer(
        child: Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: color.withValues(alpha: color.a * opacity),
                  width: 1.5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _youMarker(BuildContext context, Offset you) {
    return Positioned(
      left: you.dx - 23,
      top: you.dy - 23,
      child: _youMarkerBody(context),
    );
  }

  Widget _youMarkerBody(BuildContext context) {
    final c = FireflyTheme.of(context);
    final strength = _c.strength;
    final offline = strength == LinkStrength.offline;
    final power = _c.powerMode;
    final glowMap = {
      LinkStrength.strong: .7,
      LinkStrength.good: .45,
      LinkStrength.weak: .2,
      LinkStrength.offline: .0,
    };
    final rippleCount = switch (strength) {
      LinkStrength.strong => 3,
      LinkStrength.good => 2,
      LinkStrength.weak => 1,
      LinkStrength.offline => 0,
    };
    final ripples = power == PowerMode.saver && rippleCount > 1
        ? 1
        : rippleCount;
    final powerFactor = power == PowerMode.saver
        ? .5
        : power == PowerMode.boost
            ? 1.15
            : 1.0;

    return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                final t = _pulse.value;
                // weak link flickers, otherwise a gentle pulse
                final anim = offline
                    ? 1.0
                    : strength == LinkStrength.weak
                        ? (sin(t * 2 * pi * 3) > 0 ? 1.0 : .45)
                        : .8 + .2 * sin(t * 2 * pi);
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    IgnorePointer(
                      child: Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(colors: [
                            c.accentGlow.withValues(
                                alpha: c.accentGlow.a *
                                    (glowMap[strength]! * powerFactor)
                                        .clamp(0, 1)),
                            Colors.transparent,
                          ], stops: const [0, .62]),
                        ),
                      ),
                    ),
                    for (var i = 0; i < ripples; i++)
                      _rippleRing(0, (t + i / max(ripples, 1)) % 1,
                          c.accentLine),
                    Opacity(
                      opacity: anim,
                      child: FireflyLogo(
                        size: 38,
                        tailColor: offline ? c.faint : c.accent,
                        glow: offline ? 0 : glowMap[strength]!,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 2),
          Text('YOU',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: c.faint)),
        ]);
  }

  Widget _nameChip(BuildContext context, String text) {
    final c = FireflyTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        gradient: c.glass(),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.stroke),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: c.dim)),
    );
  }

  Widget _unreadBadge(BuildContext context, int count) {
    final c = FireflyTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 17),
      height: 17,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: c.accent,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 8)],
      ),
      alignment: Alignment.center,
      child: Text('$count',
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: c.accentInk)),
    );
  }

  Widget _singleMarker(BuildContext context, String username) {
    final world = _c.worldOf(username)!;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 1400),
      curve: Curves.easeInOut,
      left: world.dx - 40,
      top: world.dy - 30,
      child: _singleMarkerBody(context, username),
    );
  }

  Widget _singleMarkerBody(BuildContext context, String username) {
    final c = FireflyTheme.of(context);
    final finding = _findTarget == 'user:$username';
    final unread = _c.unread[username] ?? 0;
    return GestureDetector(
        onTap: () => _openCard(username),
        child: SizedBox(
          width: 80,
          child: Column(
            children: [
              SizedBox(
                width: 46,
                height: 46,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    if (finding)
                      AnimatedBuilder(
                        animation: _pulse,
                        builder: (context, _) => _rippleRing(
                            -6, (_pulse.value * 1.33) % 1, c.accentLine),
                      ),
                    InitialAvatar(
                      name: username,
                      size: 38,
                      ringColor: finding ? c.accent : c.edge,
                    ),
                    if (unread > 0)
                      Positioned(
                          top: -2, right: -2,
                          child: _unreadBadge(context, unread)),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              _nameChip(context, username),
            ],
          ),
        ));
  }

  Widget _groupMarker(BuildContext context, List<String> members) {
    final pts = [for (final u in members) _c.worldOf(u)!];
    final center = pts.reduce((a, b) => a + b) / members.length.toDouble();
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 1400),
      curve: Curves.easeInOut,
      left: center.dx - 70,
      top: center.dy - 34,
      child: _groupMarkerBody(context, members),
    );
  }

  Widget _groupMarkerBody(BuildContext context, List<String> members) {
    final c = FireflyTheme.of(context);
    final unread =
        members.fold(0, (a, u) => a + (_c.unread[u] ?? 0));
    final finding = _findTarget == 'group' &&
        members.every(_findGroup.contains);
    final label = '${members.first.split(' ').first} +${members.length - 1}';

    return GestureDetector(
        onTap: () => _openGroup(members),
        child: SizedBox(
          width: 140,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  GlassPanel(
                    radius: 999,
                    strong: true,
                    blur: 12,
                    borderColor: finding ? c.accent : c.stroke2,
                    padding: const EdgeInsets.all(5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < min(3, members.length); i++)
                          Container(
                            margin: EdgeInsets.only(left: i == 0 ? 0 : 0),
                            transform: Matrix4.translationValues(
                                i == 0 ? 0 : -10.0 * i, 0, 0),
                            child: InitialAvatar(
                                name: members[i], size: 32,
                                ringColor: c.edge),
                          ),
                        Container(
                          constraints: const BoxConstraints(minWidth: 22),
                          height: 22,
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          margin: EdgeInsets.only(
                              left: members.length > 1
                                  ? 4.0 - 10 * (min(3, members.length) - 1)
                                  : 4),
                          decoration: BoxDecoration(
                            color: c.glassHi,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: c.stroke),
                          ),
                          alignment: Alignment.center,
                          child: Text('${members.length}',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: c.dim)),
                        ),
                      ],
                    ),
                  ),
                  if (unread > 0)
                    Positioned(
                        top: -5, right: -3,
                        child: _unreadBadge(context, unread)),
                ],
              ),
              const SizedBox(height: 5),
              _nameChip(context, label),
            ],
          ),
        ));
  }

  // ---- floating chrome ----

  List<Widget> _chrome(BuildContext context) {
    final c = FireflyTheme.of(context);
    final chromeVisible = !_interacting;
    final modeIcons = <(IconData, String)>[
      if (_c.powerMode == PowerMode.saver)
        (Icons.battery_saver_rounded, 'Power saver'),
      if (_c.powerMode == PowerMode.boost)
        (Icons.bolt_rounded, 'Boost — relaying more traffic'),
      if (_c.wifiOn) (Icons.wifi_tethering_rounded, 'Turbo link active'),
    ];

    return [
      // wordmark
      Positioned(
        top: 56,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 350),
            opacity: chromeVisible ? 1 : 0,
            child: Center(child: FireflyWordmark(status: _meshStatus())),
          ),
        ),
      ),
      // mode indicators
      if (modeIcons.isNotEmpty)
        Positioned(
          top: 58,
          right: 16,
          child: GlassPanel(
            radius: 999,
            blur: 16,
            drop: false,
            padding: const EdgeInsets.all(6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (icon, tip) in modeIcons)
                  Tooltip(
                    message: tip,
                    child: Container(
                      width: 26,
                      height: 26,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: c.accentSoft),
                      child: Icon(icon, size: 16, color: c.accent),
                    ),
                  ),
              ],
            ),
          ),
        ),
      // finding chip
      if (_findTarget != null)
        Positioned(
          bottom: 102,
          left: 14,
          right: 14,
          child: Center(
            child: GlassPanel(
              radius: 999,
              strong: true,
              blur: 20,
              glow: true,
              borderColor: c.accentLine,
              padding: const EdgeInsets.fromLTRB(16, 9, 10, 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.near_me_rounded, size: 17, color: c.accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(_findLabel(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: c.text)),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _findTarget = null),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: c.glassLo),
                      child: Icon(Icons.close_rounded,
                          size: 16, color: c.dim),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      // map controls (visible while interacting)
      Positioned(
        right: 14,
        bottom: 110,
        child: IgnorePointer(
          ignoring: !_interacting,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: _interacting ? 1 : 0,
            child: Column(
              children: [
                GlassIconButton(
                    icon: Icons.add_rounded,
                    tooltip: 'Zoom in',
                    onTap: () => _zoomBy(1)),
                const SizedBox(height: 8),
                GlassIconButton(
                    icon: Icons.remove_rounded,
                    tooltip: 'Zoom out',
                    onTap: () => _zoomBy(-1)),
                const SizedBox(height: 8),
                GlassIconButton(
                    icon: Icons.my_location_rounded,
                    iconSize: 19,
                    tooltip: 'Recenter on you',
                    onTap: _recenter),
              ],
            ),
          ),
        ),
      ),
      // OpenStreetMap attribution (ODbL requirement for the real-world map)
      if (_c.realWorldMap)
        Positioned(
          left: 12,
          bottom: 10,
          child: IgnorePointer(
            child: Text('© OpenStreetMap contributors',
                style: TextStyle(fontSize: 9, color: c.faint)),
          ),
        ),
      // transport error strip
      if (_c.transportError != null)
        Positioned(
          top: 110,
          left: 14,
          right: 14,
          child: GlassPanel(
            radius: 14,
            padding: const EdgeInsets.all(10),
            borderColor: const Color(0x66FF6B6B),
            child: Text(_c.transportError!,
                style: const TextStyle(
                    color: Color(0xFFFF8A80), fontSize: 12)),
          ),
        ),
      // dock
      Positioned(
        bottom: 24,
        left: 0,
        right: 0,
        child: IgnorePointer(
          ignoring: _interacting,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 350),
            opacity: _interacting ? 0 : 1,
            child: Center(child: _dock(context)),
          ),
        ),
      ),
    ];
  }

  Widget _dock(BuildContext context) {
    final c = FireflyTheme.of(context);
    final unread = _c.totalUnread();
    final requests = _c.friends.pendingRequests.length;
    return GlassPanel(
      radius: 999,
      strong: true,
      blur: 24,
      padding: const EdgeInsets.all(7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _panel = _Panel.friends),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.group_rounded, size: 20, color: c.accent),
                      const SizedBox(width: 7),
                      Text('Friends',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: c.text)),
                    ],
                  ),
                ),
                if (unread + requests > 0)
                  Positioned(
                      top: -2, right: 2,
                      child: _unreadBadge(context, unread + requests)),
              ],
            ),
          ),
          Container(width: 1, height: 22, color: c.stroke),
          GestureDetector(
            onTap: () => setState(() => _panel = _Panel.settings),
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(Icons.settings_rounded, size: 20, color: c.dim),
            ),
          ),
          if (ffDebug) ...[
            Container(width: 1, height: 22, color: c.stroke),
            GestureDetector(
              onTap: () => setState(() => _panel = _Panel.debug),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(Icons.bug_report_outlined,
                    size: 20, color: c.dim),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- overlays ----

  List<Widget> _overlays(BuildContext context) {
    final c = FireflyTheme.of(context);
    if (_panel == _Panel.none) return const [];
    return [
      Positioned.fill(
        child: GestureDetector(
          onTap: _closeAll,
          child: Container(color: c.scrim),
        ),
      ),
      if (_panel == _Panel.card && _cardUser != null)
        _sheet(FriendCardSheet(
          controller: _c,
          username: _cardUser!,
          onClose: _closeAll,
          onChat: () => _openChat(group: false, from: _Panel.card),
          onFind: () => _startFind(username: _cardUser),
        )),
      if (_panel == _Panel.group)
        _sheet(GroupCardSheet(
          controller: _c,
          members: _groupUsers,
          onClose: _closeAll,
          onMemberChat: (u) =>
              _openChat(group: false, username: u, from: _Panel.group),
          onChatAll: () => _openChat(group: true, from: _Panel.group),
          onFind: () => _startFind(group: true),
        )),
      if (_panel == _Panel.friends)
        _sheet(FriendsPanel(
          controller: _c,
          onOpen: (u) => setState(() {
            _cardUser = u;
            _panel = _Panel.card;
          }),
          onClose: _closeAll,
        )),
      if (_panel == _Panel.settings)
        _sheet(SettingsPanel(
            controller: _c, onClose: _closeAll, onLogout: widget.onLogout)),
      if (_panel == _Panel.chat)
        Positioned(
          left: 0,
          right: 0,
          top: 120,
          bottom: 0,
          child: ChatPanel(
            controller: _c,
            isGroup: _chatIsGroup,
            username: _cardUser,
            groupUsers: _groupUsers,
            onBack: () => setState(() {
              _c.openChatId = null;
              _panel = (_chatIsGroup || _chatFrom == _Panel.group)
                  ? _Panel.group
                  : _Panel.card;
            }),
            onFind: () => _chatIsGroup
                ? _startFind(group: true)
                : _startFind(username: _cardUser),
          ),
        ),
      if (_panel == _Panel.debug)
        _sheet(DebugPanel(
          controller: _c,
          identity: widget.identity,
          batteryTier: widget.batteryTier,
        )),
    ];
  }

  Widget _sheet(Widget child) {
    final height = MediaQuery.of(context).size.height;
    return Positioned(
      left: 14,
      right: 14,
      bottom: 20,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * .78),
        child: child,
      ),
    );
  }
}
