package dev.batman.batman_app.qr

import com.google.zxing.BinaryBitmap
import com.google.zxing.InvertedLuminanceSource
import com.google.zxing.LuminanceSource
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.nio.ByteBuffer

/**
 * 254-app-qr §2: one camera frame's Y plane -> the QR text, or null. Pure (ZXing core only), so the JVM tests run the
 * same code as [QrScanActivity]. Never throws; the text is never logged.
 */
object QrDecode {
    /** longer QRs are ignored (§2: no legal payload is this long, and no large string crosses the channel) */
    const val MAX_LEN = 4096

    /**
     * A CameraX YUV_420_888 Y plane: copies `buffer.remaining()` bytes — the last row is often shorter than [rowStride]
     * (A r2-m2). The Y plane's pixelStride is 1 (ImageFormat.YUV_420_888); anything else -> null, no guessing.
     */
    fun fromPlane(buffer: ByteBuffer, rowStride: Int, pixelStride: Int, w: Int, h: Int): String? = try {
        if (pixelStride != 1) null
        else ByteArray(buffer.remaining()).let { y -> buffer.get(y); decode(y, rowStride, w, h) }
    } catch (e: Exception) {
        null
    }

    /**
     * dataWidth = [rowStride] skips the row padding; a dark-background code (`qrencode -t ansiutf8`) is tried inverted.
     * No TRY_HARDER: U4 (a rotated code) passes without it, so it is not set (§5 U4 rule).
     */
    fun decode(y: ByteArray, rowStride: Int, w: Int, h: Int): String? = try {
        val src = PlanarYUVLuminanceSource(y, rowStride, h, 0, 0, w, h, false)
        val text = try {
            read(src)
        } catch (e: NotFoundException) {
            read(InvertedLuminanceSource(src))
        }
        text.takeIf { it.length <= MAX_LEN }
    } catch (e: Exception) {
        null
    }

    private fun read(src: LuminanceSource): String =
        QRCodeReader().decode(BinaryBitmap(HybridBinarizer(src))).text
}
