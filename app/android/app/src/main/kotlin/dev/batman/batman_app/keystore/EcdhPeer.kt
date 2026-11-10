package dev.batman.batman_app.keystore

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.PublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

// 254-app-member-join §2: the `ecdh` channel's peer. Kotlin checks only the format: exactly 65 bytes, 0x04, x / y < p,
// and y² ≡ x³ − 3x + b (mod p) computed here with BigInteger (no reliance on the provider's own check); only then
// a PublicKey. The channel is for dev builds only. Which point it is (an approval's ephemeral key, from Rust's
// recipient_eph) is the Dart convention, not checked here (the same in-process honest boundary as SignAllowList).
object EcdhPeer {
    private val P = BigInteger("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    private val B = BigInteger("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)
    private val THREE = BigInteger.valueOf(3)

    /** (x, y) of a SEC1 uncompressed P-256 point on the curve, else null. */
    fun check(peer: ByteArray?): Pair<BigInteger, BigInteger>? {
        if (peer == null || peer.size != 65 || peer[0] != 0x04.toByte()) return null
        val x = BigInteger(1, peer.copyOfRange(1, 33))
        val y = BigInteger(1, peer.copyOfRange(33, 65))
        if (x >= P || y >= P) return null
        val lhs = y.multiply(y).mod(P)
        val rhs = x.multiply(x).multiply(x).subtract(THREE.multiply(x)).add(B).mod(P)
        return if (lhs == rhs) x to y else null
    }

    fun publicKey(x: BigInteger, y: BigInteger): PublicKey {
        val spec = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(ECParameterSpec::class.java)
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), spec))
    }

    /** The channel's whole decision: null (refused) unless a dev build and a point on the curve. */
    fun accept(devTrust: Boolean, peer: ByteArray?): PublicKey? {
        if (!devTrust) return null
        val (x, y) = check(peer) ?: return null
        return publicKey(x, y)
    }
}
