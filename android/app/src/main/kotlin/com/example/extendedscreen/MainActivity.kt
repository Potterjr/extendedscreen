package com.example.extendedscreen

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.extendedscreen.plugins.VideoDecoderPlugin
import com.example.extendedscreen.plugins.SurfaceViewPlugin
import com.example.extendedscreen.plugins.PermissionsPlugin
import com.example.extendedscreen.plugins.ScreenCapturePlugin
import com.example.extendedscreen.plugins.ClientKeepAlivePlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VideoDecoderPlugin.register(flutterEngine, this)
        SurfaceViewPlugin.register(flutterEngine, this)
        PermissionsPlugin.register(flutterEngine, this)
        ScreenCapturePlugin.register(flutterEngine, this)
        ClientKeepAlivePlugin.register(flutterEngine, this)
    }

    // Route the MediaProjection consent result to the capture plugin.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!ScreenCapturePlugin.handleActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
}
