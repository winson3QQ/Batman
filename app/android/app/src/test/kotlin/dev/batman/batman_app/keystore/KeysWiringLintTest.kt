package dev.batman.batman_app.keystore

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

// Review round 3 A-MAJOR-1 (b): Keys.handlers is the one place where the real Keystore levels and the build's devTrust
// reach KeyHandlers; Keys needs AndroidKeyStore, so the JVM cannot run it. This SOURCE LINT pins the wiring: levels
// come from Keys.levels() itself and devTrust is passed through unchanged. A lint, not a behaviour test — the
// behaviour test is androidTest KeyHandlersDeviceTest (needs a device / emulator). It fails when it cannot read the file.
class KeysWiringLintTest {
    private val src: String = File("src/main/kotlin/dev/batman/batman_app/keystore/Keys.kt")
        .also { assertTrue("Keys.kt not found from ${File(".").absolutePath}", it.isFile) }
        .readText()

    @Test fun handlersTakeTheLiveLevelsAndTheBuildsDevTrust() {
        val block = Regex("""fun handlers\(devTrust: Boolean\) = KeyHandlers\(object : KeyUses \{(.*?)\n    \}, (\w+)\)""", RegexOption.DOT_MATCHES_ALL)
            .find(src)
        assertTrue("Keys.handlers not found in its expected shape", block != null)
        val body = block!!.groupValues[1]
        assertTrue("levels must be Keys.levels(): $body", Regex("""\n\s*override fun levels\(\) = this@Keys\.levels\(\)\n""").containsMatchIn(body))
        assertTrue("exactly one levels override: $body", Regex("""fun levels\(""").findAll(body).count() == 1)
        assertTrue("devTrust must be passed through: ${block.groupValues[2]}", block.groupValues[2] == "devTrust")
    }
}
