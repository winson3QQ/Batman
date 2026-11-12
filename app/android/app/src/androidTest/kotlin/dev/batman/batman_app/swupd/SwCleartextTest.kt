package dev.batman.batman_app.swupd

import android.security.NetworkSecurityPolicy
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.URL
import javax.net.SocketFactory

/**
 * 254-app-update v0.4 §8 T12 (instrumented, on the S20; WRITTEN, NOT RUN — needs the phone):
 *   ./gradlew :app:connectedDevDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=dev.batman.batman_app.swupd.SwCleartextTest
 * Run it once on a release build too (both flavors; §8 T12: the debug manifest hides a missing INTERNET).
 * - the raw-socket PUT to a local fake node succeeds although cleartext is not permitted app-wide;
 * - negative control (in the same app): HttpURLConnection to the same http:// fails with "CLEARTEXT communication …
 *   not permitted" — proves nothing relaxed the policy. Mutation: add android:usesCleartextTraffic="true" (or a
 *   networkSecurityConfig permitting cleartext) to the main manifest -> cleartextIsBlockedForHttpStack FAILs.
 * - logcat after the PUT does not hold the bearer (lower- or upper-case hex); the passphrase is checked in T9.
 *   Mutation: a Log.d of the bearer in SwPut -> noSecretInLogcat FAILs.
 * §10-15: if 127.0.0.1 turns out to be exempt from the policy, run with `-e host wifi` (the phone's Wi-Fi IPv4).
 */
@RunWith(AndroidJUnit4::class)
class SwCleartextTest {
    private val bearer = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

    private fun host(): InetAddress {
        if (InstrumentationRegistry.getArguments().getString("host") != "wifi") return InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        return NetworkInterface.getNetworkInterfaces().toList().filter { it.name.startsWith("wlan") }
            .flatMap { it.inetAddresses.toList() }.first { it.address.size == 4 }
    }

    // a fake node answering 200 after reading the head and Content-Length bytes
    private fun fakeNode(at: InetAddress): ServerSocket {
        val ss = ServerSocket(0, 5, at)
        Thread {
            try {
                ss.accept().use { s ->
                    val inp = s.getInputStream()
                    val head = ByteArrayOutputStream()
                    while (!head.toString("ISO-8859-1").endsWith("\r\n\r\n")) { val c = inp.read(); if (c < 0) break; head.write(c) }
                    val n = Regex("Content-Length: (\\d+)").find(head.toString("ISO-8859-1"))?.groupValues?.get(1)?.toLong() ?: 0
                    var got = 0L; val buf = ByteArray(65536)
                    while (got < n) { val r = inp.read(buf); if (r < 0) break; got += r }
                    s.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".toByteArray())
                }
            } catch (_: IOException) {
            }
        }.apply { isDaemon = true; start() }
        return ss
    }

    private fun body(n: Long): InputStream = object : InputStream() {
        var left = n
        override fun read(): Int = if (left-- > 0) 0x55 else -1
    }

    @Test fun rawSocketPutWorksWithCleartextOff() {
        assertFalse("cleartext must stay disallowed app-wide", NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted)
        val at = host()
        fakeNode(at).use { ss ->
            val o = SwPut().put(SocketFactory.getDefault(), at, ss.localPort, bearer, 300_000) { body(300_000) }
            assertEquals(SwPut.Result.OK200, o.result)
        }
    }

    @Test fun cleartextIsBlockedForHttpStack() {
        val at = host()
        fakeNode(at).use { ss ->
            val c = URL("http://${at.hostAddress}:${ss.localPort}/batman/v1/bulk/0").openConnection() as HttpURLConnection
            try {
                c.connectTimeout = 3_000
                c.responseCode
                fail("HttpURLConnection reached http:// — cleartext is permitted (policy relaxed)")
            } catch (e: IOException) {
                assertTrue("${e.javaClass.name}: ${e.message}", e.message?.contains("CLEARTEXT", ignoreCase = true) == true)
            } finally {
                c.disconnect()
            }
        }
    }

    @Test fun noSecretInLogcat() {
        val at = host()
        fakeNode(at).use { ss -> SwPut().put(SocketFactory.getDefault(), at, ss.localPort, bearer, 1000) { body(1000) } }
        val ui = InstrumentationRegistry.getInstrumentation().uiAutomation
        val log = ui.executeShellCommand("logcat -d").let { pfd ->
            android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.readBytes().toString(Charsets.UTF_8) }
        }
        assertTrue("logcat is empty: nothing was checked", log.length > 1000)
        for (secret in listOf(bearer, bearer.uppercase())) assertFalse("the bearer is in logcat", log.contains(secret))
    }
}
