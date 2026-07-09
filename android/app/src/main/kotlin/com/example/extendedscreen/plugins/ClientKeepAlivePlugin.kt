package com.example.extendedscreen.plugins

import android.content.Context
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

/**
 * Thin bridge that lets the Dart client connection manager start/stop the
 * [ClientKeepAliveService] as the extended-screen link comes up and goes down.
 */
object ClientKeepAlivePlugin {
    private const val CHANNEL = "extended_screen/keepalive"

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ClientKeepAliveService.start(context)
                    result.success(null)
                }
                "stop" -> {
                    ClientKeepAliveService.stop(context)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
