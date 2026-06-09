package com.example.extendedscreen.plugins

import android.app.Activity
import android.content.Context
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

object SurfaceViewPlugin {

    private const val VIEW_TYPE = "extended_screen/surface_view"

    fun register(engine: FlutterEngine, activity: Activity) {
        engine.platformViewsController.registry
            .registerViewFactory(VIEW_TYPE, DecoderSurfaceFactory(activity))
    }
}

class DecoderSurfaceFactory(private val activity: Activity) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return DecoderSurfaceView(context)
    }
}

class DecoderSurfaceView(context: Context) : PlatformView, SurfaceHolder.Callback {

    private val surfaceView = SurfaceView(context)

    init {
        surfaceView.holder.addCallback(this)
    }

    override fun getView(): View = surfaceView

    override fun surfaceCreated(holder: SurfaceHolder) {
        // Pass the real Surface to the video decoder
        VideoDecoderPlugin.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
    override fun surfaceDestroyed(holder: SurfaceHolder) {}
    override fun dispose() {}
}
