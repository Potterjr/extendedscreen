package com.example.extendedscreen.plugins

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.BinaryCodec
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

object VideoDecoderPlugin : MethodChannel.MethodCallHandler {

    private const val CHANNEL = "extended_screen/video_decoder"
    private const val NAL_CHANNEL = "extended_screen/nal_feed"

    private var mediaCodec: MediaCodec? = null
    private var surface: Surface? = null
    private val nalQueue = LinkedBlockingQueue<ByteArray>(120)
    private val availableInputs = LinkedBlockingQueue<Int>()
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var configured = false
    private val droppedNalCount = AtomicInteger(0)

    // Pending init params (set by Dart `initialize`); codec is configured once
    // BOTH the surface and these params are available — whichever arrives last.
    private var pendingWidth = 0
    private var pendingHeight = 0
    private var pendingFps = 60
    private var pendingMime: String? = null

    fun register(engine: FlutterEngine, act: Activity) {
        activity = act
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        // Binary channel for NAL data — avoids StandardMessageCodec overhead on hot path.
        BasicMessageChannel(engine.dartExecutor.binaryMessenger, NAL_CHANNEL, BinaryCodec.INSTANCE)
            .setMessageHandler { buf, reply ->
                if (buf != null) {
                    val nal = ByteArray(buf.remaining())
                    buf.get(nal)
                    feedNal(nal)
                }
                reply.reply(null)
            }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                pendingWidth = call.argument<Int>("width") ?: 2960
                pendingHeight = call.argument<Int>("height") ?: 1848
                pendingFps = call.argument<Int>("fps") ?: 60
                pendingMime = if ((call.argument<String>("codec") ?: "h264") == "h265")
                    MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
                setDisplayRefreshRate(pendingFps.toFloat())
                tryConfigure()
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
            "getDropCount" -> {
                result.success(droppedNalCount.getAndSet(0))
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

    // NAL type 7 = SPS, which always leads a keyframe group (SPS+PPS+IDR).
    // Dropping a keyframe NAL corrupts all following P-frames until the next IDR.
    private fun isKeyframeNal(nal: ByteArray) =
        nal.size >= 5 && (nal[4].toInt() and 0x1F) == 7

    // Pair an incoming NAL with an available input buffer; whichever is ready.
    @Synchronized
    private fun feedNal(nal: ByteArray) {
        val codec = mediaCodec
        val index = availableInputs.poll()
        if (codec != null && index != null) {
            submit(codec, index, nal)
        } else {
            if (!nalQueue.offer(nal)) {
                // Queue full — prefer dropping a P-frame over a keyframe so the
                // decoder stays in a decodable state without forcing an IDR request.
                val dropped = dropOldestNonKeyframe()
                if (!dropped) nalQueue.poll() // all keyframes — drop oldest anyway
                nalQueue.offer(nal)
                droppedNalCount.incrementAndGet()
            }
        }
    }

    // Returns true if a non-keyframe NAL was found and removed.
    private fun dropOldestNonKeyframe(): Boolean {
        val iter = nalQueue.iterator()
        while (iter.hasNext()) {
            if (!isKeyframeNal(iter.next())) {
                iter.remove()
                return true
            }
        }
        return false
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

    private fun setDisplayRefreshRate(fps: Float) {
        val act = activity ?: return
        act.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // API 30+: request exact display mode with target refresh rate
                val display = act.display ?: return@runOnUiThread
                val targetMode = display.supportedModes
                    .filter { it.physicalWidth == display.mode.physicalWidth }
                    .maxByOrNull { if (it.refreshRate <= fps) it.refreshRate else 0f }
                if (targetMode != null) {
                    val params = act.window.attributes
                    params.preferredDisplayModeId = targetMode.modeId
                    act.window.attributes = params
                }
            } else {
                val params = act.window.attributes
                params.preferredRefreshRate = fps
                act.window.attributes = params
            }
        }
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
        droppedNalCount.set(0)
    }

    private class CodecCallback : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            VideoDecoderPlugin.onInputAvailable(codec, index)
        }

        override fun onOutputBufferAvailable(
            codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo
        ) {
            try { codec.releaseOutputBuffer(index, true) } catch (_: Exception) {}
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            VideoDecoderPlugin.channel?.invokeMethod("onCodecError", e.diagnosticInfo)
            VideoDecoderPlugin.channel?.invokeMethod("onRequestIdr", null)
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {}
    }
}
