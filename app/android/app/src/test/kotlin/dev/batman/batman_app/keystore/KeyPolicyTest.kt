package dev.batman.batman_app.keystore

import dev.batman.batman_app.keystore.Level.SOFTWARE
import dev.batman.batman_app.keystore.Level.STRONGBOX
import dev.batman.batman_app.keystore.Level.TRUSTED_ENVIRONMENT
import dev.batman.batman_app.keystore.Level.UNKNOWN
import dev.batman.batman_app.keystore.Level.UNKNOWN_SECURE
import android.security.keystore.KeyProperties
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

    // review round 3 B-MINOR-1 (a bug on main since e8d6510: the two were swapped, so "no assumptions" counted as
    // hardware). Pinned to the SDK constants (compile-time constants of the stub android.jar) and to the literals.
    @Test fun levelConstantsAreTheSdkOnes() {
        assertEquals(KeyProperties.SECURITY_LEVEL_UNKNOWN, UNKNOWN)
        assertEquals(KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE, UNKNOWN_SECURE)
        assertEquals(KeyProperties.SECURITY_LEVEL_SOFTWARE, SOFTWARE)
        assertEquals(KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT, TRUSTED_ENVIRONMENT)
        assertEquals(KeyProperties.SECURITY_LEVEL_STRONGBOX, STRONGBOX)
        assertEquals(-2, UNKNOWN); assertEquals(-1, UNKNOWN_SECURE)
        for (role in KeyRole.values()) for (dev in listOf(true, false)) {
            assertFalse("$role -2 dev=$dev", KeyPolicy.allowed(role, -2, dev))
            assertTrue("$role -1 dev=$dev", KeyPolicy.allowed(role, -1, dev))
        }
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

    // M3: the gate of the handlers that use a key (MainActivity.gate): operation x key x level x flavor.
    private val tee = KeyRole.values().associateWith<KeyRole, Int?> { TRUSTED_ENVIRONMENT }
    private val every = listOf<Int?>(STRONGBOX, TRUSTED_ENVIRONMENT, UNKNOWN_SECURE, SOFTWARE, UNKNOWN, null, 3, 99, -3)
    private val needs = mapOf(
        KeyOp.SIGN_OWNER to setOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN),
        KeyOp.BIND_OWNER_ENC to setOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN, KeyRole.OWNER_ENC),
        KeyOp.SIGN_ADMIN to setOf(KeyRole.RECORD_AES, KeyRole.ADMIN_SIGN),
        KeyOp.ECDH to setOf(KeyRole.RECORD_AES, KeyRole.OWNER_ENC),
        KeyOp.SEAL to setOf(KeyRole.RECORD_AES),
    )

    @Test fun gateTableOperationKeyLevelFlavor() {
        assertEquals(KeyOp.values().toSet(), needs.keys)
        var rows = 0
        for (op in KeyOp.values()) for (role in KeyRole.values()) for (l in every) for (dev in listOf(true, false)) {
            val r = KeyPolicy.refused(op, tee + (role to l), dev)
            // the other three keys are TEE, so only [role] at [l] can refuse — and only when [op] uses that key
            val ok = role !in needs.getValue(op) || l in hw || (role == KeyRole.OWNER_ENC && l == SOFTWARE && dev)
            val what = "$op $role level=$l dev=$dev"
            if (ok) assertEquals(what, null, r) else {
                assertEquals(what, role, r?.role)
                assertEquals(what, l, r?.level)
            }
            rows++
        }
        assertEquals(5 * 4 * 9 * 2, rows)
    }

    @Test fun gateRefusesAKeyWithNoEntry() {
        for (op in KeyOp.values()) for (dev in listOf(true, false)) {
            assertEquals("$op", KeyRole.RECORD_AES, KeyPolicy.refused(op, emptyMap(), dev)?.role)
            for (role in needs.getValue(op)) assertEquals("$op without $role", role, KeyPolicy.refused(op, tee - role, dev)?.role)
        }
    }

    @Test fun gateOnTheS20() {
        // dev: everything; field: the SOFTWARE owner_enc refuses ECDH and sig_enc (the claim: B-MAJOR-1), nothing else
        for (op in KeyOp.values()) assertEquals("$op", null, KeyPolicy.refused(op, s20, devTrust = true))
        val enc = setOf(KeyOp.ECDH, KeyOp.BIND_OWNER_ENC)
        for (op in KeyOp.values().filter { it !in enc }) assertEquals("$op", null, KeyPolicy.refused(op, s20, devTrust = false))
        for (op in enc) assertEquals("$op", KeyRole.OWNER_ENC, KeyPolicy.refused(op, s20, devTrust = false)?.role)
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
