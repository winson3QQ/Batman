package dev.batman.batman_app.keystore

import dev.batman.batman_app.keystore.Level.SOFTWARE
import dev.batman.batman_app.keystore.Level.STRONGBOX
import dev.batman.batman_app.keystore.Level.TRUSTED_ENVIRONMENT
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.PublicKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Design 254-app-s1 §8-4 (review round 2, MAJOR 1/2): the channel's key handlers driven with fake levels and fake keys.
// A level the build does not allow (or no key) -> error `keyLevel` and the key is never used; levels that fit -> the
// key is used. Negative controls: the gate call removed in KeyHandlers.use, the levels read replaced by constant
// hardware levels, or sig_enc mapped back to SIGN_OWNER -> these FAIL.
class KeyHandlersTest {
    /**
     * Records every call; [levels] is what the Keystore answers (null = it throws, like an unreadable key); a key in
     * [unreadable] throws when its own level is read, and makes levels() (all four) throw too.
     */
    private class FakeKeys(var levels: Map<KeyRole, Int?>?, val unreadable: Set<KeyRole> = emptySet()) : KeyUses {
        val calls = mutableListOf<String>()
        override fun levels(): Map<KeyRole, Int?> {
            calls += "levels"
            if (unreadable.isNotEmpty()) throw IllegalStateException("keystore busy: $unreadable")
            return levels ?: throw IllegalStateException("keystore busy")
        }
        override fun level(role: KeyRole): Int? {
            calls += "level $role"
            if (role in unreadable) throw IllegalStateException("keystore busy: $role")
            return (levels ?: throw IllegalStateException("keystore busy"))[role]
        }
        override fun sign(role: KeyRole, input: ByteArray): ByteArray { calls += "sign $role"; return byteArrayOf(0x30, 1) }
        override fun ecdh(peer: PublicKey): ByteArray { calls += "ecdh"; return ByteArray(32) { 7 } }
        override fun seal(plain: ByteArray, aad: ByteArray): ByteArray { calls += "seal"; return byteArrayOf(9) }
        override fun open(sealed: ByteArray, aad: ByteArray): ByteArray { calls += "open"; return byteArrayOf(5, 6) }
        /** this phone's owner_enc public key (bindInput binds exactly this one) */
        override fun ownerEncPub(): ByteArray = ByteArray(65) { 4 }
        val used get() = calls.filter { it != "levels" && !it.startsWith("level ") }
    }

    private val tee = KeyRole.values().associateWith<KeyRole, Int?> { TRUSTED_ENVIRONMENT }
    // the S20 (facts §9): signing / AES in StrongBox, owner_enc SOFTWARE
    private val s20 = KeyRole.values().associateWith<KeyRole, Int?> { STRONGBOX } + (KeyRole.OWNER_ENC to SOFTWARE)

    private val bindInput = "batman-owner-enc-v1".toByteArray() + ByteArray(65) { 4 }
    private val authInput = "batman-owner-auth-v1".toByteArray() + ByteArray(64) { 1 }
    private val opInput = "batman-owner-op-v1".toByteArray() + ByteArray(97) { 2 }
    private val peer: ByteArray = (KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
        .generateKeyPair().public as ECPublicKey).w.let { w -> byteArrayOf(4) + b32(w.affineX) + b32(w.affineY) }

    private fun b32(v: BigInteger) = v.toByteArray().let { r -> ByteArray(32).also { o -> r.copyInto(o, maxOf(0, 32 - r.size), maxOf(0, r.size - 32)) } }

    /** Each handler of the channel, the keys it needs, and the call. */
    private class Op(val name: String, val needs: Set<KeyRole>, val call: (KeyHandlers) -> KeyAnswer)

