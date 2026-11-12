package com.example.extendedscreen.plugins

import android.app.Activity
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock
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

// Threads: the method channel and the NAL channel (registered without a
// TaskQueue), the SurfaceHolder callback and the codec callbacks (set without
// a Handler, so they run on the looper of the thread that created the codec,
// which is main) all run on the platform (main) thread today. Everything that
// touches the queues or the codec still holds this object's lock
// (@Synchronized), so that state stays consistent if one of them moves off
// the main thread; channel.invokeMethod, which several of them call, must
// stay on it.
object VideoDecoderPlugin : MethodChannel.MethodCallHandler {

    private const val CHANNEL = "extended_screen/video_decoder"
    private const val NAL_CHANNEL = "extended_screen/nal_feed"

    // The queue holds about 100 ms of frames at the stream rate, but never
    // fewer than this, so an ordinary delivery burst doesn't trip it.
    private const val MIN_QUEUED_FRAMES = 6
    // Minimum gap between keyframe requests made because frames were dropped:
    // under sustained overload, unthrottled requests would turn the stream
    // into back-to-back IDRs and make the overload worse.
    private const val IDR_REQUEST_INTERVAL_MS = 750L
    // Ceiling for that gap while the codec takes no input at all (see
    // requestIdrThrottled()).
    private const val IDR_REQUEST_MAX_INTERVAL_MS = 8_000L

    private var mediaCodec: MediaCodec? = null
    private var surface: Surface? = null
    // Frames (one Annex-B access unit each) waiting for a free input buffer of
    // mediaCodec, at most queueCap(); availableInputs holds that codec's free
    // input buffer indices.
    private val nalQueue = LinkedBlockingQueue<ByteArray>()
    private val availableInputs = LinkedBlockingQueue<Int>()
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var configured = false
    private val droppedNalCount = AtomicInteger(0)
    // Set when frames were dropped, or a new codec started, with no keyframe
    // to resume from: every frame is then dropped until a keyframe arrives.
    private var awaitingKeyframe = false
    // When requestIdr() last asked for a keyframe (SystemClock.elapsedRealtime).
    private var lastIdrRequestMs = 0L
    // Current gap between throttled keyframe requests, and whether the codec
    // has freed an input buffer since the last request; together they back
    // the requests off while the codec is stuck.
    private var idrRetryMs = IDR_REQUEST_INTERVAL_MS
    private var inputTakenSinceIdrRequest = false
    // Codec of the stream being fed, for keyframe detection. Set by
    // `initialize` and, unlike pendingMime, kept through dispose().
    @Volatile private var isHevc = false

