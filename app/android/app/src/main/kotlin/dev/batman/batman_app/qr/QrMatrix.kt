package dev.batman.batman_app.qr

import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.encoder.Encoder

/**
 * #329 PR 5 plan v16 §2.1 / R1: the app's own upper-case hex code -> the QR modules, for Dart to draw. Pure (ZXing
 * core only), so the JVM tests run the same code. The text is never logged; errors carry a fixed message only.
 */
object QrMatrix {
    const val MAX_LEN = 4096

    /** the encoded QR: [size] modules square, QR [version], [bits] row by row, each row padded to whole bytes, MSB first */
    class Result(val size: Int, val version: Int, val bits: ByteArray)

    /** null when [text] is not 1..[MAX_LEN] characters of [0-9A-F] or ZXing cannot encode it (Dart then shows no QR) */
    fun encode(text: String): Result? {
        if (text.isEmpty() || text.length > MAX_LEN || !text.all { it in '0'..'9' || it in 'A'..'F' }) return null
        return try {
            val q = Encoder.encode(text, ErrorCorrectionLevel.L)
            val m = q.matrix
            val size = m.width
            val rowBytes = (size + 7) / 8
            val bits = ByteArray(rowBytes * size)
            for (y in 0 until size) for (x in 0 until size) {
                if (m.get(x, y).toInt() == 1) {
                    val i = y * rowBytes + x / 8
                    bits[i] = (bits[i].toInt() or (0x80 ushr (x % 8))).toByte()
                }
            }
            Result(size, q.version.versionNumber, bits)
        } catch (e: Exception) {
            null
        }
    }
}

/**
 * #329 PR 5 plan v16 §2.1: the ClipDescription extra that marks a copied code as sensitive. Android 13 (API 33) has
 * the constant; on Android 12 the same literal key is set, its effect there is unverified (plan ⚠️).
 */
object ClipSensitive {
    const val EXTRA = "android.content.extra.IS_SENSITIVE"

    /** the extra key to set for this API level; null below Android 12, which the app does not run on (minSdk 31) */
    fun key(sdk: Int): String? = if (sdk >= 31) EXTRA else null
}
