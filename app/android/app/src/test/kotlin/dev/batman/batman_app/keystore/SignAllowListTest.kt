package dev.batman.batman_app.keystore

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Inputs mirror what batman-proto builds (sig.rs / cose.rs); the Sig_structure here is the vector cose.net_config
// sig_structure's shape: 84 6a "Signature1" <protected> <aad> <payload>.
class SignAllowListTest {
    private fun a(s: String) = s.toByteArray(Charsets.US_ASCII)
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun bstr(b: ByteArray): ByteArray = when {
        b.size < 24 -> byteArrayOf((0x40 or b.size).toByte()) + b
        b.size < 256 -> byteArrayOf(0x58, b.size.toByte()) + b
        else -> byteArrayOf(0x59, (b.size shr 8).toByte(), b.size.toByte()) + b
    }
    private fun tbs(aad: String, payload: ByteArray = ByteArray(300) { 7 }, ctx: String = "Signature1", head: Int = 0x84): ByteArray {
        val prot = hex("a20126036d6261746d616e2f6e6574636667")
        return byteArrayOf(head.toByte(), (0x60 or ctx.length).toByte()) + a(ctx) + bstr(prot) + bstr(a(aad)) + bstr(payload)
    }

    @Test fun ownerSignsItsThreeLabelsOnly() {
        val h = ByteArray(64) { 1 }
        for (l in listOf("batman-owner-enc-v1", "batman-owner-auth-v1", "batman-owner-op-v1")) assertTrue(l, SignAllowList.ownerMaySign(a(l) + h))
        assertFalse("bare label", SignAllowList.ownerMaySign(a("batman-owner-op-v1")))
        assertFalse("admin structure", SignAllowList.ownerMaySign(tbs("batman-netcfg-v1")))
        assertFalse("node label", SignAllowList.ownerMaySign(a("batman-node-static-v1") + h))
        assertFalse("near miss", SignAllowList.ownerMaySign(a("batman-owner-op-v2") + h))
        assertFalse("empty", SignAllowList.ownerMaySign(ByteArray(0)))
    }

    @Test fun adminSignsSigStructuresWithItsLabels() {
        for (l in listOf("batman-netcfg-v1", "batman-members-v1", "batman-secrets-v1")) assertTrue(l, SignAllowList.adminMaySign(tbs(l)))
        assertTrue("short payload", SignAllowList.adminMaySign(tbs("batman-netcfg-v1", ByteArray(5))))
    }

    @Test fun adminRefusesEverythingElse() {
        val h = ByteArray(64) { 1 }
        assertFalse("owner input", SignAllowList.adminMaySign(a("batman-owner-op-v1") + h))
        assertFalse("other aad", SignAllowList.adminMaySign(tbs("batman-invite-v1")))
        assertFalse("empty aad", SignAllowList.adminMaySign(tbs("")))
        assertFalse("Signature context", SignAllowList.adminMaySign(tbs("batman-netcfg-v1", ctx = "Signature")))
        assertFalse("array of 3", SignAllowList.adminMaySign(tbs("batman-netcfg-v1", head = 0x83)))
        val t = tbs("batman-members-v1")
        assertFalse("trailing byte", SignAllowList.adminMaySign(t + byteArrayOf(0)))
        assertFalse("truncated", SignAllowList.adminMaySign(t.copyOfRange(0, t.size - 1)))
        assertFalse("empty", SignAllowList.adminMaySign(ByteArray(0)))
    }
}

// The real Sig_structures from tests/vectors/219-protocol/vectors.json (what batman-proto's cose.rs builds,
// byte-exact) and the real owner-op / claim_replay inputs: allowed for the right key, refused for the other.
class SignAllowListVectorTest {
    private val json: String = java.io.File("../../../tests/vectors/219-protocol/vectors.json").readText()
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun field(group: String, key: String): ByteArray {
        val g = json.indexOf("\"$group\"").also { require(it >= 0) { "no group $group" } }
        val m = Regex(""""$key"\s*:\s*"([0-9a-f]+)"""").find(json, g) ?: error("no $group.$key")
        return hex(m.groupValues[1])
    }

    @Test fun vectorSigStructuresAreAdminOnly() {
        // net_secrets has no sig_structure field in the vectors (its Sign1 is checked in batman-proto's tests)
        for (g in listOf("net_config", "member_list")) {
            val t = field(g, "sig_structure")
            assertTrue("$g admin", SignAllowList.adminMaySign(t))
            assertFalse("$g owner", SignAllowList.ownerMaySign(t))
        }
    }

    @Test fun vectorOwnerInputsAreOwnerOnly() {
        for ((g, k) in listOf("owner_op" to "input", "claim_replay" to "owner_op_input")) {
            val t = field(g, k)
            assertTrue("$g.$k owner", SignAllowList.ownerMaySign(t))
            assertFalse("$g.$k admin", SignAllowList.adminMaySign(t))
        }
    }
}
