package dev.batman.batman_app.qr

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.common.BitMatrix
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.ByteBuffer
import java.util.Random

/**
 * 254-app-qr §5 U1–U4: real QR codes (ZXing's writer) laid out as a CameraX Y plane — rowStride padding, a short last
 * row — and decoded through [QrDecode.fromPlane], the path QrScanActivity uses.
 */
class QrDecodeTest {
    // the provhelper claim QR's shape: 112 lowercase hex (CBOR {1: device_id, 2: K}); a test value, not a real K
    private val claim = "a2017262617461642d30303030303030303030303002582000112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        .substring(0, 112)

    private fun qr(text: String, w: Int, h: Int): BitMatrix = QRCodeWriter().encode(
        text, BarcodeFormat.QR_CODE, w, h, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.L)
    )

    /** a Y plane: rows of [rowStride] bytes (the padding is noise), the last row only [m].width long */
    private fun plane(m: BitMatrix, rowStride: Int, invert: Boolean = false): ByteBuffer {
        val w = m.width; val h = m.height
        val y = ByteArray(rowStride * (h - 1) + w)
        Random(7).nextBytes(y)
        for (r in 0 until h) for (c in 0 until w) {
            val dark = m[c, r] != invert
            y[r * rowStride + c] = (if (dark) 0x10 else 0xF0).toByte()
        }
        return ByteBuffer.wrap(y)
    }

    private fun scan(m: BitMatrix, pad: Int = 64, invert: Boolean = false): String? =
        QrDecode.fromPlane(plane(m, m.width + pad, invert), m.width + pad, 1, m.width, m.height)

    private fun rotate90(m: BitMatrix): BitMatrix {
        val r = BitMatrix(m.height, m.width)
        for (y in 0 until m.height) for (x in 0 until m.width) if (m[x, y]) r.set(m.height - 1 - y, x)
        return r
    }

    @Test fun u1PaddedRowsAndAShortLastRow() {
        val m = qr(claim, 320, 300)
        val b = plane(m, 384)
        assertEquals(384 * 299 + 320, b.remaining())
        assertEquals(claim, QrDecode.fromPlane(b, 384, 1, 320, 300))
    }

    @Test fun u1NoPadding() {
        assertEquals(claim, scan(qr(claim, 300, 300), pad = 0))
    }

    @Test fun u2NoiseIsNull() {
        val y = ByteArray(640 * 480).also { Random(1).nextBytes(it) }
        assertNull(QrDecode.fromPlane(ByteBuffer.wrap(y), 640, 1, 640, 480))
    }

    @Test fun u2LengthCap() {
        assertEquals("1".repeat(4096), scan(qr("1".repeat(4096), 600, 600)))
        assertNull("over 4096 characters is ignored", scan(qr("1".repeat(4097), 600, 600)))
    }

    @Test fun u2MalformedFramesAreNullNotThrown() {
        assertNull("all black", QrDecode.fromPlane(ByteBuffer.wrap(ByteArray(100 * 100)), 100, 1, 100, 100))
        assertNull("1x1", QrDecode.fromPlane(ByteBuffer.wrap(ByteArray(1)), 1, 1, 1, 1))
        assertNull("shorter than its size", QrDecode.fromPlane(ByteBuffer.wrap(ByteArray(10)), 100, 1, 100, 100))
        assertNull("rowStride < width", QrDecode.fromPlane(ByteBuffer.wrap(ByteArray(100 * 100)), 50, 1, 100, 100))
        assertNull("empty", QrDecode.fromPlane(ByteBuffer.wrap(ByteArray(0)), 0, 1, 0, 0))
        val m = qr(claim, 300, 300)
        assertNull("pixelStride 2 is not guessed", QrDecode.fromPlane(plane(m, 364), 364, 2, 300, 300))
    }

    @Test fun u3InvertedCode() {
        assertEquals(claim, scan(qr(claim, 300, 300), invert = true))
    }

    @Test fun u4RotatedCode() {
        assertEquals(claim, scan(rotate90(qr(claim, 320, 300))))
    }
}
