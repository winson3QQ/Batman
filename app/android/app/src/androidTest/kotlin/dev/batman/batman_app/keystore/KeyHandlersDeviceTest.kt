package dev.batman.batman_app.keystore

import android.security.keystore.KeyInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.security.KeyFactory
import java.security.KeyStore
import java.security.PrivateKey
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Design 254-app-s1 §8-4 / review round 3 A-MAJOR-1: the REAL wiring of Keys.handlers() — the levels KeyHandlers
 * decides on are the Keystore's live ones, and the build's devTrust is passed through — on a device or emulator, with
 * test aliases ("bmtest-…", never the app's "batman-…" keys), deleted before and after.
 *
 * Run on the EMULATOR only (never with gradle connected* tasks — they touch every connected device):
 *   ./gradlew --offline -Pemulator-abi=true :app:assembleDevDebug :app:assembleDevDebugAndroidTest
 *   adb -s emulator-5554 install -r <app-dev-debug.apk>; adb -s emulator-5554 install -r <app-dev-debug-androidTest.apk>
 *   adb -s emulator-5554 shell am instrument -w -e class dev.batman.batman_app.keystore.KeyHandlersDeviceTest \
 *     dev.batman.app.dev.test/androidx.test.runner.AndroidJUnitRunner
 * Negative controls: Keys.handlers' levels replaced by constant STRONGBOX, or devTrust by `true` -> this FAILs.
 */
@RunWith(AndroidJUnit4::class)
class KeyHandlersDeviceTest {
    private val keys = Keys("bmtest")
    private val ks: KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    @Before fun clean() = KeyRole.values().forEach { keys.delete(it) }
    @After fun cleanUp() = KeyRole.values().forEach { keys.delete(it) }

    /** The level read here, independently of Keys.level. */
    private fun direct(role: KeyRole): Int? = when (val k = ks.getKey(keys.alias(role), null)) {
        null -> null
        is PrivateKey -> KeyFactory.getInstance(k.algorithm, "AndroidKeyStore").getKeySpec(k, KeyInfo::class.java).securityLevel
        is SecretKey -> (SecretKeyFactory.getInstance(k.algorithm, "AndroidKeyStore").getKeySpec(k, KeyInfo::class.java) as KeyInfo).securityLevel
        else -> error("$role: ${k.javaClass}")
    }

    @Test fun handlersDecideOnTheLiveKeystoreLevels_andTheBuildsDevTrust() {
        keys.firstRun()
        val levels = KeyRole.values().associateWith { direct(it) }
        android.util.Log.i("BMTEST", "levels $levels")
        assertTrue("every test key exists: $levels", levels.values.all { it != null })
        val bind = "batman-owner-enc-v1".toByteArray() + keys.publicKey65(KeyRole.OWNER_ENC)
        for (dev in listOf(false, true)) {
            val h = keys.handlers(dev)
            // keyLevels: the live levels and what KeyPolicy makes of them in this build
            @Suppress("UNCHECKED_CAST") val m = (h.keyLevels() as KeyAnswer.Ok).value as Map<String, Any?>
            for (r in KeyRole.values()) assertEquals("dev=$dev $r", levels[r], m[r.name])
            val a = KeyPolicy.abilities(levels, dev)
            assertEquals("dev=$dev", mapOf("appUsable" to a.appUsable, "claim" to a.claim, "login" to a.login, "recover" to a.recover,
                "makeNetwork" to a.makeNetwork, "softOwnerEnc" to a.softOwnerEnc), m.filterKeys { it !in KeyRole.values().map(KeyRole::name) })
            // sig_enc over this phone's owner_enc: refused exactly as KeyPolicy says for these levels and this build
            val no = KeyPolicy.refused(KeyOp.BIND_OWNER_ENC, levels, dev)
            val s = h.signOwner(bind)
            if (no == null) assertTrue("dev=$dev: $s", s is KeyAnswer.Ok)
            else assertEquals("dev=$dev", KeyAnswer.Err("keyLevel", no.role.name, no.level), s)
            if (!dev && levels[KeyRole.OWNER_ENC] == Level.SOFTWARE) assertTrue("field, SOFTWARE owner_enc: $s", s is KeyAnswer.Err && s.code == "keyLevel")
            // ecdh is for dev builds only: a field build answers so before any level
            if (!dev) assertEquals(KeyAnswer.Err("ecdh", "dev builds only", null), h.ecdh(keys.publicKey65(KeyRole.OWNER_SIGN)))
        }
    }
}
