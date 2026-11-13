package dev.batman.batman_app

import com.polidea.rxandroidble2.exceptions.BleException
import io.reactivex.exceptions.UndeliverableException
import io.reactivex.functions.Consumer
import io.reactivex.plugins.RxJavaPlugins
import java.io.IOException

/**
 * 254-app-update v0.4.3 (04 + S20, T11 apply): the node reboots after update/apply, the BLE link drops, and
 * RxAndroidBle (under reactive_ble_mobile) delivers the disconnect to a subscriber that is already gone. RxJava then
 * routes an UndeliverableException to RxJavaPlugins' default handler, which hands it to the thread's uncaught handler
 * and the process dies (logcat: "The exception could not be delivered to the consumer because it has already
 * canceled/disposed the flow … Caused by: BleDisconnectedException … status 0").
 * The handler RxAndroidBle's README recommends ("Error handling": ignore an UndeliverableException whose cause is a
 * BleException — it was delivered at least once — and treat anything else as a crash), plus RxJava 2's wiki list of
 * benign late errors (IOException, InterruptedException). Anything else goes to the thread's uncaught handler as
 * before (a real bug still crashes). Plain JVM (no android.*): the JVM test drives it.
 */
object BleRx {
    /** the fixed, non-secret line for a swallowed late error (the exception's message carries the node's MAC) */
    const val LINE = "BMAPP rx: a BLE / IO error after its subscriber was gone (ignored)"

    fun swallowed(e: Throwable): Boolean {
        if (e !is UndeliverableException) return false
        val c = e.cause
        return c is BleException || c is IOException || c is InterruptedException
    }

    fun handler(log: (String) -> Unit): Consumer<Throwable> = Consumer { e ->
        if (swallowed(e)) {
            log(LINE)
        } else {
            val t = Thread.currentThread()
            val h = t.uncaughtExceptionHandler
            if (h != null) h.uncaughtException(t, e) else throw e
        }
    }

    /** Before the Flutter engine starts any BLE work (MainActivity.onCreate). */
    fun install(log: (String) -> Unit) = RxJavaPlugins.setErrorHandler(handler(log))
}
