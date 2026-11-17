package com.example.extendedscreen

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.extendedscreen.plugins.VideoDecoderPlugin
import com.example.extendedscreen.plugins.SurfaceViewPlugin
import com.example.extendedscreen.plugins.PermissionsPlugin
import com.example.extendedscreen.plugins.ScreenCapturePlugin
import com.example.extendedscreen.plugins.ClientKeepAlivePlugin
import com.example.extendedscreen.plugins.ClientKeepAliveService
import com.example.extendedscreen.plugins.WifiLatencyLock
import com.example.extendedscreen.plugins.BatteryStatusPlugin
import com.example.extendedscreen.plugins.WifiPairingPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VideoDecoderPlugin.register(flutterEngine, this)
        SurfaceViewPlugin.register(flutterEngine, this)
        PermissionsPlugin.register(flutterEngine, this)
        ScreenCapturePlugin.register(flutterEngine, this)
        ClientKeepAlivePlugin.register(flutterEngine, this)
        BatteryStatusPlugin.register(flutterEngine, this)
        WifiPairingPlugin.register(flutterEngine, this)
    }

    // Route the MediaProjection consent result to the capture plugin.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!ScreenCapturePlugin.handleActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    // There is no cached engine, so FlutterActivity destroys its engine, and
    // with it the Dart side's socket, heartbeat and reconnect loop, every time
    // this activity is destroyed: swiped away from Recents, Back on Home
    // finishing it, or relaunched for a configuration change. A foreground
    // service left running after that only holds up a process that can no
    // longer reconnect: the keep-alive notification stayed while the tablet
    // never came back, and a reverse-remote capture kept encoding frames
    // nobody reads.
    override fun onDestroy() {
        // Always: the next engine starts with no share running and must not
        // reuse the consent token (single-use on Android 14+), so a capture
        // can't be handed over.
        ScreenCapturePlugin.onHostDestroyed(this)
        // A broadcast from adb (a pairing, a USB session key) must not be
        // handed to an engine that is gone: nothing would answer it. A
        // relaunched activity registers again.
        WifiPairingPlugin.onHostDestroyed(this)
        // A configuration change relaunches the activity at once and the new
        // engine's connect calls KeepAliveChannel.start() again, so the
        // keep-alive stays up across it.
        if (!isChangingConfigurations) ClientKeepAliveService.stop(this)
        // Nothing left to release it once the engine is gone; a relaunched
        // activity's session takes it again when it streams over Wi-Fi.
        WifiLatencyLock.release()
        super.onDestroy()
    }
}
