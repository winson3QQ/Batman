package dev.batman.batman_app.keystore

import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import javax.crypto.KeyAgreement
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

// member-join M14 (Kotlin part) / M16: the `ecdh` channel's peer check, on the JVM (no provider curve check relied on).
class EcdhPeerTest {
    private val p = BigInteger("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)

    private fun b32(v: BigInteger): ByteArray = v.toByteArray().let { r -> ByteArray(32).also { o -> r.copyInto(o, maxOf(0, 32 - r.size), maxOf(0, r.size - 32)) } }
    private fun sec1(x: BigInteger, y: BigInteger) = byteArrayOf(4) + b32(x) + b32(y)
    private fun pair() = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private fun pointOf(k: java.security.PublicKey): ByteArray = (k as ECPublicKey).w.let { sec1(it.affineX, it.affineY) }

    @Test fun refusesWhatIsNotAPoint() {
        val good = pointOf(pair().public)
        assertNull("64 B", EcdhPeer.check(good.copyOfRange(0, 64)))
        assertNull("0x02 (compressed)", EcdhPeer.check(byteArrayOf(2) + good.copyOfRange(1, 65)))
        assertNull("x >= p", EcdhPeer.check(sec1(p, BigInteger.ONE)))
        assertNull("y >= p", EcdhPeer.check(sec1(BigInteger.ONE, p)))
        val off = good.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertNull("not on the curve", EcdhPeer.check(off))
        assertNull("the point at infinity (0, 0)", EcdhPeer.check(sec1(BigInteger.ZERO, BigInteger.ZERO)))
        assertNull("SEC1 infinity 0x00", EcdhPeer.check(ByteArray(65)))
        assertNull("null", EcdhPeer.check(null))
    }

    @Test fun aPointGivesTheSameEcdhAsSoftware() {
        val me = pair()
        val peer = pair()
        val pk = EcdhPeer.accept(true, pointOf(peer.public))
        assertNotNull(pk)
        val z = KeyAgreement.getInstance("ECDH").run { init(me.private); doPhase(pk, true); generateSecret() }
        val z2 = KeyAgreement.getInstance("ECDH").run { init(peer.private); doPhase(me.public, true); generateSecret() }
        assertEquals(32, z.size)
        assertArrayEquals(z2, z)
    }

    @Test fun fieldBuildsRefuse() {
        assertNull("DEV_TRUST = false", EcdhPeer.accept(false, pointOf(pair().public)))
    }
}
