// PROOF OF CONCEPT — throwaway code.
//
// This screen exists only to confirm flutter_blue_plus works end-to-end on
// both platforms before the real BLE transport adapter is built. It is not
// wired into the relay pipeline and may be deleted once the transport
// adapter task is complete.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleScanPocScreen extends StatefulWidget {
  const BleScanPocScreen({super.key});

  @override
  State<BleScanPocScreen> createState() => _BleScanPocScreenState();
}

class _BleScanPocScreenState extends State<BleScanPocScreen> {
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  List<ScanResult> _results = [];
  bool _scanning = false;
  String? _error;

  late final StreamSubscription<BluetoothAdapterState> _adapterSub;
  late final StreamSubscription<List<ScanResult>> _resultsSub;
  late final StreamSubscription<bool> _scanningSub;

  @override
  void initState() {
    super.initState();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      setState(() => _adapterState = state);
    });
    _resultsSub = FlutterBluePlus.scanResults.listen((results) {
      setState(() => _results = results);
    });
    _scanningSub = FlutterBluePlus.isScanning.listen((scanning) {
      setState(() => _scanning = scanning);
    });
  }

  @override
  void dispose() {
    _adapterSub.cancel();
    _resultsSub.cancel();
    _scanningSub.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _toggleScan() async {
    setState(() => _error = null);
    try {
      if (_scanning) {
        await FlutterBluePlus.stopScan();
      } else {
        // flutter_blue_plus requests the platform Bluetooth permissions
        // (Nearby Devices on Android 12+, the system BLE prompt on iOS)
        // when scanning starts; a denial surfaces as an exception here.
        await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
      }
    } catch (e) {
      setState(() => _error = 'Scan failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bluetoothOn = _adapterState == BluetoothAdapterState.on;
    return Scaffold(
      appBar: AppBar(title: const Text('BLE PoC (throwaway)')),
      body: Column(
        children: [
          if (!bluetoothOn)
            MaterialBanner(
              content: Text('Bluetooth is ${_adapterState.name} — turn it on to scan.'),
              actions: const [SizedBox.shrink()],
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final r = _results[i];
                final name = r.advertisementData.advName.isNotEmpty
                    ? r.advertisementData.advName
                    : (r.device.platformName.isNotEmpty
                        ? r.device.platformName
                        : '(unnamed)');
                return ListTile(
                  title: Text(name),
                  subtitle: Text(r.device.remoteId.str),
                  trailing: Text('${r.rssi} dBm'),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: bluetoothOn ? _toggleScan : null,
        icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(_scanning ? 'Stop' : 'Scan'),
      ),
    );
  }
}
