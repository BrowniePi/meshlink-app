import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

import '../debug/debug_log.dart' as dbg;

/// The four battery tiers from Technical Reference §6. Thresholds:
/// ≥50% active, 20–50% passive, <20% leaf, <10% ticket-only.
enum BatteryTier {
  /// Full duty cycle (100 ms on / 900 ms off); full Spray-and-Wait relay.
  activeRelay('Active relay'),

  /// Reduced duty cycle (50 ms on / 1,950 ms off); relay only direct to
  /// destination, no spray copy generation.
  passiveRelay('Passive relay'),

  /// Advertise only on send; own messages and deliveries only, zero relay
  /// load on the device.
  leaf('Leaf mode'),

  /// BLE off except to display/scan the ticket QR; all messaging disabled.
  ticketOnly('Ticket-only mode');

  const BatteryTier(this.label);
  final String label;

  static BatteryTier forLevel(int percent) {
    if (percent < 10) return BatteryTier.ticketOnly;
    if (percent < 20) return BatteryTier.leaf;
    if (percent < 50) return BatteryTier.passiveRelay;
    return BatteryTier.activeRelay;
  }
}

/// Reads the battery percent 0–100, or null if the platform won't report it.
typedef BatteryLevelReader = Future<int?> Function();

/// Four-tier battery management (Phase 7): polls the battery level every
/// 60 seconds and transitions [tier] automatically per the Technical
/// Reference table. Transitions are logged for debugging. The test menu can
/// pin a tier via [force] to demo each behavior without draining a device.
///
/// This class only decides the tier; enforcement (BLE duty cycle, relay
/// throttling, messaging cut-off) lives with the transports — see
/// FailoverTransport.applyTier.
class BatteryTierManager {
  BatteryTierManager({
    BatteryLevelReader? readLevel,
    this.pollInterval = const Duration(seconds: 60),
  }) : _readLevel = readLevel ?? _pluginLevel;

  static final Battery _battery = Battery();

  static Future<int?> _pluginLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return null; // platform won't report battery (e.g. desktop test bench)
    }
  }

  final BatteryLevelReader _readLevel;
  final Duration pollInterval;

  /// Current tier. UI-observable (chat strip) and consumed by the transport.
  final ValueNotifier<BatteryTier> tier = ValueNotifier(BatteryTier.activeRelay);

  /// Last polled battery percent, null when unknown. For display only.
  final ValueNotifier<int?> level = ValueNotifier(null);

  BatteryTier? _forced;

  /// Non-null while the test menu has pinned a tier.
  BatteryTier? get forced => _forced;

  Timer? _timer;

  Future<void> start() async {
    if (_timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => poll());
    await poll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One poll cycle: read the level and re-evaluate the tier (unless forced).
  Future<void> poll() async {
    final percent = await _readLevel();
    level.value = percent;
    if (_forced != null) return;
    // Unknown level fails open to active relay: a platform that can't
    // report battery must never lose messaging over it.
    _transition(
      percent == null ? BatteryTier.activeRelay : BatteryTier.forLevel(percent),
      reason: percent == null ? 'level unknown' : 'battery $percent%',
    );
  }

  /// Pin the tier from the test menu; null returns to automatic.
  void force(BatteryTier? pinned) {
    _forced = pinned;
    if (pinned != null) {
      _transition(pinned, reason: 'forced via test menu');
    } else {
      dbg.DebugLog.instance.log('battery', 'tier force cleared — back to auto');
      poll();
    }
  }

  void _transition(BatteryTier next, {required String reason}) {
    if (tier.value == next) return;
    dbg.DebugLog.instance
        .log('battery', 'tier ${tier.value.label} → ${next.label} ($reason)');
    tier.value = next;
  }
}
