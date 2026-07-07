import 'package:flutter/material.dart';

import '../../power/battery_tier_manager.dart';

/// Persistent battery-tier strip: which of the four Phase 7 power modes the
/// device is in right now, plus the last polled battery percent. A "(forced)"
/// marker shows when the test menu has pinned a tier.
class BatteryTierIndicator extends StatelessWidget {
  const BatteryTierIndicator({super.key, required this.manager});

  final BatteryTierManager manager;

  static const Map<BatteryTier, IconData> _icons = {
    BatteryTier.activeRelay: Icons.battery_full,
    BatteryTier.passiveRelay: Icons.battery_4_bar,
    BatteryTier.leaf: Icons.battery_2_bar,
    BatteryTier.ticketOnly: Icons.battery_alert,
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BatteryTier>(
      valueListenable: manager.tier,
      builder: (context, tier, _) => ValueListenableBuilder<int?>(
        valueListenable: manager.level,
        builder: (context, level, _) {
          final scheme = Theme.of(context).colorScheme;
          final (Color bg, Color fg) = switch (tier) {
            BatteryTier.activeRelay => (
                scheme.surfaceContainerHighest,
                scheme.onSurfaceVariant
              ),
            BatteryTier.passiveRelay => (
                scheme.secondaryContainer,
                scheme.onSecondaryContainer
              ),
            BatteryTier.leaf => (
                scheme.tertiaryContainer,
                scheme.onTertiaryContainer
              ),
            BatteryTier.ticketOnly => (
                scheme.errorContainer,
                scheme.onErrorContainer
              ),
          };
          final percent = level == null ? '' : ' · $level%';
          final forced = manager.forced != null ? ' (forced)' : '';
          return Material(
            color: bg,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_icons[tier], size: 16, color: fg),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Battery: ${tier.label}$percent$forced',
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: fg),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
