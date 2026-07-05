import 'package:meshlink_app/identity/device_identity.dart';

/// Fresh Ed25519 identity generated at call time — no hardcoded key material
/// anywhere, even for tests (PHASE4_CHANGES.md §Signing). Replaces the
/// Phase 1 committed test seed.
Future<DeviceIdentity> testIdentity() => DeviceIdentity.generate();
