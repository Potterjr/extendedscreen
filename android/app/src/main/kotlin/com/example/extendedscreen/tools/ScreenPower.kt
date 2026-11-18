package com.example.extendedscreen.tools

import android.annotation.SuppressLint
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.system.Os
import java.lang.reflect.Method
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * Turns the tablet's panel off, or back on, while the display keeps running:
 * the screen goes dark, yet everything still renders (so MediaProjection keeps
 * sending the picture to the Mac) and input still lands. The same thing
 * scrcpy does for --turn-screen-off.
 *
 * Not part of the app at run time: the Mac starts it through adb, with the
 * shell's privileges, as
 * `CLASSPATH=<this app's APK> app_process / com.example.extendedscreen.tools.ScreenPower <command>`.
 * It touches hidden platform APIs, by reflection, which only a process with
 * those privileges may call. No Android Context, no Flutter, nothing else of
 * the app's.
 *
 * - `hold`: the panel goes off and stays off while the Mac keeps renewing
 *   its lease. It prints `ok off …` once the panel is off, then reads lines
 *   on its standard input: `keep` renews the lease, `off` turns the panel off
 *   again and renews it too, `on` turns the panel back on and ends it. So
 *   does the end of the input, and so does a lease left to run out
 *   ([LEASE_MS]): that is what the Mac app dying, the cable coming out, adb
 *   going away or the Mac going to sleep look like from here, and the end of
 *   the input alone is not enough (killing the Mac's adb process leaves this
 *   one's input open). Nor is anything this process does: when the Mac's side
 *   of adb goes away, adbd kills it outright (SIGHUP, which runs no shutdown
 *   hook). So before the panel goes off it starts a watchdog, `watch`: a
 *   process of its own (setsid), out of adbd's reach, told over a pipe
 *   whether the panel is off, which puts the panel back on when that pipe
 *   ends with it still off: when `hold` dies, however it dies. Meanwhile
 *   `hold` reports user activity every few seconds, or Android lets the
 *   device go idle, and a mirror of an idle display can go black after a
 *   few seconds with the panel off (scrcpy's --keep-active). It ends by
 *   itself if the tablet goes to sleep all the same, or wakes up: its power
 *   button puts it to sleep (unseen, the panel being dark) and the next press
 *   wakes it, which lights the panel. From Android 16 the lock screen that
 *   follows a sleep stops the screen capture, a device someone put to sleep
 *   must not be kept awake, and a lit one must not be kept from timing out.
 * - `on`: lights the panel once, then exits (by hand, should one ever stay
 *   dark). `probe`: prints what this device offers.
 * - `watch`: the watchdog above; not for the Mac to call.
 *
 * It changes no setting, so nothing outlives it: if both processes are
 * killed (USB debugging turned off), the tablet times out as usual and its
 * power button brings it back lit.
 *
 * Every line it prints starts with `ok`, `warn` or `error`.
 *
 * The lint checks on non-SDK interfaces are about an app's own process, where
 * the runtime blocks them; app_process started from the shell is not one.
 */
@SuppressLint("BlockedPrivateApi", "PrivateApi", "DiscouragedPrivateApi", "SoonBlockedPrivateApi")
object ScreenPower {
    // SurfaceControl.POWER_MODE_*.
    private const val POWER_MODE_OFF = 0
    private const val POWER_MODE_NORMAL = 2

    /** How often `hold` reports user activity (scrcpy uses 4 s too). */
    private const val KEEP_ACTIVE_MS = 4_000L

    /**
     * How long `hold` keeps the panel off without hearing from the Mac. The
     * Mac renews every 2 s; a few late renewals must not light the panel.
     */
    private const val LEASE_MS = 10_000L

    /**
     * How often `hold` checks that the tablet has not slept since the panel
     * went off: often enough to see the sleep between two quick presses of
     * the power button, the second of which wakes it and lights the panel.
     */
    private const val WAKE_CHECK_MS = 100L

    /**
     * How long the panel waits to be lit again for an asleep tablet to wake.
     * A tablet woken again within a moment of going to sleep (a second press
     * of the power button) is not lit by Android: the panel's own switch to
     * off had not happened yet, so nothing switches it back on. One asleep
     * longer than this has been switched off by Android, and its wake-up
     * lights the panel.
     */
    private const val ASLEEP_WAIT_MS = 5_000L

    /** How long `hold` waits for its watchdog to be ready before giving up. */
    private const val WATCHDOG_READY_MS = 5_000L

    @JvmStatic
    fun main(args: Array<String>) {
        // Always System.exit, never a return from main: a process that loaded
        // libandroid_servers crashes in its shutdown thread otherwise.
        val code = try {
            when (args.firstOrNull()) {
                "hold" -> hold()
                "watch" -> watch()
                "on" -> { say("ok on displays=${Panel.find().set(true)}"); 0 }
                "probe" -> { probe(); 0 }
                else -> { say("error: usage: hold | on | probe"); 2 }
            }
        } catch (t: Throwable) {
            say("error: ${describe(t)}")
            1
        }
        System.exit(code)
    }

    private fun say(line: String) {
        println(line)
        System.out.flush()
    }

    private fun hold(): Int {
        // Out of the adb shell's session, so that a device which kills the
        // session's processes when adb lets go still leaves this one to see
        // its input end and put the panel back on.
        try {
            Os.setsid()
        } catch (_: Throwable) {
            // Already a session leader, or not allowed: carry on.
        }
        // Everything found before the panel is touched: any failure here
        // (a native abort loading DisplayControl's library included) leaves
        // it as it was.
        val panel = Panel.find()
        val power = try {
            Power.find()
        } catch (t: Throwable) {
            say("warn: no power manager: ${describe(t)}")
            null
        }
        if (power?.interactive() == false) {
            throw IllegalStateException("the tablet is asleep")
        }
        // Ready before the panel goes off: without it, nothing would put the
        // panel back on if this process were killed.
        val watchdog = startWatchdog()
        fun tellWatchdog(off: Boolean) {
            try {
                watchdog.outputStream.write(if (off) '1'.code else '0'.code)
                watchdog.outputStream.flush()
            } catch (_: Throwable) {
            }
        }
        fun closeWatchdog() {
            try {
                watchdog.outputStream.close()
            } catch (_: Throwable) {
            }
        }

        tellWatchdog(true)
        val displays = try {
            panel.set(false)
        } catch (t: Throwable) {
            // Possibly part-way: some displays off. The watchdog lights them.
            closeWatchdog()
            throw t
        }
        say("ok off displays=$displays sdk=${Build.VERSION.SDK_INT}")

        val ended = AtomicBoolean(false)
        val done = CountDownLatch(1)
        try {
            val renewedAt = AtomicLong(SystemClock.elapsedRealtime())
            if (power != null) {
                thread(isDaemon = true, name = "keep-active") {
                    var reported = false
                    while (!ended.get()) {
                        try {
                            power.userActivity()
                        } catch (t: Throwable) {
                            if (!reported) say("warn: no user activity: ${describe(t)}")
                            reported = true
                        }
                        SystemClock.sleep(KEEP_ACTIVE_MS)
                    }
                }
                // A sleep is seen while it lasts. One too short for that (two
                // quick presses) still leaves a trace: the time of the last
                // wake-up, where the device reports it, or the lock screen,
                // which Android shows on waking.
                val wokeAt = power.lastWakeTime()
                val keyguard = Keyguard.find()
                val lockedAtStart = keyguard?.locked()
                thread(isDaemon = true, name = "wake-watch") {
                    while (!ended.get()) {
                        SystemClock.sleep(WAKE_CHECK_MS)
                        if (power.interactive() == false) {
                            say("warn: the tablet went to sleep")
                            break
                        }
                        val now = power.lastWakeTime()
                        if (wokeAt != null && now != null && now != wokeAt) {
                            say("warn: the tablet woke up")
                            break
                        }
                        if (lockedAtStart == false && keyguard.locked() == true) {
                            say("warn: the tablet locked")
                            break
                        }
                    }
                    done.countDown()
                }
            }
            // The lease: renewed by every line from the Mac, checked once a second.
            thread(isDaemon = true, name = "lease") {
                while (!ended.get()) {
                    SystemClock.sleep(1_000)
                    if (SystemClock.elapsedRealtime() - renewedAt.get() > LEASE_MS) {
                        say("warn: lease ran out")
                        break
                    }
                }
                done.countDown()
            }
            thread(isDaemon = true, name = "input") {
                val input = System.`in`.bufferedReader()
                while (true) {
                    val line = try {
                        input.readLine()
                    } catch (_: Throwable) {
                        null
                    } ?: break
                    renewedAt.set(SystemClock.elapsedRealtime())
                    when (line.trim()) {
                        "on" -> break
                        "off" -> try {
                            panel.set(false)
                            say("ok off")
                        } catch (t: Throwable) {
                            say("error: ${describe(t)}")
                        }
                    }
                }
                done.countDown()
            }
            // Whichever comes first: `on`, the end of the input, the lease,
            // or the tablet going to sleep.
            done.await()
        } finally {
            ended.set(true)
            try {
                say(if (panel.lightWhenAwake(power)) "ok on" else "ok asleep")
                tellWatchdog(false)
            } catch (t: Throwable) {
                // The watchdog, still told the panel is off, tries again.
                say("error: restoring the panel: ${describe(t)}")
            }
            closeWatchdog()
        }
        return 0
    }

    /**
     * This same class, run again by app_process as `watch`, in its own
     * session. Returns once it has said it is ready to light the panel.
     */
    private fun startWatchdog(): Process {
        val classPath = System.getProperty("java.class.path")
            ?: throw IllegalStateException("no class path")
        val builder = ProcessBuilder(
            "/system/bin/app_process", "/", ScreenPower::class.java.name, "watch")
        builder.environment()["CLASSPATH"] = classPath
        // Nothing of adbd's: its pipes close, or are gone, when it kills `hold`.
        builder.redirectError(java.io.File("/dev/null"))
        val watchdog = builder.start()
        val answer = AtomicReference<String?>()
        val answered = CountDownLatch(1)
        thread(isDaemon = true, name = "watchdog-ready") {
            answer.set(try {
                watchdog.inputStream.bufferedReader().readLine()
            } catch (_: Throwable) {
                null
            })
            answered.countDown()
        }
        if (!answered.await(WATCHDOG_READY_MS, TimeUnit.MILLISECONDS) ||
            answer.get() != "ready"
        ) {
            watchdog.destroy()
            throw IllegalStateException(
                "the watchdog did not start (${answer.get() ?: "no answer"})")
        }
        return watchdog
    }

    /**
     * The watchdog: reads one byte per change from `hold` ('1' panel off, '0'
     * panel back on) and, when its input ends with the panel still off, puts
     * it back on. Finds the panel first, so that the restore needs nothing
     * that could fail, and says `ready` once it has.
     */
    private fun watch(): Int {
        try {
            Os.setsid()
        } catch (_: Throwable) {
        }
        val panel = Panel.find()
        val power = try {
            Power.find()
        } catch (_: Throwable) {
            null
        }
        say("ready")
        var off = false
        while (true) {
            val b = try {
                System.`in`.read()
            } catch (_: Throwable) {
                -1
            }
            if (b == -1) break
            if (b == '1'.code) off = true
            if (b == '0'.code) off = false
        }
        if (off) panel.lightWhenAwake(power)
        return 0
    }

    /** Every physical display, found once, and the call that powers them. */
    private class Panel(private val tokens: List<IBinder>, private val setMode: Method) {
        /** Sets every physical display's power mode. Returns how many. */
        fun set(on: Boolean): Int {
            for (token in tokens) {
                setMode.invoke(null, token, if (on) POWER_MODE_NORMAL else POWER_MODE_OFF)
            }
            return tokens.size
        }

        /**
         * Lights the panel, at once if the tablet is awake, else as soon as it
         * wakes within [ASLEEP_WAIT_MS] (never while it sleeps: a panel lit
         * then stays black, scrcpy #1667). Returns false if it slept on: its
         * own wake-up lights the panel then.
         */
        fun lightWhenAwake(power: Power?): Boolean {
            val until = SystemClock.elapsedRealtime() + ASLEEP_WAIT_MS
            while (power?.interactive() == false) {
                if (SystemClock.elapsedRealtime() > until) return false
                SystemClock.sleep(WAKE_CHECK_MS)
            }
            set(true)
            return true
        }

        companion object {
            fun find(): Panel {
                val surfaceControl = Class.forName("android.view.SurfaceControl")
                val setMode = surfaceControl.getMethod(
                    "setDisplayPowerMode", IBinder::class.java, Int::class.javaPrimitiveType)
                val tokens = physicalDisplayTokens(surfaceControl)
                if (tokens.isEmpty()) throw IllegalStateException("no physical display token")
                return Panel(tokens, setMode)
            }
        }
    }

    private fun physicalDisplayTokens(surfaceControl: Class<*>): List<IBinder> {
        // Up to Android 13 SurfaceControl has them itself (and some builds
        // after that still do). Tried first: it needs no native library.
        tokensFrom(surfaceControl)?.let { if (it.isNotEmpty()) return it }
        // From Android 14 they moved to DisplayControl, in the system server.
        if (Build.VERSION.SDK_INT >= 34) {
            tokensFrom(displayControl())?.let { if (it.isNotEmpty()) return it }
        }
        // Older still: the one built-in display.
        return try {
            listOfNotNull(surfaceControl.getMethod("getInternalDisplayToken")
                .invoke(null) as IBinder?)
        } catch (_: NoSuchMethodException) {
            emptyList()
        }
    }

    private fun tokensFrom(holder: Class<*>): List<IBinder>? {
        val ids: Method
        val token: Method
        try {
            ids = holder.getMethod("getPhysicalDisplayIds")
            token = holder.getMethod("getPhysicalDisplayToken", Long::class.javaPrimitiveType)
        } catch (_: NoSuchMethodException) {
            return null
        }
        val list = ids.invoke(null) as LongArray
        return list.toList().mapNotNull { token.invoke(null, it) as IBinder? }
    }

    /**
     * com.android.server.display.DisplayControl, with its native library.
     * Loaded with the whole system server class path, as scrcpy does since
     * 3.1: with services.jar alone the library's JNI_OnLoad cannot find
     * vendor classes on some devices and aborts the process.
     */
    private fun displayControl(): Class<*> {
        val factory = Class.forName("com.android.internal.os.ClassLoaderFactory")
        val create = factory.getDeclaredMethod(
            "createClassLoader",
            String::class.java, String::class.java, String::class.java,
            ClassLoader::class.java, Int::class.javaPrimitiveType,
            Boolean::class.javaPrimitiveType, String::class.java)
        val classPath = Os.getenv("SYSTEMSERVERCLASSPATH")?.takeIf { it.isNotEmpty() }
            ?: "/system/framework/services.jar"
        val loader = create.invoke(
            null, classPath, null, null,
            ClassLoader.getSystemClassLoader(), 0, true, null) as ClassLoader
        val cls = loader.loadClass("com.android.server.display.DisplayControl")
        val load = Runtime::class.java.getDeclaredMethod(
            "loadLibrary0", Class::class.java, String::class.java)
        load.isAccessible = true
        load.invoke(Runtime.getRuntime(), cls, "android_servers")
        return cls
    }

    /** PowerManager, as the shell (which holds DEVICE_POWER) may use it. */
    private class Power(private val service: Any) {
        private val isInteractive: Method? = try {
            if (Build.VERSION.SDK_INT >= 34) {
                service.javaClass.getMethod("isDisplayInteractive", Int::class.javaPrimitiveType)
            } else {
                service.javaClass.getMethod("isInteractive")
            }
        } catch (_: NoSuchMethodException) {
            try {
                service.javaClass.getMethod("isInteractive")
            } catch (_: NoSuchMethodException) {
                null
            }
        }

        private val activity: Method? =
            service.javaClass.methods.firstOrNull { it.name == "userActivity" }

        private val lastWakeup: Method? = service.javaClass.methods
            .firstOrNull { it.name == "getLastWakeup" && it.parameterTypes.isEmpty() }

        /**
         * When the device last woke up (PowerManager.WakeData.wakeTime), or
         * null where the platform does not say.
         */
        fun lastWakeTime(): Long? = try {
            val data = lastWakeup?.invoke(service)
            data?.javaClass?.getField("wakeTime")?.getLong(data)
        } catch (_: Throwable) {
            null
        }

        fun methodsLike(vararg words: String): String = methodsLike(service.javaClass, *words)

        /** Awake (true), asleep (false), or unknown (null). */
        fun interactive(): Boolean? = try {
            val method = isInteractive
            when {
                method == null -> null
                method.parameterTypes.isEmpty() -> method.invoke(service) as Boolean
                else -> method.invoke(service, 0) as Boolean
            }
        } catch (_: Throwable) {
            null
        }

        /**
         * Reports user activity, as a touch would: the device neither sleeps
         * nor goes idle. USER_ACTIVITY_EVENT_OTHER, no flags.
         */
        fun userActivity() {
            val method = activity ?: throw NoSuchMethodException("userActivity")
            when (method.parameterTypes.size) {
                // displayId, time, event, flags (Android 12, API 31, and later).
                4 -> method.invoke(service, 0, SystemClock.uptimeMillis(), 0, 0)
                // time, event, flags.
                3 -> method.invoke(service, SystemClock.uptimeMillis(), 0, 0)
                else -> throw NoSuchMethodException(
                    "userActivity${method.parameterTypes.toList()}")
            }
        }

        companion object {
            fun find(): Power {
                val binder = Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String::class.java)
                    .invoke(null, "power") as IBinder
                val service = Class.forName("android.os.IPowerManager\$Stub")
                    .getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
                return Power(service)
            }
        }
    }

    /** The window manager's view of the lock screen. */
    private class Keyguard(private val service: Any, private val isLocked: Method) {
        /** Showing (true), not (false), or unknown (null). */
        fun locked(): Boolean? = try {
            isLocked.invoke(service) as Boolean
        } catch (_: Throwable) {
            null
        }

        companion object {
            fun find(): Keyguard? = try {
                val binder = Class.forName("android.os.ServiceManager")
                    .getMethod("getService", String::class.java)
                    .invoke(null, "window") as IBinder
                val service = Class.forName("android.view.IWindowManager\$Stub")
                    .getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
                Keyguard(service, service.javaClass.getMethod("isKeyguardLocked"))
            } catch (_: Throwable) {
                null
            }
        }
    }

    private fun probe() {
        say("ok sdk=${Build.VERSION.SDK_INT} release=${Build.VERSION.RELEASE} " +
            "maker=${Build.MANUFACTURER}")
        val sc = Class.forName("android.view.SurfaceControl")
        say("ok SurfaceControl: " + methodsLike(sc, "Power", "PhysicalDisplay", "InternalDisplay"))
        if (Build.VERSION.SDK_INT >= 34) {
            say("ok SYSTEMSERVERCLASSPATH set: ${!Os.getenv("SYSTEMSERVERCLASSPATH").isNullOrEmpty()}")
            try {
                val dc = displayControl()
                say("ok DisplayControl: " + methodsLike(dc, "Power", "PhysicalDisplay"))
            } catch (t: Throwable) {
                say("warn: DisplayControl unavailable (${describe(t)})")
            }
        }
        try {
            say("ok tokens: ${physicalDisplayTokens(sc).size}")
        } catch (t: Throwable) {
            say("error: tokens (${describe(t)})")
        }
        try {
            val power = Power.find()
            say("ok PowerManager: " + power.methodsLike("Interactive", "Last", "Wake"))
            say("ok interactive: ${power.interactive()} last wake: ${power.lastWakeTime()} " +
                "keyguard locked: ${Keyguard.find()?.locked()}")
            power.userActivity()
            say("ok userActivity")
        } catch (t: Throwable) {
            say("warn: power manager (${describe(t)})")
        }
    }

    private fun methodsLike(cls: Class<*>, vararg words: String): String =
        cls.declaredMethods
            .filter { m -> words.any { m.name.contains(it) } }
            .map { m -> "${m.name}(${m.parameterTypes.joinToString(",") { it.simpleName }})" }
            .distinct()
            .sorted()
            .joinToString(" ")

    private fun describe(t: Throwable): String {
        var e: Throwable = t
        while (e.cause != null && e is java.lang.reflect.InvocationTargetException) {
            e = e.cause!!
        }
        return "${e.javaClass.simpleName}: ${e.message}"
    }
}
