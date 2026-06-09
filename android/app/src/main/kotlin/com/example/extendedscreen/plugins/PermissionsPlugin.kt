package com.example.extendedscreen.plugins

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

object PermissionsPlugin {
    private const val CHANNEL = "extended_screen/permissions"

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermissions" -> {
                    val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                    val batteryOptimized = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        pm.isIgnoringBatteryOptimizations(context.packageName)
                    } else true
                    val overlayPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(context)
                    } else true
                    result.success(mapOf(
                        "battery_optimization" to batteryOptimized,
                        "display_over_apps" to overlayPermission,
                    ))
                }
                "openPermission" -> {
                    val perm = call.argument<String>("permission")
                    val intent = when (perm) {
                        "battery_optimization" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:${context.packageName}")
                                }
                            } else null
                        }
                        "display_over_apps" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                                    data = Uri.parse("package:${context.packageName}")
                                }
                            } else null
                        }
                        else -> null
                    }
                    intent?.let {
                        it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(it)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
