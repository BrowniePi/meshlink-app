import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/friend_wire.dart';
import '../friends/friend_service.dart';

/// Friend location view. Offline venue "map": a tile map would need internet
/// the event deliberately doesn't have, so the pin is drawn on a local
/// canvas with coordinates, accuracy, and — critically — `beacon_age_s` as
/// "updated Ns ago" so a stale position is obvious.
///
/// Polls at most every 60 s (the node rate-limits harder anyway) and shows
/// last-known between polls. A refusal is indistinguishable from an unknown
/// user by design; the UI says only "Location not available".
class FriendMapScreen extends StatefulWidget {
  const FriendMapScreen({
    super.key,
    required this.friends,
    required this.username,
  });

  final FriendService friends;
  final String username;

  @override
  State<FriendMapScreen> createState() => _FriendMapScreenState();
}

class _FriendMapScreenState extends State<FriendMapScreen> {
  LocationResponsePayload? _last;
  DateTime? _lastAt;
  bool _everTried = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Freshest-wins: two answers can race for one query (the friend's phone
    // live, a node cached). The query future resolves with the first; any
    // fresher one lands in the service's lastKnownLocation afterwards and
    // arrives here through this listener.
    widget.friends.addListener(_onFreshLocation);
    _last = widget.friends.lastKnownLocation[widget.username];
    if (_last != null) {
      _lastAt = DateTime.now();
      _everTried = true;
    }
    _query();
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _query());
  }

  @override
  void dispose() {
    widget.friends.removeListener(_onFreshLocation);
    _poll?.cancel();
    super.dispose();
  }

  void _onFreshLocation() {
    final cached = widget.friends.lastKnownLocation[widget.username];
    // The service only replaces the cached entry with a fresher fix, so a
    // new object here is by construction newer than what we show.
    if (cached == null || identical(cached, _last)) return;
    setState(() {
      _everTried = true;
      _last = cached;
      _lastAt = DateTime.now();
    });
  }

  Future<void> _query() async {
    final result = await widget.friends.queryFriendLocation(widget.username);
    if (!mounted) return;
    setState(() {
      _everTried = true;
      if (result != null) {
        _last = result;
        _lastAt = DateTime.now();
      }
    });
  }

  /// Age of the coordinate right now: the node-reported beacon age plus the
  /// time since we received the response.
  int? get _ageS {
    final last = _last;
    final lastAt = _lastAt;
    if (last == null || lastAt == null) return null;
    return last.beaconAgeS + DateTime.now().difference(lastAt).inSeconds;
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.username} — location')),
      body: last == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_everTried ? Icons.location_off : Icons.location_searching,
                      size: 48),
                  const SizedBox(height: 12),
                  Text(_everTried
                      ? 'Location not available'
                      : 'Asking the node…'),
                  if (_everTried)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'They may not be sharing their location with you, or '
                        'their phone has not reported a position yet.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _PinPainter(
                      color: Theme.of(context).colorScheme.primary,
                      gridColor: Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withValues(alpha: 0.5),
                    ),
                  ),
                ),
                SafeArea(
                  child: ListTile(
                    leading: const Icon(Icons.place),
                    title: Text(
                      '${(last.latMicrodeg / 1e6).toStringAsFixed(6)}, '
                      '${(last.lonMicrodeg / 1e6).toStringAsFixed(6)}',
                    ),
                    subtitle: Text(
                      'updated ${_ageS}s ago · ±${last.accuracyM} m'
                      '${last.zoneId != 0xFFFF ? ' · zone ${last.zoneId}' : ''}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh (max once a minute)',
                      onPressed: _query,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// A venue-grid backdrop with the friend's pin at the centre — an honest
/// offline stand-in for a tile map.
class _PinPainter extends CustomPainter {
  _PinPainter({required this.color, required this.gridColor});

  final Color color;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final centre = Offset(size.width / 2, size.height / 2);
    final halo = Paint()..color = color.withValues(alpha: 0.15);
    canvas.drawCircle(centre, 56, halo);
    final pin = Paint()..color = color;
    canvas.drawCircle(centre, 10, pin);
    final path = Path()
      ..moveTo(centre.dx, centre.dy + 26)
      ..lineTo(centre.dx - 10 * cos(pi / 6), centre.dy + 10 * sin(pi / 6))
      ..lineTo(centre.dx + 10 * cos(pi / 6), centre.dy + 10 * sin(pi / 6))
      ..close();
    canvas.drawPath(path, pin);
  }

  @override
  bool shouldRepaint(covariant _PinPainter oldDelegate) =>
      color != oldDelegate.color;
}
