package dev.batman.batman_app.qr

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #329 PR 5 plan v16 §2.1: the code text never reaches a log. A source lint (QrMatrixTest is the behaviour test): the
 * QR encoder file, and MainActivity's qrMatrix / clipboard handlers, hold no logging call. Fails when a file is missing.
 */
class QrClipLogLintTest {
    private val banned = listOf("Log.", "println", "printStackTrace")

    private fun code(path: String): String = File(path)
        .also { assertTrue("$path not found from ${File(".").absolutePath}", it.isFile) }
        .readText().lines().filterNot { it.trimStart().startsWith("//") || it.trimStart().startsWith("*") }.joinToString("\n")

    @Test fun theEncoderFileLogsNothing() {
        val src = code("src/main/kotlin/dev/batman/batman_app/qr/QrMatrix.kt")
        assertEquals(emptyList<String>(), banned.filter { it in src })
    }

    @Test fun theClipboardAndQrHandlersLogNothing() {
        val src = code("src/main/kotlin/dev/batman/batman_app/MainActivity.kt").lines()
        val handlers = src.filter { l -> listOf("\"qrMatrix\"", "\"copyCode\"", "\"clearClip\"").any { it in l } }
        assertEquals("three handler lines", 3, handlers.size)
        // the two helper functions, from their declaration to the next blank line
        val bodies = listOf("private fun copyCode(", "private fun MethodChannel.Result.clipCall(").map { start ->
            val i = src.indexOfFirst { start in it }
            assertTrue("$start not found", i >= 0)
            src.drop(i).takeWhile { it.isNotBlank() }.joinToString("\n")
        }
        val qrBlock = src.dropWhile { "\"qrMatrix\"" !in it }.take(5).joinToString("\n")
        val all = (handlers + bodies + qrBlock).joinToString("\n")
        assertEquals(emptyList<String>(), banned.filter { it in all })
    }
}
