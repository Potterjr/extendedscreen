package com.example.extendedscreen

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.extendedscreen.plugins.VideoDecoderPlugin
import com.example.extendedscreen.plugins.SurfaceViewPlugin
import com.example.extendedscreen.plugins.PermissionsPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VideoDecoderPlugin.register(flutterEngine, this)
        SurfaceViewPlugin.register(flutterEngine, this)
        PermissionsPlugin.register(flutterEngine, this)
    }
}
