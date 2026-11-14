package dev.batman.batman_app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Review round 2 MAJOR 1 (c): MainActivity holds no key logic of its own. Keys.sign / ecdh / seal are private (a direct
// call does not compile); this source lint catches the other bypass the compiler allows: MainActivity reaching the
// Keystore or a crypto primitive itself, or a key channel not forwarded to KeyHandlers. A lint, not a behaviour test
// (KeyHandlersTest is); it reads the source file and fails when it cannot.
class MainActivityKeyUseLintTest {
    private val src: String = File("src/main/kotlin/dev/batman/batman_app/MainActivity.kt")
        .also { assertTrue("MainActivity.kt not found from ${File(".").absolutePath}", it.isFile) }
        .readText()
        // comments say what is not done here; only code counts
        .lines().filterNot { it.trimStart().startsWith("//") }.joinToString("\n")

    @Test fun noKeystoreOrCryptoPrimitiveInMainActivity() {
        val banned = listOf("KeyStore", "Signature", "KeyAgreement", "Cipher", "getKey(", "PrivateKey", "SecretKey", "KeyPolicy")  // Keys.sign / ecdh / seal: private, the compiler refuses
        assertEquals(emptyList<String>(), banned.filter { it in src })
    }

    @Test fun everyKeyChannelForwardsToKeyHandlers() {
        for (m in listOf("keyLevels", "signOwner", "signAdmin", "ecdh", "seal")) {
            val line = src.lines().singleOrNull { it.trimStart().startsWith("\"$m\" ->") }
            assertTrue("$m: ${line ?: "no handler line"}", line != null && Regex("""^\s*"$m" -> keyCall\(result(, wipe = true)?\) \{ it\.$m\(""").containsMatchIn(line))
        }
        assertTrue("keyCall builds the handlers from Keys", "f(Keys().handlers(BuildConfig.DEV_TRUST))" in src)
    }
}
