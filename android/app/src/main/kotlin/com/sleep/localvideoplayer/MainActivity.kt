package com.sleep.localvideoplayer

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sleep.localvideoplayer/background"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val intent = Intent(this, KeepAliveService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("START_FAILED", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            stopService(Intent(this, KeepAliveService::class.java))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("STOP_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
