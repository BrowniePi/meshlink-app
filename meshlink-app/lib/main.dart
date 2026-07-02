import 'package:flutter/material.dart';

import 'ble_poc/ble_scan_poc_screen.dart';

void main() {
  runApp(const MeshLinkApp());
}

class MeshLinkApp extends StatelessWidget {
  const MeshLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshLink',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      // Temporary home: BLE plugin proof-of-concept. The chat UI task
      // replaces this with the real Phase 1 screen.
      home: const BleScanPocScreen(),
    );
  }
}
