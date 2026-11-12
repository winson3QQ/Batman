package dev.batman.batman_app.swupd

import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Socket
import java.net.SocketTimeoutException
import javax.net.SocketFactory

/**
 * 254-app-update v0.4 D4 / D5: the one HTTP request of the software update — a raw-socket `PUT /batman/v1/bulk/0` to
 * provd on the node's phone AP. Plain JVM (no android.*), so the JVM unit tests (T8) drive it against a local fake node.
 *
 * D4: hand-written HTTP/1.1, four headers, a fixed Content-Length (never chunked), the body streamed from the picked
 * file in 64 KiB chunks; only the status line is read; the result is only "200" or "other" (an early 409 / 403 / 400
 * is usually never seen, F11). Abort = SO_LINGER 0 then close (an RST, the send buffer dropped) — from the watchdog
 * (35 s without a byte more written), a cancel, or the Specifier network's onLost. D5: the PUT's own connect is the
 * probe — 3 s timeout, one retry, then no_network; refused (provd not bound yet, F13) -> every 1 s for up to 10 s.
 *
 * Secrets (D8): the bearer is only ever written into the request bytes; it is never part of a result, an exception
 * message or a log line. Results carry only a fixed, non-secret code. One instance = one PUT.
 */
class SwPut(
    private val timing: Timing = Timing(),
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
) {
    /** The waits of the PUT (design D4 / D5). Tests shorten only the ones they say they shorten. */
    data class Timing(
        val connectTimeoutMs: Int = CONNECT_TIMEOUT_MS,
        val refusedRetryMs: Long = REFUSED_RETRY_MS,
        val refusedForMs: Long = REFUSED_FOR_MS,
        val stallMs: Long = STALL_MS,
    )

    /** §11.1: the three answers of `upload`, plus a short non-secret code (for tests; not sent to Dart). */
    enum class Result(val wire: String) { OK200("ok200"), OTHER("other"), NO_NETWORK("no_network") }
    data class Outcome(val result: Result, val code: String)

    @Volatile private var socket: Socket? = null
    @Volatile private var body: InputStream? = null
    @Volatile private var aborted: String? = null
    @Volatile private var lastProgress = 0L
    /** Body bytes written so far by this PUT (§11.1 `uploadProgress`). */
    @Volatile var sent = 0L
        private set

    /**
     * Aborts the PUT (cancel / onLost / watchdog): SO_LINGER 0 + close, so the node gets an RST and nothing more of the
     * send buffer (D4 v0.4). Idempotent; before the connect it makes the PUT end without sending anything.
     */
    fun abort(code: String) {
        if (aborted == null) aborted = code
        socket?.let { hardClose(it) }
        // code review r1 B-m1: a read stuck in the file (a stalled DocumentsProvider pipe) is woken where the stream allows
        body?.let { try { it.close() } catch (_: IOException) {} }
    }

    /**
     * Runs the PUT on the calling thread (never the UI thread). [open] opens the body (the SAF stream); exactly [size]
     * bytes are sent.
     */
    fun put(factory: SocketFactory, ip: InetAddress, port: Int, bearerHex: String, size: Long, open: () -> InputStream): Outcome {
        if (!isBearerHex(bearerHex) || port !in 1..65535 || size <= 0) return Outcome(Result.OTHER, "args")
        aborted?.let { return Outcome(Result.OTHER, it) }
        // code review r1 B-m2: the file is opened BEFORE the connect — provd gives the request head 5 s from the accept
        // (http.go ReadHeaderTimeout); a slow provider (a cloud file) must not eat into it
        val input = try { open() } catch (e: Exception) { return Outcome(Result.OTHER, "file_io") }
        body = input
        var watchdog: Thread? = null
        try {
            aborted?.let { return Outcome(Result.OTHER, it) }
            val s = when (val c = connect(factory, ip, port)) {
                is Conn.Up -> c.socket
                is Conn.Down -> return c.outcome
            }
            aborted?.let { hardClose(s); return Outcome(Result.OTHER, it) }
            s.soTimeout = timing.stallMs.toInt() // the status line read (D4)
            lastProgress = clock()
            watchdog = Thread({ watch(s) }, "swupd-watchdog").apply { isDaemon = true; start() }
            // the body is copied on its own thread: a file read that never returns (r1 B-m1) cannot hold the PUT past
            // the watchdog — its abort ends the wait here, the copy thread dies with the closed socket / stream
            var copyErr: String? = null
            val copy = Thread({ copyErr = copy(s, input, ip, port, bearerHex, size) }, "swupd-body").apply { isDaemon = true; start() }
            while (copy.isAlive) {
                copy.join(WATCH_TICK_MS)
                if (copy.isAlive) aborted?.let { return fail(s, it) }
            }
            copyErr?.let { return fail(s, it) }
            val line = statusLine(s)
            return if (line.startsWith("HTTP/1.") && line.split(' ').getOrNull(1) == "200") {
                s.close()
                if (aborted != null) Outcome(Result.OTHER, aborted!!) else Outcome(Result.OK200, "ok")
            } else fail(s, "status")
        } catch (e: SocketTimeoutException) {
            return socket?.let { fail(it, "read_timeout") } ?: Outcome(Result.OTHER, aborted ?: "read_timeout")
        } catch (e: IOException) {
            return socket?.let { fail(it, "io") } ?: Outcome(Result.OTHER, aborted ?: "io")
        } finally {
            watchdog?.interrupt()
            socket = null
            body = null
            try { input.close() } catch (_: IOException) {}
        }
    }

    // the head, then exactly [size] bytes in 64 KiB chunks; null = all sent, else the failure code
    private fun copy(s: Socket, input: InputStream, ip: InetAddress, port: Int, bearerHex: String, size: Long): String? = try {
        val out = s.getOutputStream()
        out.write(request(ip, port, bearerHex, size))
        val buf = ByteArray(CHUNK)
        var err: String? = null
        while (sent < size && err == null) {
            if (aborted != null) { err = aborted; break } // r1 B-m1: a zero-read spin ends with the watchdog
            val want = minOf(buf.size.toLong(), size - sent).toInt()
            val n = try { input.read(buf, 0, want) } catch (e: IOException) { err = "file_io"; break }
            if (n < 0) { err = "short_file"; break }
            if (n == 0) continue
            out.write(buf, 0, n)
            sent += n
            lastProgress = clock()
        }
        if (err == null) out.flush()
        err
    } catch (e: IOException) {
        "io"
    }

    // any failure after the connect: the socket is aborted (RST); an abort that came first decides the code
    private fun fail(s: Socket, code: String): Outcome {
        hardClose(s)
        return Outcome(Result.OTHER, aborted ?: code)
    }

    private fun watch(s: Socket) {
        try {
            while (!s.isClosed) {
                sleep(WATCH_TICK_MS)
                if (clock() - lastProgress >= timing.stallMs) { abort("watchdog"); return }
            }
        } catch (_: InterruptedException) {
        }
    }

    private sealed class Conn {
        class Up(val socket: Socket) : Conn()
        class Down(val outcome: Outcome) : Conn()
    }

    // D5: two connect timeouts (or no route: ARP failed on a same-subnet foreign AP) = not this node's AP (F14 drops)
    // -> no_network; refused = provd not bound yet (F13) -> every 1 s for up to 10 s, then other
    private fun connect(factory: SocketFactory, ip: InetAddress, port: Int): Conn {
        val start = clock()
        var unreached = 0
        while (true) {
            aborted?.let { return Conn.Down(Outcome(Result.OTHER, it)) }
            val s = factory.createSocket()
            socket = s
            try {
                s.connect(InetSocketAddress(ip, port), timing.connectTimeoutMs)
                return Conn.Up(s)
            } catch (e: IOException) {
                hardClose(s)
                socket = null
                aborted?.let { return Conn.Down(Outcome(Result.OTHER, it)) }
                when (e) {
                    is SocketTimeoutException, is NoRouteToHostException ->
                        if (++unreached >= CONNECT_TRIES) return Conn.Down(Outcome(Result.NO_NETWORK, "unreached"))
                    is ConnectException -> {
                        if (clock() - start >= timing.refusedForMs) return Conn.Down(Outcome(Result.OTHER, "refused"))
                        try { sleep(timing.refusedRetryMs) } catch (_: InterruptedException) { return Conn.Down(Outcome(Result.OTHER, "cancelled")) }
                    }
                    else -> return Conn.Down(Outcome(Result.OTHER, "connect_io"))
                }
            }
        }
    }

    companion object {
        const val CONNECT_TIMEOUT_MS = 3_000
        const val CONNECT_TRIES = 2
        const val REFUSED_RETRY_MS = 1_000L
        const val REFUSED_FOR_MS = 10_000L
        /** D4: 35 s without a byte more written -> abort; also the status line's SO_TIMEOUT */
        const val STALL_MS = 35_000L
        const val CHUNK = 64 * 1024
        const val WATCH_TICK_MS = 500L
        private const val STATUS_MAX = 256

        fun isBearerHex(s: String) = s.length == 32 && s.all { it in '0'..'9' || it in 'a'..'f' }

        /**
         * v0.4.2: the app's default network has TRANSPORT_VPN (true) / not (false) / unknown (null: no capabilities).
         * Unknown is not a VPN: the PUT then shows whether the node is reached (its code says how it failed).
         */
        fun vpnCovers(hasVpnTransport: Boolean?) = hasVpnTransport == true

        /** The request head, byte for byte (T8): request line, Host, X-Batman-Upload, Content-Length, Connection. */
        fun request(ip: InetAddress, port: Int, bearerHex: String, size: Long): ByteArray =
            ("PUT /batman/v1/bulk/0 HTTP/1.1\r\n" +
                "Host: ${ip.hostAddress}:$port\r\n" +
                "X-Batman-Upload: $bearerHex\r\n" +
                "Content-Length: $size\r\n" +
                "Connection: close\r\n\r\n").toByteArray(Charsets.US_ASCII)

        /** Linger 0 + close: an RST, the send buffer dropped (D4). Errors are ignored (already closed). */
        fun hardClose(s: Socket) {
            try { s.setSoLinger(true, 0) } catch (_: IOException) {}
            try { s.close() } catch (_: IOException) {}
        }

        // only the status line ("HTTP/1.1 200 OK"), at most 256 bytes; nothing after it is read
        private fun statusLine(s: Socket): String {
            val inp = s.getInputStream()
            val b = StringBuilder()
            while (b.length < STATUS_MAX) {
                val c = inp.read()
                if (c < 0 || c == '\n'.code) break
                if (c != '\r'.code) b.append(c.toChar())
            }
            return b.toString()
        }

        /** An IPv4 literal only (never a name lookup): four decimal octets. */
        fun ipv4(s: String): InetAddress? {
            val p = s.split('.')
            if (p.size != 4) return null
            val b = ByteArray(4)
            for (i in 0..3) {
                val v = p[i].takeIf { it.isNotEmpty() && it.length <= 3 && it.all { c -> c in '0'..'9' } }?.toInt() ?: return null
                if (v > 255) return null
                b[i] = v.toByte()
            }
            return InetAddress.getByAddress(b)
        }
    }
}
