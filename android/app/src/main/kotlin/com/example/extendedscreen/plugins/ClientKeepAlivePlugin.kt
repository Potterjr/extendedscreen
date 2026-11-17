package com.example.extendedscreen.plugins

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine

/**
 * Thin bridge that lets the Dart client connection manager start/stop the
 * [ClientKeepAliveService] as the extended-screen link comes up and goes down,
 * and hold [WifiLatencyLock] while a Wi-Fi session streams.
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
                "setLowLatencyWifi" -> {
                    WifiLatencyLock.set(context, call.argument<Boolean>("enabled") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}

/**
 * Asks Android to keep Wi-Fi out of power saving while a Wi-Fi session
 * streams. With power saving on, the radio dozes between beacons and a frame
 * that arrives meanwhile waits for it: the stream's latency jumps by tens of
 * milliseconds now and then, which at 120 fps is several late frames.
 *
 * `WIFI_MODE_FULL_LOW_LATENCY` (API 29+) is honoured only while this app is in
 * the foreground with the screen on, which is when the picture is being
 * watched. Below API 29 the older high-performance mode does the same job but
 * applies in the background too, which is why Dart lets go of it as soon as
 * a link is lost, not only on Disconnect. Needs `WAKE_LOCK`, which the
 * manifest already asks for.
 *
 * Not reference-counted: set(true) twice and set(false) once releases it.
 */
object WifiLatencyLock {
    private const val TAG = "ExtendedScreen:wifi"
    private var lock: WifiManager.WifiLock? = null

    @Synchronized
    fun set(context: Context, enabled: Boolean) {
        if (!enabled) return release()
        try {
            val held = lock ?: create(context)?.also { lock = it } ?: return
            if (!held.isHeld) held.acquire()
        } catch (e: Exception) {
            // Not worth failing a session over: the link works without it.
            android.util.Log.w("ExtendedScreen", "Wi-Fi low-latency lock not taken", e)
        }
    }

    /** Also called when the activity goes away: its engine can no longer. */
    @Synchronized
    fun release() {
        try {
            lock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            android.util.Log.w("ExtendedScreen", "Wi-Fi low-latency lock not released", e)
        }
    }

    private fun create(context: Context): WifiManager.WifiLock? {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE)
            as? WifiManager ?: return null
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            @Suppress("DEPRECATION")
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        return wifi.createWifiLock(mode, TAG).apply { setReferenceCounted(false) }
    }
}
