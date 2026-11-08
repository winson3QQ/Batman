package dev.batman.batman_app.keystore

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

// Design §4 / §4.1: the four Keystore keys. Kotlin generates and uses them; it never reads records (the Rust store owns
// them) and signs only allow-listed bytes. Every key's level is READ BACK (KeyInfo.securityLevel), never assumed.
class Keys(private val prefix: String = "batman") {
    private val ks: KeyStore = KeyStore.getInstance(ANDROID_KS).apply { load(null) }

    fun alias(role: KeyRole) = "$prefix-${role.name.lowercase()}-v1"
    fun exists(role: KeyRole) = ks.containsAlias(alias(role))

    /** The live level of [role]'s key, or null when the alias is missing. */
    fun level(role: KeyRole): Int? {
        if (!exists(role)) return null
        return when (val k = ks.getKey(alias(role), null)) {
            is PrivateKey -> KeyFactory.getInstance(k.algorithm, ANDROID_KS).getKeySpec(k, KeyInfo::class.java).securityLevel
            is SecretKey -> (SecretKeyFactory.getInstance(k.algorithm, ANDROID_KS).getKeySpec(k, KeyInfo::class.java) as KeyInfo).securityLevel
            else -> null
        }
    }

    fun levels(): Map<KeyRole, Int?> = KeyRole.values().associateWith { level(it) }

    /**
     * Generate [role]'s key: StrongBox first; if StrongBox is unavailable, or the key READ BACK is SOFTWARE (keystore2
     * emulates ECDH silently on Keymaster 4, facts §9), delete it and try the TEE; keep the better by Level.rank.
     * Only called while there is no install marker and no record (design §4.1). Returns the kept level.
     */
    fun generate(role: KeyRole): Int {
        delete(role)
        val first = try { make(role, strongBox = true); level(role) } catch (e: StrongBoxUnavailableException) { null }
        if (first != null && first != Level.SOFTWARE && first != Level.UNKNOWN) return first
        delete(role)
        val second = try { make(role, strongBox = false); level(role) } catch (e: Exception) { null }
        if (first != null && (second == null || Level.rank(first) > Level.rank(second))) {
            delete(role); make(role, strongBox = true); return level(role) ?: Level.UNKNOWN
        }
        return second ?: Level.UNKNOWN
    }

    fun delete(role: KeyRole) { if (exists(role)) ks.deleteEntry(alias(role)) }

    private fun make(role: KeyRole, strongBox: Boolean) {
        val a = alias(role)
        when (role) {
            KeyRole.RECORD_AES -> KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KS).apply {
                init(KeyGenParameterSpec.Builder(a, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setIsStrongBoxBacked(strongBox).build())
            }.generateKey()
            KeyRole.OWNER_SIGN, KeyRole.ADMIN_SIGN -> ec(a, KeyProperties.PURPOSE_SIGN, strongBox) { setDigests(KeyProperties.DIGEST_SHA256) }
            KeyRole.OWNER_ENC -> ec(a, KeyProperties.PURPOSE_AGREE_KEY, strongBox) {}
        }
    }

    private fun ec(a: String, purpose: Int, strongBox: Boolean, extra: KeyGenParameterSpec.Builder.() -> Unit) {
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KS).apply {
            initialize(KeyGenParameterSpec.Builder(a, purpose)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .apply(extra).setIsStrongBoxBacked(strongBox).build())
        }.generateKeyPair()
    }

    /** Uncompressed SEC1 public key (65 B) of an EC key. */
    fun publicKey65(role: KeyRole): ByteArray {
        val pub = ks.getCertificate(alias(role)).publicKey as ECPublicKey
        fun f(b: java.math.BigInteger) = b.toByteArray().let { r -> ByteArray(32).also { o -> r.copyInto(o, maxOf(0, 32 - r.size), maxOf(0, r.size - 32)) } }
        return byteArrayOf(4) + f(pub.w.affineX) + f(pub.w.affineY)
    }

    /** ECDSA-SHA256 DER signature; refused unless the bytes are allow-listed for that key (design §2). Rust normalises low-s. */
    fun sign(role: KeyRole, input: ByteArray): ByteArray {
        val allowed = when (role) {
            KeyRole.OWNER_SIGN -> SignAllowList.ownerMaySign(input)
            KeyRole.ADMIN_SIGN -> SignAllowList.adminMaySign(input)
            else -> false
        }
        require(allowed) { "refused: $role does not sign these bytes" }
        val k = ks.getKey(alias(role), null) as PrivateKey
        return Signature.getInstance("SHA256withECDSA").run { initSign(k); update(input); sign() }
    }

    /** ECDH x coordinate with owner_enc and [peer] (the caller zeroes it after use). */
    fun ecdh(peer: PublicKey): ByteArray {
        val k = ks.getKey(alias(KeyRole.OWNER_ENC), null) as PrivateKey
        return KeyAgreement.getInstance("ECDH", ANDROID_KS).run { init(k); doPhase(peer, true); generateSecret() }
    }

    /** AES-256-GCM with a Keystore-generated IV (design §3); returns iv ‖ ciphertext. [aad] = final path + generation. */
    fun seal(plain: ByteArray, aad: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, ks.getKey(alias(KeyRole.RECORD_AES), null)); updateAAD(aad) }
        val ct = c.doFinal(plain)
        return c.iv + ct
    }

    fun open(sealed: ByteArray, aad: ByteArray): ByteArray {
        require(sealed.size > 12 + 16) { "sealed record too short" }
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, ks.getKey(alias(KeyRole.RECORD_AES), null), GCMParameterSpec(128, sealed, 0, 12)); updateAAD(aad)
        }
        return c.doFinal(sealed, 12, sealed.size - 12)
    }

    companion object { const val ANDROID_KS = "AndroidKeyStore" }
}
