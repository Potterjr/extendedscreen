package com.example.extendedscreen.plugins

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reverse remote (Mac controls tablet): captures THIS device's screen via
 * MediaProjection and streams the H.264/H.265 NAL units to the Mac, which
 * decodes them. The heavy lifting (projection + encoder + virtual display)
 * lives in [ScreenCaptureService] so it keeps running as a foreground service
 * even when the user switches to other apps — the whole point of remote control.
 *
 * This plugin owns the method/event channels and the one-time consent flow.
 */
object ScreenCapturePlugin : MethodChannel.MethodCallHandler {

    private const val CHANNEL = "extended_screen/android_capture"
    private const val FRAMES_CHANNEL = "extended_screen/android_frames"
    const val REQUEST_CODE = 0xCA9

    private var activity: Activity? = null
    private var methodChannel: MethodChannel? = null
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    // The MediaProjection consent token (valid until capture stops).
    private var projectionResultCode = 0
    private var projectionData: Intent? = null
    private var pendingProjectionResult: MethodChannel.Result? = null

    fun register(engine: FlutterEngine, act: Activity) {
        activity = act
        methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, FRAMES_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestProjection" -> requestProjection(result)
            "startCapture" -> {
                startCapture(
                    w = call.argument<Int>("width") ?: 0,
                    h = call.argument<Int>("height") ?: 0,
                    codec = call.argument<String>("codec") ?: "h264",
                    fps = call.argument<Int>("fps") ?: 60,
                    bitrate = call.argument<Int>("bitrate") ?: 12_000_000,
                )
                result.success(null)
            }
            "stopCapture" -> {
                stopCapture()
                result.success(null)
            }
            "requestIdr" -> {
                ScreenCaptureService.requestIdr()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestProjection(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.success(false)
            return
        }
        if (projectionData != null) {
            result.success(true) // consent already granted this session
            return
        }
        pendingProjectionResult = result
        val mpm = act.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
        act.startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_CODE)
    }

    /** Forwarded from MainActivity.onActivityResult. Returns true if consumed. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val pending = pendingProjectionResult
        pendingProjectionResult = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            projectionResultCode = resultCode
            projectionData = data
            pending?.success(true)
        } else {
            pending?.success(false)
        }
        return true
    }

    private fun startCapture(w: Int, h: Int, codec: String, fps: Int, bitrate: Int) {
        val act = activity ?: return
        val data = projectionData ?: return
        val intent = Intent(act, ScreenCaptureService::class.java).apply {
            putExtra("resultCode", projectionResultCode)
            putExtra("data", data)
            putExtra("width", w)
            putExtra("height", h)
            putExtra("codec", codec)
            putExtra("fps", fps)
            putExtra("bitrate", bitrate)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            act.startForegroundService(intent)
        } else {
            act.startService(intent)
        }
    }

    private fun stopCapture() {
        val act = activity ?: return
        act.stopService(Intent(act, ScreenCaptureService::class.java))
        projectionData = null
        projectionResultCode = 0
    }

    /** Called by the service for every encoded NAL unit. */
    fun emitFrame(bytes: ByteArray) {
        val sink = eventSink ?: return
        main.post { sink.success(bytes) }
    }
}
