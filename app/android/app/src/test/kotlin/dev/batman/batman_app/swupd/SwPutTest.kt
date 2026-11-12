package dev.batman.batman_app.swupd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory

/**
 * 254-app-update v0.4 §8 T8 (raw PUT), as JVM tests against a local fake node whose behaviour follows provd/http.go:
 * headers first, an early 409 + Connection: close + ~500 ms (Go's rstAvoidanceDelay) + close before the body is read,
 * 200 only after the whole body. The design puts T8 on the S20 (instrumented); [SwPut] is plain JVM, so the same
 * socket behaviour runs here (loopback, not the phone's Wi-Fi stack). Each test names its negative control (the
 * mutation that makes it FAIL).
 */
class SwPutTest {
    private val lo: InetAddress = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
    private val bearer = "0123456789abcdef0123456789abcdef"
    private val plain: SocketFactory = SocketFactory.getDefault()

    /** A stream of [size] pattern bytes that allocates nothing per read (the 200 MB heap test). */
    private class Pattern(private val size: Long) : InputStream() {
        var pos = 0L
        override fun read(): Int = if (pos >= size) -1 else (pos++ and 0xff).toInt()
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (pos >= size) return -1
            val n = minOf(len.toLong(), size - pos).toInt()
            for (i in 0 until n) b[off + i] = ((pos + i) and 0xff).toByte()
            pos += n
            return n
        }
    }

    /** The fake node: accepts connections on loopback, runs [serve] for each on its own thread. */
    private class FakeNode(val serve: (Socket) -> Unit) : AutoCloseable {
        val server = ServerSocket(0, 50, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
        val accepted = AtomicInteger()
        val port get() = server.localPort
        private val t = Thread {
            while (!server.isClosed) {
                val s = try { server.accept() } catch (e: SocketException) { break }
                accepted.incrementAndGet()
                Thread { s.use { try { serve(it) } catch (_: Exception) {} } }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true; start() }
        override fun close() = server.close()
    }

    // the request head as provd reads it (up to the empty line, at most 4 KiB like provd's header limit)
    private fun readHead(s: Socket): String {
        val inp = s.getInputStream()
        val b = ByteArrayOutputStream()
        while (b.size() < 4096) {
            val c = inp.read()
            if (c < 0) break
            b.write(c)
            val a = b.toByteArray()
            if (a.size >= 4 && String(a, a.size - 4, 4, Charsets.ISO_8859_1) == "\r\n\r\n") break
        }
        return String(b.toByteArray(), Charsets.ISO_8859_1)
    }

    private fun contentLength(head: String) = Regex("(?i)\r\ncontent-length: *(\\d+)\r\n").find(head)!!.groupValues[1].toLong()

    // read the body to the end, return the count; and how the stream ended: "eof" (FIN) or "reset" (RST)
    private fun drain(s: Socket, limit: Long = Long.MAX_VALUE, onByte: (Long) -> Unit = {}): Pair<Long, String> {
        val inp = s.getInputStream()
        val buf = ByteArray(64 * 1024)
        var n = 0L
        while (n < limit) {
            val r = try { inp.read(buf, 0, minOf(buf.size.toLong(), limit - n).toInt()) } catch (e: SocketException) {
                return n to if (e.message?.contains("reset", ignoreCase = true) == true) "reset" else "error:${e.message}"
            }
            if (r < 0) return n to "eof"
            n += r
            onByte(n)
        }
        return n to "limit"
    }

    private fun ok(s: Socket) {
        s.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
        s.getOutputStream().flush()
    }

    // T8: request line + 4 headers byte for byte, no Transfer-Encoding, the body intact, 200 -> ok200.
    // Negative control: add "Transfer-Encoding: chunked" (or any header change) in SwPut.request -> FAIL.
    @Test fun requestBytesExactAnd200() {
        val head = AtomicReference<String>()
        val body = AtomicReference<ByteArray>()
        FakeNode { s ->
            val h = readHead(s); head.set(h)
            val n = contentLength(h).toInt()
            val b = ByteArray(n); var got = 0
            while (got < n) { val r = s.getInputStream().read(b, got, n - got); if (r < 0) break; got += r }
            body.set(b.copyOf(got)); ok(s)
        }.use { node ->
            val data = ByteArray(200_000) { (it * 7).toByte() }
            val o = SwPut().put(plain, lo, node.port, bearer, data.size.toLong()) { data.inputStream() }
            assertEquals(SwPut.Outcome(SwPut.Result.OK200, "ok"), o)
            assertEquals(
                "PUT /batman/v1/bulk/0 HTTP/1.1\r\nHost: 127.0.0.1:${node.port}\r\nX-Batman-Upload: $bearer\r\n" +
                    "Content-Length: 200000\r\nConnection: close\r\n\r\n", head.get())
            assertFalse(head.get().contains("Transfer-Encoding", ignoreCase = true))
            assertTrue(body.get().contentEquals(data))
        }
    }

    // T8: a 200 MB file streams with a heap increase < 16 MB.
    // Negative control: read the whole file first (readBytes()) -> FAIL (or OOM).
    @Test fun twoHundredMegabytesInSmallHeap() {
        val size = 200L * 1024 * 1024
        FakeNode { s -> val h = readHead(s); drain(s, contentLength(h)); ok(s) }.use { node ->
            val rt = Runtime.getRuntime()
            System.gc(); Thread.sleep(200)
            val base = rt.totalMemory() - rt.freeMemory()
            val peak = AtomicLong(0)
            val sampler = Thread {
                try { while (true) { peak.set(maxOf(peak.get(), rt.totalMemory() - rt.freeMemory() - base)); Thread.sleep(5) } } catch (_: InterruptedException) {}
            }.apply { isDaemon = true; start() }
            val o = SwPut().put(plain, lo, node.port, bearer, size) { Pattern(size) }
            sampler.interrupt()
            assertEquals(SwPut.Result.OK200, o.result)
            assertTrue("heap grew ${peak.get() / 1024 / 1024} MB", peak.get() < 16L * 1024 * 1024)
        }
    }

    // T8: provd refuses before reading the body (409, Connection: close, ~500 ms, close) while >= 1 MB is being sent
    // -> other, without depending on the status code. Negative control: report the status only when one is read
    // (a v0.2-style 409 branch: an I/O error counted as anything but other) -> FAIL.
    @Test fun early409BeforeBodyIsOther() {
        FakeNode { s ->
            readHead(s)
            s.getOutputStream().write("HTTP/1.1 409 Conflict\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".toByteArray())
            s.shutdownOutput(); Thread.sleep(500)
        }.use { node ->
            val size = 8L * 1024 * 1024
            val o = SwPut().put(plain, lo, node.port, bearer, size) { Pattern(size) }
            assertEquals(SwPut.Result.OTHER, o.result)
        }
    }

    // T8: a non-200 status after the whole body -> other
    @Test fun non200StatusIsOther() {
        FakeNode { s ->
            val h = readHead(s); drain(s, contentLength(h))
            s.getOutputStream().write("HTTP/1.1 403 Forbidden\r\n\r\n".toByteArray())
        }.use { node ->
            assertEquals(SwPut.Outcome(SwPut.Result.OTHER, "status"), SwPut().put(plain, lo, node.port, bearer, 1000) { Pattern(1000) })
        }
    }

    // T8: the fake node stops reading -> other within <= 40 s (the real 35 s watchdog, default Timing), and the node
    // sees an RST. Negative control: no watchdog -> the PUT blocks past 60 s -> FAIL (the test's own 60 s guard).
    @Test(timeout = 60_000) fun stalledNodeTripsWatchdog() {
        val ended = AtomicReference<String>()
        FakeNode { s ->
            readHead(s)
            Thread.sleep(38_000) // stops reading: the client's send buffer fills, the write blocks
            ended.set(drain(s).second)
        }.use { node ->
            val size = 200L * 1024 * 1024
            val t0 = System.nanoTime()
            val o = SwPut().put(plain, lo, node.port, bearer, size) { Pattern(size) }
            val secs = (System.nanoTime() - t0) / 1e9
            assertEquals(SwPut.Outcome(SwPut.Result.OTHER, "watchdog"), o)
            assertTrue("took $secs s", secs in 34.0..40.0)
            Thread.sleep(4_000)
            assertEquals("reset", ended.get())
        }
    }

    // T8: cancel -> the node gets an RST (linger 0), not a FIN followed by the rest of the send buffer. A N1 arm: the
    // node keeps reading after the abort; the app makes no new connection and reports only "other" (its fixed code;
    // no "someone is uploading" text exists anywhere in Kotlin — the 31 s wait before any retry is Rust's
    // PUT_FAIL_WAIT_MS, T5). Negative control: plain close() without SO_LINGER 0 in SwPut.hardClose -> "eof" -> FAIL.
    @Test fun cancelSendsRstAndNoRetry() {
        val ended = AtomicReference<String>()
        val put = SwPut()
        FakeNode { s ->
            readHead(s)
            val r = drain(s) { n -> if (n >= 4L * 1024 * 1024) { put.abort("cancelled") } ; Thread.sleep(0, 1) }
            ended.set(r.second)
        }.use { node ->
            val size = 200L * 1024 * 1024
            val o = put.put(plain, lo, node.port, bearer, size) { Pattern(size) }
            assertEquals(SwPut.Outcome(SwPut.Result.OTHER, "cancelled"), o)
            Thread.sleep(2_000)
            assertEquals("reset", ended.get())
            assertEquals("one connection, no retry by Kotlin", 1, node.accepted.get())
            assertTrue(o.result.wire in setOf("ok200", "other", "no_network"))
        }
    }

    // a file shorter than its size -> other (never a hung Content-Length), the node sees an RST
    @Test fun shortFileIsOtherWithRst() {
        val ended = AtomicReference<String>()
        FakeNode { s -> readHead(s); ended.set(drain(s).second) }.use { node ->
            val o = SwPut().put(plain, lo, node.port, bearer, 1_000_000) { Pattern(300_000) }
            assertEquals(SwPut.Outcome(SwPut.Result.OTHER, "short_file"), o)
            Thread.sleep(500)
            assertEquals("reset", ended.get())
        }
    }

    /** Sockets whose first [timeouts] connects time out (the AP drops, F14); the rest connect for real. */
    private class Flaky(val timeouts: Int) : SocketFactory() {
        val made = AtomicInteger()
        override fun createSocket(): Socket = if (made.incrementAndGet() <= timeouts) object : Socket() {
            override fun connect(endpoint: SocketAddress?, timeout: Int) { throw SocketTimeoutException("connect timed out") }
        } else Socket()
        override fun createSocket(h: String?, p: Int) = throw UnsupportedOperationException()
        override fun createSocket(h: String?, p: Int, a: InetAddress?, lp: Int) = throw UnsupportedOperationException()
        override fun createSocket(h: InetAddress?, p: Int) = throw UnsupportedOperationException()
        override fun createSocket(h: InetAddress?, p: Int, a: InetAddress?, lp: Int) = throw UnsupportedOperationException()
    }

    // T8 direct path (D5): one connect timeout, then success -> the PUT goes through (no Specifier).
    // Negative control: CONNECT_TRIES = 1 (Specifier after one timeout) -> no_network -> FAIL.
    @Test fun oneConnectTimeoutThenSuccessStaysDirect() {
        FakeNode { s -> val h = readHead(s); drain(s, contentLength(h)); ok(s) }.use { node ->
            val f = Flaky(1)
            assertEquals(SwPut.Result.OK200, SwPut().put(f, lo, node.port, bearer, 10) { Pattern(10) }.result)
            assertEquals(2, f.made.get())
        }
    }

    // two connect timeouts -> no_network (Dart then goes to joinAp). Negative control: CONNECT_TRIES = 3 -> ok200 -> FAIL.
    @Test fun twoConnectTimeoutsAreNoNetwork() {
        FakeNode { s -> val h = readHead(s); drain(s, contentLength(h)); ok(s) }.use { node ->
            val f = Flaky(2)
            assertEquals(SwPut.Outcome(SwPut.Result.NO_NETWORK, "unreached"), SwPut().put(f, lo, node.port, bearer, 10) { Pattern(10) })
            assertEquals(2, f.made.get())
            assertEquals(0, node.accepted.get())
        }
    }

    // refused (provd not bound yet, F13): retried every second up to 10 s; binding in time -> ok200, never -> other.
    // Times shortened 10x (100 ms / 1 s). Negative control: no retry on refused -> the first case FAILs.
    @Test fun refusedIsRetriedUntilBound() {
        val probe = ServerSocket(0, 1, lo); val port = probe.localPort; probe.close()
        val timing = SwPut.Timing(refusedRetryMs = 100, refusedForMs = 1_000)
        // bind the fake node on the same port after 350 ms
        val late = AtomicReference<ServerSocket>()
        val t = Thread {
            Thread.sleep(350)
            val ss = ServerSocket(port, 50, lo); late.set(ss)
            ss.accept().use { s -> val h = readHead(s); drain(s, contentLength(h)); ok(s) }
        }.apply { isDaemon = true; start() }
        try {
            val t0 = System.nanoTime()
            val o = SwPut(timing).put(plain, lo, port, bearer, 10) { Pattern(10) }
            assertEquals(SwPut.Result.OK200, o.result)
            assertTrue((System.nanoTime() - t0) / 1_000_000 >= 300)
        } finally { t.join(2_000); late.get()?.close() }
    }

    @Test fun refusedForeverIsOther() {
        val probe = ServerSocket(0, 1, lo); val port = probe.localPort; probe.close()
        val t0 = System.nanoTime()
        val o = SwPut(SwPut.Timing(refusedRetryMs = 100, refusedForMs = 1_000)).put(plain, lo, port, bearer, 10) { Pattern(10) }
        assertEquals(SwPut.Outcome(SwPut.Result.OTHER, "refused"), o)
        assertTrue((System.nanoTime() - t0) / 1_000_000 >= 1_000)
    }

    // D8: bad arguments never connect and never echo the bearer; outcomes carry only fixed codes
    @Test fun argsAndSecrets() {
        FakeNode { }.use { node ->
            for (b in listOf("0123456789ABCDEF0123456789ABCDEF", "short", bearer + "0")) {
                val o = SwPut().put(plain, lo, node.port, b, 10) { Pattern(10) }
                assertEquals(SwPut.Outcome(SwPut.Result.OTHER, "args"), o)
                assertFalse(o.toString().contains(b))
            }
            assertEquals(0, node.accepted.get())
        }
        assertEquals(null, SwPut.ipv4("node.local")); assertEquals(null, SwPut.ipv4("10.41.80.256")); assertEquals(null, SwPut.ipv4("10.41.80"))
        assertEquals("10.41.80.13", SwPut.ipv4("10.41.80.13")!!.hostAddress)
        // the constants the design fixes (D4 / D5)
        assertEquals(35_000L, SwPut.STALL_MS); assertEquals(3_000, SwPut.CONNECT_TIMEOUT_MS); assertEquals(2, SwPut.CONNECT_TRIES)
    }
}
