package dev.batman.batman_app.swupd

import android.net.ConnectivityManager
import android.os.Build
import android.os.Bundle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.batman.batman_app.MainActivity
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.net.ConnectException
import java.net.InetSocketAddress

/**
 * 254-app-update v0.4 §8 T9 (D5 on the real S20 with a bench node; WRITTEN, NOT RUN — needs the phone, a node whose
 * phone AP is on, and a person to answer the system dialog). One arm per run, chosen with `-e arm <x>`:
 *   ./gradlew :app:connectedDevDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=dev.batman.batman_app.swupd.SwNetDeviceTest \
 *     -Pandroid.testInstrumentationRunnerArguments.arm=a -Pandroid.testInstrumentationRunnerArguments.nodeIp=<node AP IP>
 * Arguments: arm, nodeIp, and for b / c / f / g the bench AP's ssid and pass (a bench test value only; it shows in the
 * instrumentation command line — never a field passphrase). Every run reports the Android version (§6: 12 / 12L ⚠️).
 * Arms:
 *   a  phone already on the node's AP: findDirect finds it, no dialog, activeNetwork unchanged; first connect time
 *      recorded (§10-16). Negative control: `-e mutant alwaysSpecifier` makes the arm go through join() -> the system
 *      dialog appears and activeNetwork changes -> the arm FAILs.
 *   b  phone not on the AP: findDirect finds nothing; join() with the dialog accepted -> "ok"; a TCP connect to
 *      nodeIp:8095 over the joined Network reaches the node (connected or refused); release() afterwards.
 *   c  as b, the person refuses the dialog -> "no_network" (refused and timed out are not told apart, r1 B-m5).
 *   e  as b a second time: either no dialog or a dialog (STA+STA phones); both accepted — the person notes which.
 *   f  phone on the same SSID with the direct route forced off (`-e mutant alwaysSpecifier`): join() -> "ok"; the
 *      person counts the Wi-Fi drops (expected 2: on join and on release, F25).
 *   g  phone on another AP: findDirect finds nothing -> join() as b.
 *   i  (code review r1 A-M2 / B-M1) as b, then a second join() in the same stage -> the same Network, no new dialog,
 *      held() is that Network; the person counts the Wi-Fi drops for the whole arm (expected 2, not 4). Negative
 *      control: `-e mutant rejoin` releases before the second join -> a second dialog / two more drops -> FAIL.
 *   d / h (Wi-Fi off; app killed during the Specifier) are by hand: d expects "no_network" + the panel text,
 *      h expects the phone back on its previous Wi-Fi ⚠️. After b–g: system settings show no saved network (F25).
 * Every Specifier arm then greps logcat for the passphrase -> 0 hits (D8).
 */
@RunWith(AndroidJUnit4::class)
class SwNetDeviceTest {
    private val args: Bundle = InstrumentationRegistry.getArguments()
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private val cm = ctx.getSystemService(ConnectivityManager::class.java)
    private val ip = args.getString("nodeIp")?.let(SwPut::ipv4)
    private val alwaysSpecifier = args.getString("mutant") == "alwaysSpecifier"

    private fun arm(a: String) {
        assumeTrue("arm $a not selected", args.getString("arm") == a)
        assertNotNull("-e nodeIp <IPv4> is required", ip)
        report("android", "${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}) ${Build.MODEL}")
    }

    private fun report(k: String, v: String) =
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString(k, v) })

    // the node answered: connected, or refused (provd not bound yet, F13) — both mean the packets reached it
    private fun reaches(net: android.net.Network): Boolean {
        val s = net.socketFactory.createSocket()
        return try { s.connect(InetSocketAddress(ip, 8095), 3_000); true } catch (e: ConnectException) { true } catch (e: IOException) { false } finally { SwPut.hardClose(s) }
    }

    private fun noPassInLogcat(pass: String) {
        val ui = InstrumentationRegistry.getInstrumentation().uiAutomation
        val log = android.os.ParcelFileDescriptor.AutoCloseInputStream(ui.executeShellCommand("logcat -d")).use { it.readBytes().toString(Charsets.UTF_8) }
        assertTrue("logcat is empty: nothing was checked", log.length > 1000)
        assertFalse("the passphrase is in logcat", log.contains(pass))
    }

    private fun joined(expect: String) {
        val ssid = requireNotNull(args.getString("ssid")) { "-e ssid" }; val pass = requireNotNull(args.getString("pass")) { "-e pass" }
        // only a foreground app may request a Specifier network (F25): the app's activity is up for the whole arm
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val net = SwNet(ctx) { }
        try {
            if (!alwaysSpecifier) assertNull("the phone is already on the node's AP: this arm needs it elsewhere", net.findDirect(ip!!))
            val (answer, n) = net.join(ssid, pass)
            assertEquals(expect, answer)
            if (expect == "ok") assertTrue("the joined network does not reach the node", reaches(n!!))
        } finally {
            net.dispose()
            scenario.close()
        }
        noPassInLogcat(pass)
    }

    @Test fun a_alreadyOnNodeAp() {
        arm("a")
        val scenario = ActivityScenario.launch(MainActivity::class.java) // foreground, as in the app (and for the mutant's join)
        val before = cm.activeNetwork
        val net = SwNet(ctx) { }
        try {
            val n = if (alwaysSpecifier) net.join(args.getString("ssid")!!, args.getString("pass")!!).second else net.findDirect(ip!!)
            assertNotNull("no direct route to the node: the phone is not on its AP", n)
            val t0 = System.nanoTime()
            assertTrue("the node is not reached over the direct network", reaches(n!!))
            report("firstConnectMs", "${(System.nanoTime() - t0) / 1_000_000}")
            assertEquals("activeNetwork changed (a dialog / switch happened)", before, cm.activeNetwork)
        } finally {
            net.dispose()
            scenario.close()
        }
    }

    @Test fun i_secondJoinOfTheStageKeepsTheNetwork() {
        arm("i")
        val ssid = requireNotNull(args.getString("ssid")) { "-e ssid" }; val pass = requireNotNull(args.getString("pass")) { "-e pass" }
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        val net = SwNet(ctx) { }
        try {
            val (a1, n1) = net.join(ssid, pass)
            assertEquals("ok", a1)
            assertEquals("held() is the joined network", n1, net.held())
            if (args.getString("mutant") == "rejoin") net.release()
            val t0 = System.nanoTime()
            val (a2, n2) = net.join(ssid, pass)
            report("secondJoinMs", "${(System.nanoTime() - t0) / 1_000_000}")
            assertEquals("ok", a2)
            assertEquals("the second join of the stage requested a new network", n1, n2)
            assertTrue(reaches(n2!!))
        } finally {
            net.dispose()
            scenario.close()
        }
        noPassInLogcat(pass)
    }

    @Test fun b_joinAccepted() { arm("b"); joined("ok") }
    @Test fun c_joinRefused() { arm("c"); joined("no_network") }
    @Test fun e_joinAgain() { arm("e"); joined("ok") }
    @Test fun f_sameSsidNoDirectRoute() { arm("f"); assumeTrue("needs -e mutant alwaysSpecifier", alwaysSpecifier); joined("ok") }
    @Test fun g_otherAp() { arm("g"); joined("ok") }
}
