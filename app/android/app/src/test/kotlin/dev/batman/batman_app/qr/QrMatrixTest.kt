package dev.batman.batman_app.qr

import com.google.zxing.BinaryBitmap
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #329 PR 5 plan v16 T-Q1: the three code kinds from the protocol test vectors, upper-cased as the app shows them,
 * encode to the versions R-8 measured (P16) and decode back to the same text; the R1 limit (≤ v27) is reachable;
 * anything that is not 1..4096 upper-case hex is refused.
 */
class QrMatrixTest {
    private val vectors: String = File("../../../tests/vectors/219-protocol/vectors.json")
        .also { assertTrue("vectors.json not found from ${File(".").absolutePath}", it.isFile) }
        .readText()

    private fun hex(key: String): String =
        requireNotNull(Regex("\"$key\": \"([0-9a-f]+)\"").find(vectors)) { "no $key in vectors.json" }.groupValues[1]

    /** qr-object {1: kind, 2: bstr} around a raw object, as Rust's qr_hex does (a 2-byte length) */
    private fun wrap(kind: Int, raw: String) = "a201%02x0259%04x".format(kind, raw.length / 2) + raw

    private val invite get() = hex("qr_invite_object").uppercase()
    private val request get() = wrap(2, hex("join_request")).uppercase()
    private val approval get() = hex("qr_approval_object").uppercase()

    /** the modules drawn 4 px each with a 4-module quiet zone, read back by ZXing */
    private fun decode(r: QrMatrix.Result): String {
        val scale = 4
        val n = (r.size + 8) * scale
        val y = ByteArray(n * n) { 0xff.toByte() }
        val rowBytes = (r.size + 7) / 8
        for (my in 0 until r.size) for (mx in 0 until r.size) {
            val on = (r.bits[my * rowBytes + mx / 8].toInt() and (0x80 ushr (mx % 8))) != 0
            if (!on) continue
            for (dy in 0 until scale) for (dx in 0 until scale) y[((my + 4) * scale + dy) * n + (mx + 4) * scale + dx] = 0
        }
        val src = PlanarYUVLuminanceSource(y, n, n, 0, 0, n, n, false)
        return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(src))).text
    }

    @Test fun theThreeKindsHaveTheMeasuredVersionsAndDecodeBack() {
        for ((name, text, version) in listOf(Triple("invite", invite, 16), Triple("request", request, 26), Triple("approval", approval, 27))) {
            val r = QrMatrix.encode(text)
            assertNotNull(name, r)
            r!!
            assertEquals("$name version", version, r.version)
            assertEquals("$name size", 17 + 4 * version, r.size)
            assertEquals("$name bits", r.size * ((r.size + 7) / 8), r.bits.size)
            assertEquals("$name round trip", text, decode(r))
        }
    }

    @Test fun theLongestInputIsOverTheR1Limit() {
        val r = QrMatrix.encode("A".repeat(QrMatrix.MAX_LEN))
        assertNotNull(r)
        assertTrue("v${r!!.version} must be > 27 so R1 shows no QR", r.version > 27)
    }

    @Test fun refusesWhatIsNotUpperCaseHexWithinTheLimit() {
        assertNull("4097", QrMatrix.encode("A".repeat(QrMatrix.MAX_LEN + 1)))
        assertNull("lower case", QrMatrix.encode(invite.lowercase()))
        assertNull("empty", QrMatrix.encode(""))
        assertNull("not hex", QrMatrix.encode("A2G1"))
    }

    @Test fun theSensitiveExtraKey() {
        assertEquals(ClipSensitive.EXTRA, ClipSensitive.key(31))
        assertEquals(ClipSensitive.EXTRA, ClipSensitive.key(33))
        assertNull(ClipSensitive.key(30))
        assertEquals("android.content.extra.IS_SENSITIVE", ClipSensitive.EXTRA)
    }
}
