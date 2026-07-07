import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';

import '../debug/debug_log.dart' as dbg;

/// Phone telemetry ping responder — the app half of the node's 2-minute
/// telemetry ping (docs/phone-ping-app-spec.md; node reference
/// meshlink-node/node/monitoring/phone_ping.py).
///
/// The node sends `MLPP1{"t":"ping"}` over whichever transport the phone is
/// connected on; the app answers with
/// `MLPP1{"t":"pong","lat":…,"lon":…,"battery":…,"charging":…}` on the same
/// transport. Telemetry frames are demuxed off the mesh-packet path by
/// FailoverTransport before the pipeline ever sees them — they are not
/// signed packets and must never reach the meshlink-core decode path.

/// `MLPP1` — must match PHONE_PING_MAGIC on the node.
const List<int> phonePingMagic = [0x4D, 0x4C, 0x50, 0x50, 0x31];

/// The demux rule (spec §2): a reassembled frame starting with `MLPP1` is a
/// telemetry control frame, everything else is a mesh packet. A real mesh
/// packet starts with a random 16-byte msg_id, so a false match is ~2⁻⁴⁰.
bool isTelemetryFrame(Uint8List frame) {
  if (frame.length < phonePingMagic.length) return false;
  for (var i = 0; i < phonePingMagic.length; i++) {
    if (frame[i] != phonePingMagic[i]) return false;
  }
  return true;
}

/// Encode a pong frame exactly per spec §3: magic + compact JSON with keys
/// t, lat, lon, battery always present (nullable) and charging only if known.
Uint8List encodePong({double? lat, double? lon, int? battery, bool? charging}) {
  final body = <String, dynamic>{
    't': 'pong',
    'lat': lat,
    'lon': lon,
    'battery': battery,
  };
  if (charging != null) body['charging'] = charging;
  return Uint8List.fromList([...phonePingMagic, ...utf8.encode(jsonEncode(body))]);
}

/// One telemetry reading, computed fresh per ping — nothing is stored.
class TelemetryReading {
  const TelemetryReading({this.lat, this.lon, this.battery, this.charging});

  final double? lat;
  final double? lon;
  final int? battery;
  final bool? charging;
}

typedef TelemetryReader = Future<TelemetryReading> Function();
typedef PongSender = Future<void> Function(String peerId, Uint8List frame);

/// Answers ping frames with pong frames. Carries no timer — cadence is
/// entirely the node's (spec §6). [reader] is injectable for tests; the
/// default reads the real battery (battery_plus) and location (geolocator).
class PhonePingResponder {
  PhonePingResponder({TelemetryReader? reader})
      : _read = reader ?? readDeviceTelemetry;

  final TelemetryReader _read;

  /// Peers with a pong already in flight: a second ping that arrives while
  /// resolving location is coalesced into the pending answer (spec §4).
  final Set<String> _inFlight = {};

  /// Handle one reassembled telemetry frame. Invalid JSON, a missing "t",
  /// or an unknown type are dropped silently, mirroring the node's lenient
  /// parse. [send] must reply on the transport the frame arrived on.
  Future<void> handle(String peerId, Uint8List frame, PongSender send) async {
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(frame.sublist(phonePingMagic.length)));
    } catch (_) {
      return; // not valid JSON — drop silently
    }
    // Unknown extra keys are tolerated; only "t" matters (spec §3).
    if (body is! Map || body['t'] != 'ping') return;
    if (!_inFlight.add(peerId)) return; // coalesce: one answer per burst

    try {
      final reading = await _read();
      final pong = encodePong(
        lat: reading.lat,
        lon: reading.lon,
        battery: reading.battery,
        charging: reading.charging,
      );
      await send(peerId, pong);
      dbg.DebugLog.instance.log(
          'telemetry',
          'pong → $peerId (lat=${reading.lat} lon=${reading.lon} '
              'battery=${reading.battery} charging=${reading.charging})');
    } catch (e) {
      // Peer dropped mid-answer or a platform read blew up: the node ages
      // out the missing report after 3 missed pings; nothing to retry.
      dbg.DebugLog.instance
          .log('telemetry', 'pong to $peerId failed: $e', level: dbg.LogLevel.warn);
    } finally {
      _inFlight.remove(peerId);
    }
  }
}

/// Real device reading: battery via battery_plus, location via geolocator.
/// Every field degrades to null independently — a denied location permission
/// or an unreadable battery still produces a pong (spec §3/§5).
Future<TelemetryReading> readDeviceTelemetry() async {
  int? battery;
  bool? charging;
  try {
    final b = Battery();
    battery = await b.batteryLevel;
    charging = switch (await b.batteryState) {
      BatteryState.charging || BatteryState.full => true,
      BatteryState.discharging || BatteryState.connectedNotCharging => false,
      BatteryState.unknown => null,
    };
  } catch (_) {
    // platform won't report battery — send the pong anyway
  }
  final position = await _readPosition();
  return TelemetryReading(
    lat: position?.latitude,
    lon: position?.longitude,
    battery: battery,
    charging: charging,
  );
}

/// Precise "while in use" fix (spec §4/§5). The permission request happens
/// here, in context — the node only pings while the phone is connected and
/// foregrounded, and the OS prompt carries the crowd-map explanation from
/// Info.plist / the Android permission strings. Denial is never an error:
/// the pong ships with lat/lon null and messaging is unaffected.
Future<Position?> _readPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    try {
      // Fresh street/stage-level fix, bounded so the reply stays prompt.
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 4),
        ),
      );
    } on TimeoutException {
      return await Geolocator.getLastKnownPosition();
    }
  } catch (_) {
    return null; // location stack unavailable — report null, still pong
  }
}
