package com.example.extendedscreen.plugins

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Lightweight keep-alive foreground service for the CLIENT (extended-screen
 * decode) side. It does no work of its own — the TCP socket, heartbeat loop and
 * H.264/H.265 decoder all live in the Dart isolate. Its sole purpose is to hold
 * the whole process at foreground priority while the link is up, so Android's
 * cached-app freezer won't freeze it and then kill it with "Sync transaction
 * while frozen" the moment a memory-hungry foreground app (e.g. a game) shows up
 * — which would otherwise drop the stream when the tablet is backgrounded.
 *
 * Declared as a `connectedDevice` FGS (the USB-connected Mac), which — unlike
 * `dataSync` — has no per-day runtime cap on Android 15+.
 */
class ClientKeepAliveService : Service() {

    companion object {
        private const val NOTIF_ID = 0xE6
        private const val CHANNEL_ID = "extended_screen_client"

        /** Start (or no-op if already running) the keep-alive service. */
        fun start(context: Context) {
            val intent = Intent(context, ClientKeepAliveService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Background-start restrictions (Android 12+) can reject this if
                // we ever try to (re)start while backgrounded; the link keeps
                // running unprotected in that case rather than crashing.
                android.util.Log.w("ExtendedScreen", "keep-alive start rejected", e)
            }
        }

        /** Stop the keep-alive service (link torn down). */
        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ClientKeepAliveService::class.java))
            } catch (_: Exception) {
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundNotification()
        // If the process is killed anyway, don't resurrect a workless service —
        // the Dart side would be gone too.
        return START_NOT_STICKY
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        val notif: Notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Extended Screen",
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
            notif = Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Extended Screen")
                .setContentText("Connected to your Mac")
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setOngoing(true)
                .apply { contentIntent?.let { setContentIntent(it) } }
                .build()
        } else {
            @Suppress("DEPRECATION")
            notif = Notification.Builder(this)
                .setContentTitle("Extended Screen")
                .setContentText("Connected to your Mac")
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setOngoing(true)
                .apply { contentIntent?.let { setContentIntent(it) } }
                .build()
        }

        // The connectedDevice FGS type (and the matching manifest attribute)
        // only exist on API 30+. Below that, run as a plain foreground service.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(
                NOTIF_ID, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }
}
