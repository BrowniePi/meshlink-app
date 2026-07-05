package com.meshlink.meshlink_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var gattServer: MeshGattServer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "meshlink/relay_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    MeshRelayService.start(this)
                    result.success(null)
                }
                "stop" -> {
                    MeshRelayService.stop(this)
                    result.success(null)
                }
                "isRunning" -> result.success(MeshRelayService.running)
                else -> result.notImplemented()
            }
        }
        KeystoreBridge(this).attach(flutterEngine.dartExecutor.binaryMessenger)
        gattServer = MeshGattServer(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // super dispatches to flutter_blue_plus's own permission listeners;
        // we additionally resume peripheral advertising once BLUETOOTH_ADVERTISE
        // is granted.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        gattServer?.onRequestPermissionsResult(requestCode)
    }
}
