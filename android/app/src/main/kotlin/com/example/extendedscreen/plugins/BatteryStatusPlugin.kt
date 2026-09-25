package com.example.extendedscreen.plugins

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

/// Client-side battery/charging status — the tablet's own battery while
/// connected via USB-C. Surfaced on Home so charging (not just data
/// connectivity) is visible without leaving the app.
object BatteryStatusPlugin {
    private const val CHANNEL = "extended_screen/battery"

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> {
                    // Passing a null receiver reads the current sticky battery
                    // intent synchronously without registering a real receiver.
                    val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                    val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                        status == BatteryManager.BATTERY_STATUS_FULL
                    val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                    val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                    val percent = if (level >= 0 && scale > 0) (level * 100) / scale else -1
                    result.success(mapOf(
                        "isCharging" to isCharging,
                        "level" to percent,
                    ))
                }
                else -> result.notImplemented()
            }
        }
    }
}
