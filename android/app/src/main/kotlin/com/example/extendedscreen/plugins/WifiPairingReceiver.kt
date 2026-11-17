package com.example.extendedscreen.plugins

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Where what the Mac hands this app through adb arrives: its Wi-Fi pairing
 * (certificate and token), and the key of each USB session.
 *
 *     adb shell am broadcast -n com.example.extendedscreen/.plugins.WifiPairingReceiver \
 *         -a com.example.extendedscreen.WIFI_PAIR --es payload <base64url>
 *     adb shell am broadcast -n com.example.extendedscreen/.plugins.WifiPairingReceiver \
 *         -a com.example.extendedscreen.USB_SESSION --es payload <base64url>
 *
 * The manifest requires the sender to hold android.permission.DUMP. The shell
 * holds it; an installed app cannot, unless the user granted it through adb
 * (`pm grant`), which takes the same access a pairing does. So what arrives
 * here came from a computer the user let debug this tablet, and not from
 * another app on it. (androidx.profileinstaller guards its receiver the same
 * way.) Both actions are listed in the manifest's intent filter: since
 * Android 13 an intent that matches none of an exported component's filters
 * is not delivered, even when it names the component.
 *
 * The payload goes to the Dart side, which decides (WifiPairingChannel →
 * WifiPairingService.storePairing, or UsbSessionService.accept). The result
 * code tells the Mac what happened; it shows in `am broadcast`'s output. 0,
 * the default, means nobody took it: no engine is running, or Dart has no
 * handler.
 */
class WifiPairingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val method = when (intent.action) {
            ACTION -> "pair"
            ACTION_USB_SESSION -> "usbSession"
            else -> return
        }
        val encoded = intent.getStringExtra(EXTRA_PAYLOAD) ?: return
        if (encoded.length > MAX_ENCODED_LENGTH) return
        val ordered = isOrderedBroadcast
        val payload = try {
            Base64.decode(encoded, Base64.URL_SAFE)
        } catch (e: IllegalArgumentException) {
            if (ordered) resultCode = RESULT_REFUSED
            return
        }
        val channel = WifiPairingPlugin.channel ?: return
        // Dart answers after it has saved the pairing, or taken the key.
        val pending = goAsync()
        fun finish(code: Int) {
            if (ordered) pending.resultCode = code
            pending.finish()
        }
        channel.invokeMethod(method, payload, object : MethodChannel.Result {
            override fun success(result: Any?) =
                finish(if (result == true) RESULT_STORED else RESULT_REFUSED)

            override fun error(code: String, message: String?, details: Any?) =
                finish(RESULT_REFUSED)

            override fun notImplemented() = finish(RESULT_NOT_TAKEN)
        })
    }

    companion object {
        const val ACTION = "com.example.extendedscreen.WIFI_PAIR"
        const val ACTION_USB_SESSION = "com.example.extendedscreen.USB_SESSION"
        const val EXTRA_PAYLOAD = "payload"

        // Mirrored by AdbDelivery in adb_service.dart.
        const val RESULT_NOT_TAKEN = 0
        const val RESULT_STORED = 1
        const val RESULT_REFUSED = 2

        // A pairing is about 1.5 KB of base64.
        private const val MAX_ENCODED_LENGTH = 16 * 1024
    }
}

/**
 * The channel [WifiPairingReceiver] reaches the Dart side on. It exists only
 * while MainActivity's engine does. A pairing that arrives with no engine
 * running is dropped, and the Mac offers it again on its next USB session; a
 * USB session key is handed over again when the app, once open, dials the
 * Mac without it.
 */
object WifiPairingPlugin {
    private const val CHANNEL = "extended_screen/wifi_pairing"

    @Volatile
    var channel: MethodChannel? = null
        private set

    // The activity whose engine [channel] talks to. Main thread only.
    private var owner: Activity? = null

    fun register(engine: FlutterEngine, activity: Activity) {
        owner = activity
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
    }

    /**
     * [activity]'s engine is going away: a message sent to it now is never
     * answered. Only that activity's channel is dropped. A finished activity
     * can be destroyed after its replacement has registered (Back on Home,
     * then the app reopened at once), and clearing the replacement's channel
     * would leave the open app deaf to adb: no USB session key, ever, until
     * it is closed again (ScreenCapturePlugin guards the same way).
     */
    fun onHostDestroyed(activity: Activity) {
        if (owner !== activity) return
        owner = null
        channel = null
    }
}
