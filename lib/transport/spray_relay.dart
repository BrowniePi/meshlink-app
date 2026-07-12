import 'dart:typed_data';

import '../core/pipeline.dart';
import '../debug/debug_log.dart' as dbg;
import '../power/battery_tier_manager.dart';
import 'transport.dart';

/// Phone-side Spray-and-Wait relay: hand the pipeline's onward copy
/// ([PipelineResult.forward] — ttl already decremented, spray_L already
/// binary-split) to every connected peer except the one it arrived from.
///
/// This is the enforcement point the battery tiers promise (Technical
/// Reference §6): only [BatteryTier.activeRelay] generates spray copies.
/// Passive relay's "direct to destination only" degenerates to no spraying
/// on a phone — peers are transport IDs, so a phone cannot tell which peer
/// is a payload's destination; leaf and ticket-only carry zero relay load.
Future<void> sprayRelay({
  required Transport transport,
  required String fromPeer,
  required PipelineResult result,
  BatteryTierManager? batteryTier,
}) async {
  final Uint8List? forward = result.forward;
  if (forward == null) return;
  final tier = batteryTier?.tier.value ?? BatteryTier.activeRelay;
  if (tier != BatteryTier.activeRelay) return;

  var reached = 0;
  for (final peer in transport.listPeers()) {
    if (peer == fromPeer) continue;
    try {
      await transport.send(peer, forward);
      reached++;
    } catch (_) {
      // Peer vanished mid-send; dedup makes any retry safe.
    }
  }
  if (reached > 0) {
    dbg.DebugLog.instance.log('relay',
        'sprayed msg onward to $reached peer(s) (ttl=${forward[68]}, '
        'spray_L=${forward[69]})');
  }
}
