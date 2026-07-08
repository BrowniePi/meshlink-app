import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/power/battery_tier_manager.dart';

void main() {
  group('BatteryTier.forLevel thresholds (Technical Reference §6)', () {
    test('≥50% is active relay', () {
      expect(BatteryTier.forLevel(100), BatteryTier.activeRelay);
      expect(BatteryTier.forLevel(50), BatteryTier.activeRelay);
    });

    test('20–50% is passive relay', () {
      expect(BatteryTier.forLevel(49), BatteryTier.passiveRelay);
      expect(BatteryTier.forLevel(20), BatteryTier.passiveRelay);
    });

    test('<20% is leaf mode', () {
      expect(BatteryTier.forLevel(19), BatteryTier.leaf);
      expect(BatteryTier.forLevel(10), BatteryTier.leaf);
    });

    test('<10% is ticket-only mode', () {
      expect(BatteryTier.forLevel(9), BatteryTier.ticketOnly);
      expect(BatteryTier.forLevel(0), BatteryTier.ticketOnly);
    });
  });

  group('BatteryTierManager', () {
    test('poll transitions the tier automatically as the battery drains',
        () async {
      var level = 80;
      final manager = BatteryTierManager(readLevel: () async => level);

      await manager.poll();
      expect(manager.tier.value, BatteryTier.activeRelay);
      expect(manager.level.value, 80);

      level = 35;
      await manager.poll();
      expect(manager.tier.value, BatteryTier.passiveRelay);

      level = 15;
      await manager.poll();
      expect(manager.tier.value, BatteryTier.leaf);

      level = 5;
      await manager.poll();
      expect(manager.tier.value, BatteryTier.ticketOnly);

      // Recharge climbs back out.
      level = 60;
      await manager.poll();
      expect(manager.tier.value, BatteryTier.activeRelay);
    });

    test('unknown battery level fails open to active relay', () async {
      final manager = BatteryTierManager(readLevel: () async => null);
      await manager.poll();
      expect(manager.tier.value, BatteryTier.activeRelay);
      expect(manager.level.value, isNull);
    });

    test('tier notifier fires only on actual transitions', () async {
      var level = 80;
      final manager = BatteryTierManager(readLevel: () async => level);
      var notifications = 0;
      manager.tier.addListener(() => notifications++);

      await manager.poll(); // 80% — already the default tier, no transition
      await manager.poll();
      expect(notifications, 0);

      level = 30;
      await manager.poll();
      await manager.poll(); // still 30% — no second notification
      expect(notifications, 1);
    });

    test('force pins the tier against polling; force(null) returns to auto',
        () async {
      final manager = BatteryTierManager(readLevel: () async => 90);

      manager.force(BatteryTier.ticketOnly);
      expect(manager.forced, BatteryTier.ticketOnly);
      expect(manager.tier.value, BatteryTier.ticketOnly);

      await manager.poll(); // battery says 90%, but the pin wins
      expect(manager.tier.value, BatteryTier.ticketOnly);
      expect(manager.level.value, 90); // level display still updates

      manager.force(null);
      await manager.poll();
      expect(manager.forced, isNull);
      expect(manager.tier.value, BatteryTier.activeRelay);
    });

    test('start polls immediately and stop halts the timer', () async {
      var polls = 0;
      final manager = BatteryTierManager(
        readLevel: () async {
          polls++;
          return 42;
        },
        pollInterval: const Duration(milliseconds: 20),
      );

      await manager.start();
      expect(polls, 1);
      expect(manager.tier.value, BatteryTier.passiveRelay);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(polls, greaterThan(1));

      manager.stop();
      final after = polls;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(polls, after);
    });
  });
}
