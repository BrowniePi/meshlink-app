package com.meshlink.meshlink_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

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
    }
}
