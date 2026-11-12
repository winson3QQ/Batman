package dev.batman.batman_app.swupd

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream

/**
 * 254-app-update D1 / §11.1 pickUpdateFiles: a gzip payload is read for its first 2 bytes only; a manifest candidate
 * (not gzip, 0 <= size <= 64 KiB) is read whole but never past 64 KiB + 1 (statSize may lie); anything else -> empty.
 * Negative controls: drop the gzip stop -> payloadStopsAtTwoBytes FAILs (7 bytes read); drop the 64 KiB + 1 cap ->
 * lyingSizeIsCapped FAILs (the whole 1 MB read).
 */
class SwPickTest {
    private class Counting(b: ByteArray) : ByteArrayInputStream(b) { val read get() = pos }

    @Test fun payloadStopsAtTwoBytes() {
        val s = Counting(byteArrayOf(0x1f, 0x8b.toByte(), 8, 0, 0, 0, 0, 0, 0))
        val (head, data) = SwPick.readHead(s, 9)
        assertArrayEquals(byteArrayOf(0x1f, 0x8b.toByte()), head)
        assertEquals(0, data.size)
        assertEquals(2, s.read)
    }

    @Test fun manifestIsReadWhole() {
        val m = ByteArray(SwPick.MANIFEST_MAX) { (it % 251).toByte() }.also { it[0] = 0xa6.toByte() }
        val (head, data) = SwPick.readHead(Counting(m), m.size.toLong())
        assertArrayEquals(m.copyOf(2), head)
        assertArrayEquals(m, data)
    }

    @Test fun lyingSizeIsCapped() {
        val big = ByteArray(1 shl 20) { 0x41 }
        val s = Counting(big)
        val (head, data) = SwPick.readHead(s, 100) // statSize says 100, the stream has 1 MB
        assertEquals(2, head.size)
        assertEquals(0, data.size)
        assertEquals(SwPick.MANIFEST_MAX + 1, s.read)
    }

    @Test fun unknownOrLargeSizeReadsNothingMore() {
        for (size in listOf(-1L, SwPick.MANIFEST_MAX + 1L)) {
            val s = Counting(ByteArray(100) { 0x41 })
            val (head, data) = SwPick.readHead(s, size)
            assertEquals(2, head.size); assertEquals(0, data.size); assertEquals(2, s.read)
        }
        val (h1, d1) = SwPick.readHead(Counting(byteArrayOf(0x1f)), 1) // a 1-byte file
        assertArrayEquals(byteArrayOf(0x1f), h1); assertArrayEquals(byteArrayOf(0x1f), d1)
        val (h0, d0) = SwPick.readHead(Counting(ByteArray(0)), 0)
        assertEquals(0, h0.size); assertEquals(0, d0.size)
    }
}
