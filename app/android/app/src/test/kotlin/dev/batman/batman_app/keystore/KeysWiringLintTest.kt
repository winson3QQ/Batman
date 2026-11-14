package dev.batman.batman_app.keystore

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

// Review round 3 A-MAJOR-1 (b) / round 4: Keys.handlers is the one place where the real Keystore levels, the build's
// devTrust and owner_enc's public key reach KeyHandlers; Keys needs AndroidKeyStore, so the JVM cannot run it. This
// SOURCE LINT pins the wiring: levels come from Keys.levels() itself (each key's level(it) unchanged), devTrust is
// passed through unchanged, and ownerEncPub is owner_enc's key. A lint, not a behaviour test — the behaviour test is
// androidTest KeyHandlersDeviceTest (needs a device / emulator). It fails when it cannot read the file.
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
        // round 4: the key a sig_enc may bind is owner_enc's (MK3, OWNER_SIGN, passed every JVM and emulator test)
        assertTrue("ownerEncPub must be OWNER_ENC's: $body", Regex("""\n\s*override fun ownerEncPub\(\) = publicKey65\(KeyRole\.OWNER_ENC\)(?:\n|$)""").containsMatchIn(body))
        assertTrue("exactly one ownerEncPub override: $body", Regex("""fun ownerEncPub\(""").findAll(body).count() == 1)
    }

    // round 4 (A MK5): Keys.levels() is each key's own live level, not a mapped one
    @Test fun levelsAreEachKeysOwnLevel() {
        assertTrue("Keys.levels must map level(it) unchanged", Regex("""\n    fun levels\(\): Map<KeyRole, Int\?> = KeyRole\.values\(\)\.associateWith \{ level\(it\) \}\n""").containsMatchIn(src))
        assertTrue("one Keys.levels + the override in handlers", Regex("""\n\s*(override )?fun levels\(""").findAll(src).count() == 2)
    }
}
