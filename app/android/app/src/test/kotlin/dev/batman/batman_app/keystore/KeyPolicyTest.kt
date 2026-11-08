package dev.batman.batman_app.keystore

import dev.batman.batman_app.keystore.Level.SOFTWARE
import dev.batman.batman_app.keystore.Level.STRONGBOX
import dev.batman.batman_app.keystore.Level.TRUSTED_ENVIRONMENT
import dev.batman.batman_app.keystore.Level.UNKNOWN
import dev.batman.batman_app.keystore.Level.UNKNOWN_SECURE
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Design v8.5.1 §8.4: injected levels x flavor.
class KeyPolicyTest {
    private val hw = listOf(STRONGBOX, TRUSTED_ENVIRONMENT, UNKNOWN_SECURE)

    @Test fun everyKeyAcceptsHardwareInBothBuilds() {
        for (role in KeyRole.values()) for (l in hw) for (dev in listOf(true, false))
            assertTrue("$role $l dev=$dev", KeyPolicy.allowed(role, l, dev))
    }

    @Test fun unknownIsRefusedForEveryKey() {
        for (role in KeyRole.values()) for (dev in listOf(true, false))
            assertFalse("$role UNKNOWN dev=$dev", KeyPolicy.allowed(role, UNKNOWN, dev))
    }

    @Test fun softwareOnlyForOwnerEncInTheDevBuild() {
        for (role in listOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN, KeyRole.ADMIN_SIGN)) for (dev in listOf(true, false))
            assertFalse("$role SOFTWARE dev=$dev", KeyPolicy.allowed(role, SOFTWARE, dev))
        assertTrue(KeyPolicy.allowed(KeyRole.OWNER_ENC, SOFTWARE, devTrust = true))
        assertFalse(KeyPolicy.allowed(KeyRole.OWNER_ENC, SOFTWARE, devTrust = false))
    }

    // the S20 (facts §9): signing / AES in StrongBox, owner_enc SOFTWARE
    private val s20 = mapOf(
        KeyRole.RECORD_AES to STRONGBOX, KeyRole.OWNER_SIGN to STRONGBOX,
        KeyRole.ADMIN_SIGN to STRONGBOX, KeyRole.OWNER_ENC to SOFTWARE,
    )

    @Test fun s20DevBuildClaimsWithTheWarning() {
        val a = KeyPolicy.abilities(s20, devTrust = true)
        assertEquals(KeyPolicy.Abilities(true, true, true, true, true, softOwnerEnc = true), a)
    }

    @Test fun s20FieldBuildCannotClaimOrRecoverButCanLogIn() {
        val a = KeyPolicy.abilities(s20, devTrust = false)
        assertTrue(a.appUsable); assertTrue(a.login); assertTrue(a.makeNetwork)
        assertFalse(a.claim); assertFalse(a.recover); assertFalse(a.softOwnerEnc)
    }

    @Test fun softwareRecordKeyDisablesTheAppInBothBuilds() {
        for (dev in listOf(true, false)) {
            val a = KeyPolicy.abilities(s20 + (KeyRole.RECORD_AES to SOFTWARE), dev)
            assertFalse(a.appUsable); assertFalse(a.claim); assertFalse(a.login); assertFalse(a.makeNetwork)
        }
    }

    @Test fun singleKeyLossRows() {
        // §4.1 "單一金鑰遺失": owner signing gone -> no login / claim / recovery; admin gone -> no network; enc gone -> no claim / recovery
        val noSign = KeyPolicy.abilities(s20 - KeyRole.OWNER_SIGN, devTrust = true)
        assertTrue(noSign.appUsable); assertFalse(noSign.login); assertFalse(noSign.claim); assertFalse(noSign.recover)
        val noAdmin = KeyPolicy.abilities(s20 - KeyRole.ADMIN_SIGN, devTrust = true)
        assertTrue(noAdmin.login); assertFalse(noAdmin.makeNetwork)
        val noEnc = KeyPolicy.abilities(s20 - KeyRole.OWNER_ENC, devTrust = true)
        assertTrue(noEnc.login); assertFalse(noEnc.claim); assertFalse(noEnc.recover)
        val noAes = KeyPolicy.abilities(s20 - KeyRole.RECORD_AES, devTrust = true)
        assertFalse(noAes.appUsable); assertFalse(noAes.login)
    }

    @Test fun levelImprovingNeverDisables() {
        // the live level decides; TEE -> STRONGBOX or TEE -> UNKNOWN_SECURE after an upgrade stays usable
        for (l in hw) assertTrue(KeyPolicy.abilities(s20 + (KeyRole.OWNER_SIGN to l), devTrust = false).login)
    }

    @Test fun rankOrderForKeepingTheBetterKey() {
        val order = listOf(STRONGBOX, TRUSTED_ENVIRONMENT, UNKNOWN_SECURE, SOFTWARE, UNKNOWN).map(Level::rank)
        assertEquals(order.sortedDescending(), order)
        assertEquals(order.toSet().size, order.size)
    }
}
