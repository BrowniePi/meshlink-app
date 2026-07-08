import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/config/wifi_config.dart';

void main() {
  const base = WifiConfig(
    ssid: 'MeshLink-Test',
    passphrase: 'test-passphrase',
    nodeHost: WifiConfig.piNodeHost,
    nodePort: 7800,
  );

  test('forNodeType swaps only the host, keeping ssid/passphrase/port', () {
    final mac = base.forNodeType(WifiNodeType.mac);
    expect(mac.nodeHost, WifiConfig.macNodeHost);
    expect(mac.ssid, base.ssid);
    expect(mac.passphrase, base.passphrase);
    expect(mac.nodePort, base.nodePort);
  });

  test('forNodeType is reversible: Mac→Pi restores the Pi host', () {
    final mac = base.forNodeType(WifiNodeType.mac);
    final backToPi = mac.forNodeType(WifiNodeType.pi);
    expect(backToPi.nodeHost, WifiConfig.piNodeHost);
    expect(backToPi.nodeType, WifiNodeType.pi);
  });

  test('nodeType reports the current target from the host', () {
    expect(base.nodeType, WifiNodeType.pi);
    expect(base.forNodeType(WifiNodeType.mac).nodeType, WifiNodeType.mac);
  });
}
