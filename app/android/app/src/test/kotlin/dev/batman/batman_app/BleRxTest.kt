package dev.batman.batman_app

import com.polidea.rxandroidble2.exceptions.BleDisconnectedException
import io.reactivex.exceptions.UndeliverableException
import io.reactivex.plugins.RxJavaPlugins
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.atomic.AtomicReference

/**
 * 254-app-update v0.4.3: a BLE disconnect delivered too late (the node rebooted after update/apply) must not kill the
 * app; any other late error still reaches the thread's uncaught handler (the crash path), as without the handler.
 * Negative control: [withoutTheHandlerTheDisconnectReachesTheCrashPath] — RxJava's default sends it there.
 */
class BleRxTest {
    @After fun reset() = RxJavaPlugins.reset()

    /** RxJavaPlugins.onError(e) on a thread whose uncaught handler records what reaches it (the process-killing path) */
    private fun deliverLate(e: Throwable): Throwable? {
        val crashed = AtomicReference<Throwable?>()
        val t = Thread { RxJavaPlugins.onError(e) }
        t.uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, x -> crashed.set(x) }
        t.start(); t.join(5_000)
        return crashed.get()
    }

    private fun disconnect() = UndeliverableException(BleDisconnectedException("AA:BB:CC:DD:EE:FF", 0))

    @Test fun theLateDisconnectIsSwallowedWithAFixedLine() {
        val lines = mutableListOf<String>()
        BleRx.install { lines.add(it) }
        assertEquals(null, deliverLate(disconnect()))
        assertEquals(null, deliverLate(UndeliverableException(IOException("x"))))
        assertEquals(null, deliverLate(UndeliverableException(InterruptedException())))
        assertEquals(listOf(BleRx.LINE, BleRx.LINE, BleRx.LINE), lines)
        assertTrue("no MAC in the line", lines.none { it.contains("AA:BB") })
    }

    @Test fun anythingElseStillReachesTheCrashPath() {
        BleRx.install { }
        val bug = UndeliverableException(IllegalStateException("a real bug"))
        assertEquals(bug, deliverLate(bug))
        val plain = IllegalArgumentException("not undeliverable")
        assertEquals(plain, deliverLate(plain))
    }

    @Test fun withoutTheHandlerTheDisconnectReachesTheCrashPath() {
        // what the app did before v0.4.3: RxJava's default handler -> the thread's uncaught handler (the process dies)
        RxJavaPlugins.reset()
        val e = disconnect()
        assertEquals(e, deliverLate(e))
    }
}
