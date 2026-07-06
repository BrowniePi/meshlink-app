# Phase 6 app-side decisions not specified in Notion

Choices made during implementation that the Phase 6 page, task pages, and
WiFi Mesh Add-On doc leave open. Everything else follows those docs directly.
Companion to the node repo's docs/phase6-node-decisions.md.

- **Phone↔node WiFi wire protocol = one persistent TCP connection per phone,
  2-byte big-endian length framing.** The docs never name a protocol. The
  framing is byte-identical to the BLE path's (ble_transport.dart ↔
  node/ble/framing.py), so both phone-facing transports share one wire
  format. A persistent connection was chosen over Phase 0's
  one-frame-per-connection connect-back scheme because phones can't reliably
  accept inbound connections (background sockets, per-OS quirks), and a held
  socket gives instant disconnect detection for the failover logic.

- **Node listener address = 10.78.0.1:7800.** The node is always 10.78.0.1
  of its own AP subnet (setup_hostapd.sh), so the address holds venue-wide
  and roaming to another node's BSSID reconnects to the same host:port on
  the new node. Port 7800 continues the 10.78 theme; overridable on the node
  via `MESHLINK_WIFI_LISTEN` and in the app via `MESHLINK_WIFI_NODE_HOST/PORT`
  dart-defines.

- **SSID/passphrase reach the app as compile-time dart-defines**
  (`MESHLINK_WIFI_SSID`/`MESHLINK_WIFI_PASSPHRASE`, lib/config/wifi_config.dart),
  matching the BackendConfig pattern and the node's file-push mechanism —
  the backend stays off the venue path (Phase 5 rule). The build's values
  must match the fleet's wifi_deployment.conf.

- **Transport selection lives in FailoverTransport, not the pipeline.** The
  relay pipeline still sees exactly one `Transport` (zero meshlink-core
  changes — the Phase 0 abstraction test). listPeers() answers "who do new
  sends go to": the WiFi node while that connection is healthy, BLE peers
  otherwise. send() routes by peer-id prefix regardless of preference, so
  in-flight messages complete on whichever transport they started on.

- **Android binds the app process to the mesh network while joined**
  (WifiMeshManager.kt). A WifiNetworkSpecifier network is app-scoped and
  invisible to the default route, so plain Dart sockets can't reach
  10.78.0.1 without the bind. Consequence: the app's own backend HTTP is
  dead while the mesh is on — acceptable because the backend is only used
  at onboarding, before the toggle exists. leave()/onLost unbind.

- **WiFi Calling detection reports "unknown" on both platforms.** Neither
  iOS nor Android exposes a public query API (Android's is
  READ_PRIVILEGED_PHONE_STATE-gated). The toggle's escalated call-warning
  path exists and is tested; it triggers wherever a future platform bridge
  reports `wifiCallingActive == true`. Per the task's "where exposed by the
  platform" qualifier.

- **The WiFi opt-in choice is not persisted.** Off-by-default every launch
  is the safe reading of "opt-in, off by default": the onboarding step is
  offered after a fresh attestation fetch, and the chat AppBar toggle covers
  every later launch (a stored valid token skips onboarding entirely).

- **iOS Runner now has Runner.entitlements** with the Hotspot Configuration
  capability — required by NEHotspotConfiguration. If provisioning fails,
  enable "Hotspot Configuration" for the App ID in the Apple Developer
  portal; the pbxproj already points all three Runner configs at the file.