    private val ops = listOf(
        Op("signOwner(owner-auth)", setOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN)) { it.signOwner(authInput) },
        Op("signOwner(owner-op)", setOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN)) { it.signOwner(opInput) },
        Op("signOwner(sig_enc)", setOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN, KeyRole.OWNER_ENC)) { it.signOwner(bindInput) },
        Op("signAdmin", setOf(KeyRole.RECORD_AES, KeyRole.ADMIN_SIGN)) { it.signAdmin(byteArrayOf(0x84.toByte())) },
        Op("ecdh", setOf(KeyRole.RECORD_AES, KeyRole.OWNER_ENC)) { it.ecdh(peer) },
        Op("seal", setOf(KeyRole.RECORD_AES)) { it.seal(byteArrayOf(1), byteArrayOf(2)) },
    )

    @Test fun everyKeyFits_theKeyIsUsed() {
        for (op in ops) for (dev in listOf(true, false)) {
            if (op.name == "ecdh" && !dev) continue // dev builds only (below)
            val k = FakeKeys(tee)
            val a = op.call(KeyHandlers(k, dev))
            assertTrue("${op.name} dev=$dev: $a", a is KeyAnswer.Ok)
            assertEquals("${op.name} dev=$dev", 1, k.used.size)
        }
    }

    @Test fun aKeyNotAllowedOrMissing_refusedAsKeyLevel_andNoKeyUsed() {
        var rows = 0
        for (op in ops) for (role in op.needs) for (l in listOf<Int?>(SOFTWARE, Level.UNKNOWN, null, 99)) for (dev in listOf(true, false)) {
            if (op.name == "ecdh" && !dev) continue
            if (role == KeyRole.OWNER_ENC && l == SOFTWARE && dev) continue // allowed in the dev build (S20 below)
            val what = "${op.name} $role=$l dev=$dev"
            val k = FakeKeys(tee + (role to l))
            assertEquals(what, KeyAnswer.Err("keyLevel", role.name, l), op.call(KeyHandlers(k, dev)))
            assertEquals("$what: the key was used", emptyList<String>(), k.used)
            assertEquals("$what: the levels were read live", listOf("levels"), k.calls)
            rows++
        }
        assertEquals(86, rows)
    }

    // B-MAJOR-1: the S20 in a field build must not claim: sig_enc vouches for a SOFTWARE owner_enc
    @Test fun s20Field_sigEncRefused_loginAndOpsStillSign() {
        val k = FakeKeys(s20)
        val h = KeyHandlers(k, devTrust = false)
        assertEquals(KeyAnswer.Err("keyLevel", "OWNER_ENC", SOFTWARE), h.signOwner(bindInput))
        assertEquals(emptyList<String>(), k.used)
        assertTrue(h.signOwner(authInput) is KeyAnswer.Ok)
        assertTrue(h.signOwner(opInput) is KeyAnswer.Ok)
        assertEquals(listOf("sign OWNER_SIGN", "sign OWNER_SIGN"), k.used)
    }

    // review round 3 B-MINOR-2: sig_enc must bind THIS phone's owner_enc; another key (or a cut one) is refused before
    // the owner key is touched. Negative control: the comparison dropped -> FAIL
    @Test fun sigEncBindingAnotherKey_refused_noKeyUsed() {
        val label = "batman-owner-enc-v1".toByteArray()
        for ((what, input) in listOf(
            "another public key" to label + ByteArray(65) { 5 },
            "64 bytes" to label + ByteArray(64) { 4 },
            "66 bytes" to label + ByteArray(66) { 4 },
        )) for (dev in listOf(true, false)) {
            val k = FakeKeys(tee)
            assertEquals("$what dev=$dev", KeyAnswer.Err("keystore", "IllegalArgumentException: refused: sig_enc binds a key that is not this phone's owner_enc", null), KeyHandlers(k, dev).signOwner(input))
            assertEquals("$what dev=$dev", emptyList<String>(), k.used)
        }
        val k = FakeKeys(tee)
        assertTrue(KeyHandlers(k, false).signOwner(bindInput) is KeyAnswer.Ok)
        assertEquals(listOf("sign OWNER_SIGN"), k.used)
    }

    @Test fun s20Dev_sigEncSigned() {
        val k = FakeKeys(s20)
        assertTrue(KeyHandlers(k, devTrust = true).signOwner(bindInput) is KeyAnswer.Ok)
        assertEquals(listOf("sign OWNER_SIGN"), k.used)
    }

    // review round 2 MINOR 4: an unreadable key is an error, never a "no key" (null) answer
    @Test fun unreadableLevels_errorKeystore_neverALostKey_andNoKeyUsed() {
        val k = FakeKeys(null)
        val h = KeyHandlers(k, devTrust = true)
        assertEquals(KeyAnswer.Err("keystore", "IllegalStateException", null), h.keyLevels())
        for (op in ops) {
            val a = op.call(h)
            assertTrue("${op.name}: $a", a is KeyAnswer.Err && a.code != "keyLevel")
        }
        assertEquals(emptyList<String>(), k.used)
    }

    @Test fun keyLevels_theFullShape_aLostKeyIsNull() {
        val a = KeyHandlers(FakeKeys(tee + (KeyRole.ADMIN_SIGN to null)), devTrust = false).keyLevels()
        @Suppress("UNCHECKED_CAST") val m = (a as KeyAnswer.Ok).value as Map<String, Any?>
        assertEquals(setOf("RECORD_AES", "OWNER_SIGN", "ADMIN_SIGN", "OWNER_ENC", "appUsable", "claim", "login", "recover", "makeNetwork", "softOwnerEnc"), m.keys)
        assertEquals(null, m["ADMIN_SIGN"])
        assertEquals(TRUSTED_ENVIRONMENT, m["OWNER_SIGN"])
        assertEquals(false, m["makeNetwork"]); assertEquals(true, m["claim"])
    }

    @Test fun ecdh_fieldBuildOrNotAPoint_refusedBeforeAnyKeystoreRead() {
        val k = FakeKeys(tee)
        assertEquals(KeyAnswer.Err("ecdh", "dev builds only", null), KeyHandlers(k, devTrust = false).ecdh(peer))
        assertEquals(KeyAnswer.Err("ecdh", "not a P-256 point", null), KeyHandlers(k, devTrust = true).ecdh(peer.copyOf(64)))
        assertEquals(emptyList<String>(), k.calls)
        val z = (KeyHandlers(k, devTrust = true).ecdh(peer) as KeyAnswer.Ok).value as ByteArray
        assertArrayEquals(ByteArray(32) { 7 }, z)
    }

    @Test fun missingArgument_anErrorAfterTheGate_noKeyUsed() {
        val k = FakeKeys(tee)
        assertEquals(KeyAnswer.Err("keystore", "IllegalArgumentException: no input", null), KeyHandlers(k, true).signOwner(null))
        assertEquals(KeyAnswer.Err("keystore", "IllegalArgumentException: no plain", null), KeyHandlers(k, true).seal(null, byteArrayOf()))
        assertEquals(emptyList<String>(), k.used)
    }

    // #329 PR 7 T1: `open` (record decryption) passes the gate on the record AES key's level ONLY, with the same error
    // codes as the other uses (X26 on the Dart side reads `keyLevel`). Negative controls: KeyHandlers.open without the
    // gate (the record AES rows FAIL), or gated on all four levels / KeyOp with more keys (the other-key rows FAIL).
    private val sealedRec = ByteArray(40) { 3 }

    @Test fun open_recordAesFits_opened_onlyItsLevelRead() {
        for (dev in listOf(true, false)) for (l in listOf(STRONGBOX, TRUSTED_ENVIRONMENT, Level.UNKNOWN_SECURE)) {
            val k = FakeKeys(tee + (KeyRole.RECORD_AES to l))
            val a = KeyHandlers(k, dev).open(sealedRec, byteArrayOf(1))
            assertArrayEquals("dev=$dev aes=$l", byteArrayOf(5, 6), (a as KeyAnswer.Ok).value as ByteArray)
            assertEquals("dev=$dev aes=$l", listOf("level RECORD_AES", "open"), k.calls)
        }
    }

    @Test fun open_recordAesNotAllowedOrMissing_refusedAsKeyLevel_neverOpened() {
        for (l in listOf<Int?>(SOFTWARE, Level.UNKNOWN, null, 99)) for (dev in listOf(true, false)) {
            val k = FakeKeys(tee + (KeyRole.RECORD_AES to l))
            assertEquals("aes=$l dev=$dev", KeyAnswer.Err("keyLevel", "RECORD_AES", l), KeyHandlers(k, dev).open(sealedRec, byteArrayOf(1)))
            assertEquals("aes=$l dev=$dev", listOf("level RECORD_AES"), k.calls)
        }
    }

    // the review's case (owner_console.dart:544, owner.rs:1294): another key unreadable, missing or not allowed must not
    // make a record unopenable — the Dart callers would take a failed open for "no record" and write over it
    @Test fun open_anotherKeyUnreadableMissingOrNotAllowed_stillOpens() {
        val others = KeyRole.values().filter { it != KeyRole.RECORD_AES }
        val cases = listOf(
            "all three unreadable" to FakeKeys(tee, unreadable = others.toSet()),
            "all three missing" to FakeKeys(tee + others.associateWith { null }),
            "all three SOFTWARE" to FakeKeys(tee + others.associateWith { SOFTWARE }),
        ) + others.map { "$it unreadable" to FakeKeys(tee, unreadable = setOf(it)) }
        for ((what, k) in cases) for (dev in listOf(true, false)) {
            k.calls.clear()
            val a = KeyHandlers(k, dev).open(sealedRec, byteArrayOf(1))
            assertTrue("$what dev=$dev: $a", a is KeyAnswer.Ok)
            assertEquals("$what dev=$dev", listOf("level RECORD_AES", "open"), k.calls)
        }
    }

    @Test fun open_recordAesUnreadable_errorKeystore_notKeyLevel_neverOpened() {
        val k = FakeKeys(tee, unreadable = setOf(KeyRole.RECORD_AES))
        assertEquals(KeyAnswer.Err("keystore", "IllegalStateException: keystore busy: RECORD_AES", null), KeyHandlers(k, true).open(sealedRec, byteArrayOf(1)))
        assertEquals(emptyList<String>(), k.used)
    }

    @Test fun open_missingArgument_errorKeystore_neverOpened() {
        val k = FakeKeys(tee)
        assertEquals(KeyAnswer.Err("keystore", "IllegalArgumentException: no record", null), KeyHandlers(k, true).open(null, byteArrayOf(1)))
        assertEquals(KeyAnswer.Err("keystore", "IllegalArgumentException: no aad", null), KeyHandlers(k, true).open(sealedRec, null))
        assertEquals(emptyList<String>(), k.used)
    }

    // #329 PR 7 T2 (white box): KeyAnswer.deliver hands the answer to success, THEN zeroes a wiped ByteArray (the codec
    // encoded it inside success). Negative control: the fill(0) removed -> the "zeroed after" assertion FAILs.
    @Test fun deliver_wipe_zeroesTheBytesAfterSuccess_notBefore() {
        val plain = ByteArray(16) { (it + 1).toByte() }
        var seen: ByteArray? = null
        KeyAnswer.deliver(KeyAnswer.Ok(plain), wipe = true, success = { seen = (it as ByteArray).copyOf() }, error = { _, _, _ -> error("no error") })
        assertArrayEquals("success saw the plaintext", ByteArray(16) { (it + 1).toByte() }, seen)
        assertArrayEquals("zeroed after success", ByteArray(16), plain)
    }

    @Test fun deliver_noWipe_leavesTheBytes_errorsPassedThrough() {
        val sig = byteArrayOf(0x30, 1, 2)
        KeyAnswer.deliver(KeyAnswer.Ok(sig), wipe = false, success = {}, error = { _, _, _ -> error("no error") })
        assertArrayEquals(byteArrayOf(0x30, 1, 2), sig)
        val got = mutableListOf<Any?>()
        KeyAnswer.deliver(KeyAnswer.Err("keyLevel", "RECORD_AES", 0), wipe = true, success = { error("no success") }, error = { c, m, d -> got.addAll(listOf(c, m, d)) })
        assertEquals(listOf<Any?>("keyLevel", "RECORD_AES", 0), got)
    }
}
