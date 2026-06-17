package com.example.extendedscreen.plugins

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.view.Surface

/**
 * Owns the MediaProjection + MediaCodec encoder + VirtualDisplay for reverse
 * remote capture. Runs as a `mediaProjection` foreground service so capture
 * survives the app being backgrounded (Android 14+ requires the FGS type and a
 * running foreground service before `getMediaProjection`).
 *
 * Encoded NAL units are handed to [ScreenCapturePlugin.emitFrame]. The encoder
 * emits SPS/PPS once as a codec-config buffer; we cache it and prepend it to
 * every keyframe so a Mac decoder joining mid-stream can configure itself.
 */
class ScreenCaptureService : Service() {

    companion object {
        private const val NOTIF_ID = 0xE5
        private const val CHANNEL_ID = "extended_screen_capture"

        @Volatile
        private var encoder: MediaCodec? = null

        /** Force the next encoded frame to be a keyframe (IDR). */
        fun requestIdr() {
            try {
                encoder?.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            } catch (_: Exception) {
            }
        }
    }

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var inputSurface: Surface? = null
    private var csd: ByteArray? = null // cached SPS/PPS (Annex-B)

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf(); return START_NOT_STICKY
        }
        startForegroundNotification()

        val resultCode = intent.getIntExtra("resultCode", 0)
        val data = intent.getParcelableExtra<Intent>("data")
        val w = intent.getIntExtra("width", 0)
        val h = intent.getIntExtra("height", 0)
        val codec = intent.getStringExtra("codec") ?: "h264"
        val fps = intent.getIntExtra("fps", 60)
        val bitrate = intent.getIntExtra("bitrate", 12_000_000)

        if (data == null || w <= 0 || h <= 0) {
            stopSelf(); return START_NOT_STICKY
        }
        try {
            startCapture(resultCode, data, w, h, codec, fps, bitrate)
        } catch (e: Exception) {
            android.util.Log.e("ExtendedScreen", "Reverse capture failed", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startCapture(
        resultCode: Int, data: Intent,
        w: Int, h: Int, codec: String, fps: Int, bitrate: Int,
    ) {
        val mime = if (codec == "h265") MediaFormat.MIMETYPE_VIDEO_HEVC
        else MediaFormat.MIMETYPE_VIDEO_AVC

        val format = MediaFormat.createVideoFormat(mime, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            if (Build.VERSION.SDK_INT >= 30) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }

        val enc = MediaCodec.createEncoderByType(mime)
        enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = enc.createInputSurface()
        enc.setCallback(EncoderCallback())
        enc.start()
        encoder = enc

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
        val proj = mpm.getMediaProjection(resultCode, data)
        if (proj == null) {
            stopSelf(); return
        }
        // Android 14+ requires a registered callback before creating displays.
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopSelf()
            }
        }, null)
        projection = proj

        val dpi = resources.displayMetrics.densityDpi
        virtualDisplay = proj.createVirtualDisplay(
            "ExtendedScreenCapture", w, h, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface, null, null,
        )
    }

    private inner class EncoderCallback : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, index: Int) {}

        override fun onOutputBufferAvailable(
            c: MediaCodec, index: Int, info: MediaCodec.BufferInfo,
        ) {
            try {
                val buf = c.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size)
                    buf.get(bytes)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        csd = bytes // SPS/PPS — cache, don't emit on its own
                    } else {
                        val keyframe =
                            info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                        val sps = csd
                        if (keyframe && sps != null) {
                            ScreenCapturePlugin.emitFrame(sps + bytes)
                        } else {
                            ScreenCapturePlugin.emitFrame(bytes)
                        }
                    }
                }
                c.releaseOutputBuffer(index, false)
            } catch (_: Exception) {
            }
        }

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {}

        override fun onOutputFormatChanged(c: MediaCodec, f: MediaFormat) {}
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notif: Notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen Capture",
                    NotificationManager.IMPORTANCE_LOW))
            notif = Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Extended Screen")
                .setContentText("Sharing this screen to your Mac")
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .build()
        } else {
            @Suppress("DEPRECATION")
            notif = Notification.Builder(this)
                .setContentTitle("Extended Screen")
                .setContentText("Sharing this screen to your Mac")
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .build()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    override fun onDestroy() {
        try { virtualDisplay?.release() } catch (_: Exception) {}
        try { encoder?.stop(); encoder?.release() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        virtualDisplay = null
        inputSurface = null
        encoder = null
        projection = null
        csd = null
        super.onDestroy()
    }
}
