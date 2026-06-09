package com.example.extendedscreen.plugins

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.LinkedBlockingQueue

object VideoDecoderPlugin : MethodChannel.MethodCallHandler {

    private const val CHANNEL = "extended_screen/video_decoder"

    private var mediaCodec: MediaCodec? = null
    private var surface: Surface? = null
    private val nalQueue = LinkedBlockingQueue<ByteArray>(120)
    private val availableInputs = LinkedBlockingQueue<Int>()
    private var channel: MethodChannel? = null
    private var configured = false

    // Pending init params (set by Dart `initialize`); codec is configured once
    // BOTH the surface and these params are available — whichever arrives last.
    private var pendingWidth = 0
    private var pendingHeight = 0
    private var pendingFps = 60
    private var pendingMime: String? = null

    fun register(engine: FlutterEngine, activity: Activity) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                pendingWidth = call.argument<Int>("width") ?: 2960
                pendingHeight = call.argument<Int>("height") ?: 1848
                pendingFps = call.argument<Int>("fps") ?: 60
                pendingMime = if ((call.argument<String>("codec") ?: "h264") == "h265")
                    MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
                tryConfigure()
                result.success(null)
            }
            "feedNal" -> {
                val nal = call.argument<ByteArray>("nal")
                if (nal != null) feedNal(nal)
                result.success(null)
            }
            "requestIdr" -> {
                channel?.invokeMethod("onRequestIdr", null)
                result.success(null)
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /// Called from SurfaceViewPlugin when the SurfaceView's Surface is created.
    fun setSurface(s: Surface) {
        surface = s
        tryConfigure()
    }

    @Synchronized
    private fun tryConfigure() {
        if (configured) return
        val surf = surface ?: return
        val mime = pendingMime ?: return

        try {
            val format = MediaFormat.createVideoFormat(mime, pendingWidth, pendingHeight).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 0)
                setInteger(MediaFormat.KEY_OPERATING_RATE, pendingFps)
                setInteger(MediaFormat.KEY_PRIORITY, 0) // real-time
                if (android.os.Build.VERSION.SDK_INT >= 30) {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
            }

            val codec = MediaCodec.createDecoderByType(mime)
            codec.setCallback(CodecCallback())
            // SPS/PPS arrive inline (Annex-B) at each keyframe, so no csd needed.
            codec.configure(format, surf, null, 0)
            codec.start()
            mediaCodec = codec
            configured = true
            // Ask the host for a fresh keyframe so the decoder can start cleanly.
            channel?.invokeMethod("onRequestIdr", null)
        } catch (e: Exception) {
            channel?.invokeMethod("onCodecError", e.message)
        }
    }

    // Pair an incoming NAL with an available input buffer; whichever is ready.
    @Synchronized
    private fun feedNal(nal: ByteArray) {
        val codec = mediaCodec
        val index = availableInputs.poll()
        if (codec != null && index != null) {
            submit(codec, index, nal)
        } else {
            if (!nalQueue.offer(nal)) {
                nalQueue.poll() // drop oldest to bound latency
                nalQueue.offer(nal)
            }
        }
    }

    @Synchronized
    private fun onInputAvailable(codec: MediaCodec, index: Int) {
        val nal = nalQueue.poll()
        if (nal != null) {
            submit(codec, index, nal)
        } else {
            availableInputs.offer(index)
        }
    }

    private fun submit(codec: MediaCodec, index: Int, nal: ByteArray) {
        try {
            val buf = codec.getInputBuffer(index) ?: return
            buf.clear()
            buf.put(nal)
            codec.queueInputBuffer(index, 0, nal.size, System.nanoTime() / 1_000, 0)
        } catch (_: Exception) {}
    }

    @Synchronized
    private fun dispose() {
        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (_: Exception) {}
        mediaCodec = null
        configured = false
        pendingFps = 60
        pendingMime = null
        nalQueue.clear()
        availableInputs.clear()
    }

    private class CodecCallback : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            VideoDecoderPlugin.onInputAvailable(codec, index)
        }

        override fun onOutputBufferAvailable(
            codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo
        ) {
            // render = true → releases the buffer straight to the Surface.
            try { codec.releaseOutputBuffer(index, true) } catch (_: Exception) {}
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            VideoDecoderPlugin.channel?.invokeMethod("onCodecError", e.diagnosticInfo)
            VideoDecoderPlugin.channel?.invokeMethod("onRequestIdr", null)
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {}
    }
}
