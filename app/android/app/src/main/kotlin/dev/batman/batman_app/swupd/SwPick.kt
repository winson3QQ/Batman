package dev.batman.batman_app.swupd

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** 254-app-update D1 / U1 / §11.1 pickUpdateFiles: what is read of a picked file (plain JVM; T8-side unit test). */
object SwPick {
    const val MANIFEST_MAX = 64 * 1024
    private val GZIP = byteArrayOf(0x1f, 0x8b.toByte())

    /** U1 / D1: (first <= 2 bytes, the whole file if it may be a manifest else empty); a gzip file stops at 2 bytes. */
    fun readHead(inp: InputStream, size: Long): Pair<ByteArray, ByteArray> {
        val h = ByteArray(2)
        var n = 0
        while (n < 2) { val r = inp.read(h, n, 2 - n); if (r < 0) break; n += r }
        val head = h.copyOf(n)
        if (head.contentEquals(GZIP) || size < 0 || size > MANIFEST_MAX) return head to ByteArray(0)
        val out = ByteArrayOutputStream().apply { write(head) }
        val buf = ByteArray(8192)
        while (out.size() <= MANIFEST_MAX) {
            val r = inp.read(buf, 0, minOf(buf.size, MANIFEST_MAX + 1 - out.size()))
            if (r < 0) break
            out.write(buf, 0, r)
        }
        return head to (if (out.size() > MANIFEST_MAX) ByteArray(0) else out.toByteArray())
    }
}