    // Pending init params (set by Dart `initialize`); codec is configured once
    // BOTH the surface and these params are available — whichever arrives last.
    private var pendingWidth = 0
    private var pendingHeight = 0
    // The host's stream rate; also sizes the input queue (queueCap()).
    @Volatile private var pendingFps = 60
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
                isHevc = (call.argument<String>("codec") ?: "h264") == "h265"
                pendingMime = if (isHevc)
                    MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
                setDisplayRefreshRate(pendingFps.toFloat())
                tryConfigure()
                result.success(null)
            }
            // Host changed its stream rate (0xFB, e.g. the Max preset adapting):
            // only the panel mode (and the input queue's cap) follows — the
            // running codec is provisioned for the panel's top rate already,
            // so it isn't rebuilt (a rebuild blanked the display and waited on
            // a fresh IDR).
            "setRefreshRate" -> {
                pendingFps = call.argument<Int>("fps") ?: pendingFps
                setDisplayRefreshRate(pendingFps.toFloat())
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
            "getMaxRefreshRate" -> {
                result.success(maxRefreshRate())
            }
            else -> result.notImplemented()
        }
    }

    /// Called from SurfaceViewPlugin when the SurfaceView's Surface is created.
    /// On the first surface this configures the codec; on a later surface (the
    /// SurfaceView is destroyed/recreated when the app is backgrounded then
    /// resumed) the running codec is re-bound to the new surface so it doesn't
    /// keep rendering to the abandoned one (which shows as a black screen).
    @Synchronized
    fun setSurface(s: Surface) {
        surface = s
        val codec = mediaCodec
        if (configured && codec != null) {
            try {
                codec.setOutputSurface(s)
                // Repaint immediately: ask the host for a fresh keyframe.
                requestIdr()
            } catch (e: Exception) {
                // setOutputSurface can fail if the codec isn't in a swappable
                // state — fall back to a full reconfigure on the new surface.
                // Keep the pending params so tryConfigure() can rebuild.
                channel?.invokeMethod("onCodecError", e.message)
                try { codec.release() } catch (_: Exception) {}
                mediaCodec = null
                configured = false
                // The released codec's free input buffers die with it.
                availableInputs.clear()
                tryConfigure()
            }
        } else {
            tryConfigure()
        }
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
                // The panel's top rate, not the current stream rate: the host
                // may step back up mid-session without a reconfigure.
                setInteger(MediaFormat.KEY_OPERATING_RATE, maxOf(pendingFps, maxRefreshRate()))
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
            restartInputFromKeyframe()
            // Ask the host for a fresh keyframe so the decoder can start cleanly.
            requestIdr()
        } catch (e: Exception) {
            channel?.invokeMethod("onCodecError", e.message)
        }
    }

    // Pair an incoming frame with an available input buffer; whichever is
    // ready. A frame that has to wait is queued, up to about 100 ms of them,
    // so a decoder slower than the stream drops frames instead of falling
    // seconds behind.
    @Synchronized
    private fun feedNal(nal: ByteArray) {
        if (awaitingKeyframe) {
            if (!isKeyframeAccessUnit(nal, isHevc)) {
                droppedNalCount.incrementAndGet()
                requestIdrThrottled()
                return
            }
            awaitingKeyframe = false
        }
        val codec = mediaCodec
        val index = if (codec != null) availableInputs.poll() else null
        if (codec != null && index != null) {
            submit(codec, index, nal)
        } else if (nalQueue.size < queueCap()) {
            nalQueue.offer(nal)
        } else {
            dropForOverflow(nal)
        }
    }

    // About 100 ms of frames at the host's stream rate, which pendingFps
    // follows (0xFB), never fewer than MIN_QUEUED_FRAMES.
    private fun queueCap() = maxOf(MIN_QUEUED_FRAMES, pendingFps / 10)

    // Queue full: the decoder is behind the stream. Dropping one frame from
    // the middle of a GOP corrupts every frame after it until the next
    // keyframe, so resume from a keyframe instead: the incoming one, else the
    // newest queued one (unless it is at the head, which frees no room), else
    // the next to arrive, which is requested from the host. Caller holds the
    // lock.
    private fun dropForOverflow(nal: ByteArray) {
        if (isKeyframeAccessUnit(nal, isHevc)) {
            dropQueued(nalQueue.size)
            nalQueue.offer(nal)
            return
        }
        val newest = newestQueuedKeyframe()
        if (newest > 0) {
            dropQueued(newest)
            nalQueue.offer(nal)
        } else {
            dropQueued(nalQueue.size)
            droppedNalCount.incrementAndGet() // the incoming frame
            awaitingKeyframe = true
            requestIdrThrottled()
        }
    }

    // A new codec can only start decoding at a keyframe, and the free input
    // buffer indices belonged to the codec it replaces. Keep the queue from
    // its newest keyframe on; with none queued, drop it all and wait for the
    // next keyframe. Caller holds the lock.
    private fun restartInputFromKeyframe() {
        availableInputs.clear()
        val newest = newestQueuedKeyframe()
        if (newest >= 0) {
            dropQueued(newest)
        } else {
            dropQueued(nalQueue.size)
            awaitingKeyframe = true
        }
    }

    // Index of the newest queued keyframe, or -1.
    private fun newestQueuedKeyframe(): Int {
        var newest = -1
        nalQueue.forEachIndexed { i, au -> if (isKeyframeAccessUnit(au, isHevc)) newest = i }
        return newest
    }

    // Drops the [count] oldest queued frames, counting them for the HUD.
    private fun dropQueued(count: Int) {
        repeat(count) { nalQueue.poll() }
        droppedNalCount.addAndGet(count)
    }

    // Asks the host for a keyframe, noting when so requestIdrThrottled()
    // doesn't repeat it straight away. Caller holds the lock.
    private fun requestIdr() {
        lastIdrRequestMs = SystemClock.elapsedRealtime()
        inputTakenSinceIdrRequest = false
        channel?.invokeMethod("onRequestIdr", null)
    }

    // Keyframe request for dropped frames, repeated while they keep being
    // dropped (in case the last one went unanswered), but at most once per
    // idrRetryMs. None without a codec: tryConfigure() asks for one when it
    // starts. Caller holds the lock.
    //
    // A codec with no free input buffer that has freed none since the last
    // request is stuck (failed after onError, which nothing rebuilds from, or
    // stalled on an abandoned surface while backgrounded) and a keyframe
    // can't help it: each one would only be queued, overflow and be dropped
    // again. The gap then doubles up to IDR_REQUEST_MAX_INTERVAL_MS, so the
    // host isn't made to force an IDR every interval; onInputAvailable()
    // resets it. A healthy codec waiting for a keyframe has free buffers, so
    // it keeps the short gap.
    private fun requestIdrThrottled() {
        if (mediaCodec == null) return
        if (SystemClock.elapsedRealtime() - lastIdrRequestMs < idrRetryMs) return
        if (availableInputs.isEmpty() && !inputTakenSinceIdrRequest) {
            idrRetryMs = minOf(idrRetryMs * 2, IDR_REQUEST_MAX_INTERVAL_MS)
        }
        requestIdr()
    }

    @Synchronized
    private fun onInputAvailable(codec: MediaCodec, index: Int) {
        // A callback still in flight from a codec that has since been
        // replaced: its index means nothing to the current one.
        if (codec !== mediaCodec) return
        inputTakenSinceIdrRequest = true
        idrRetryMs = IDR_REQUEST_INTERVAL_MS
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

    /// Top refresh rate this panel supports at its current resolution — sent in
    /// the HELLO so the host's Max preset can target it (e.g. 120 on a 120 Hz
    /// tablet even while the panel is idling at 60).
    @Suppress("DEPRECATION")
    private fun maxRefreshRate(): Int {
        val act = activity ?: return 60
        val display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) act.display
            else act.windowManager.defaultDisplay) ?: return 60
        return display.supportedModes
            .filter { it.physicalWidth == display.mode.physicalWidth }
            .maxOfOrNull { Math.round(it.refreshRate) } ?: 60
    }

    private fun setDisplayRefreshRate(fps: Float) {
        val act = activity ?: return
        act.runOnUiThread {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // API 30+: request exact display mode with target refresh rate
                val display = act.display ?: return@runOnUiThread
                // Slowest mode that still shows every frame (e.g. 45 fps → 60 Hz,
                // 90 → 120), never below 60 Hz: a 30 Hz panel adds a vsync of
                // latency to every frame and to touch feedback. Picking the
                // fastest mode *under* the stream rate dropped 90 fps to 60 Hz
                // and a 30 fps stream took the whole panel down to 30 Hz.
                // Modes report inexact rates (e.g. 120.00001) — hence the 0.5.
                val want = maxOf(fps, 60f)
                val modes = display.supportedModes
                    .filter { it.physicalWidth == display.mode.physicalWidth }
                val targetMode = modes
                    .filter { it.refreshRate >= want - 0.5f }
                    .minByOrNull { it.refreshRate }
                    ?: modes.maxByOrNull { it.refreshRate }
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
        awaitingKeyframe = false
        idrRetryMs = IDR_REQUEST_INTERVAL_MS
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

/// True when [au], one Annex-B access unit, can start decoding on its own: it
/// carries parameter sets (the host prepends them to every keyframe) or an
/// IDR/IRAP slice. Start codes may be 3 or 4 bytes. The scan stops at the
/// first slice, so a non-keyframe costs a few bytes rather than the whole
/// frame. Kept outside the plugin object, with no Android types, so it can be
/// unit-tested on a plain JVM.
internal fun isKeyframeAccessUnit(au: ByteArray, hevc: Boolean): Boolean {
    var i = 0
    while (i + 3 < au.size) {
        if (au[i].toInt() != 0 || au[i + 1].toInt() != 0 || au[i + 2].toInt() != 1) {
            i++
            continue
        }
        val header = au[i + 3].toInt() and 0xFF
        if (hevc) {
            // nal_unit_type is bits 1-6: 32-34 VPS/SPS/PPS, 16-21 IRAP slices
            // (BLA/IDR/CRA); any other type below 32 is a non-IRAP slice.
            val type = (header shr 1) and 0x3F
            if (type in 16..21 || type in 32..34) return true
            if (type < 32) return false
        } else {
            // nal_unit_type is the low 5 bits: 7 SPS, 5 IDR slice; 1-4 are
            // non-IDR slices and slice data partitions.
            val type = header and 0x1F
            if (type == 5 || type == 7) return true
            if (type in 1..4) return false
        }
        i += 4
    }
    return false
}
