package dev.batman.batman_app.keystore

import java.security.PublicKey

// Design 254-app-s1 §4.1 / §8-4: the platform channel's key handlers (keyLevels / signOwner / signAdmin / ecdh / seal /
// open).
// Pure Kotlin: the live levels and the private-key operations come in through [KeyUses], so the JVM tests drive the
// handlers with fake levels and fake keys. MainActivity only forwards a call here and the answer back; it cannot reach
// a private-key operation itself (Keys.sign / ecdh / seal / open are private, handed only to the KeyHandlers it builds).
// `open` (record decryption, #329 PR 7 T1) is gated on the record AES key's level ONLY: an unreadable other key must not
// make a record unopenable (the Dart callers would take it for "no record" and write over ui/state-v1 and mpend).
// Not handled (accepted, #329 residual, plan §12 B-m1): a transient Keystore error on the record AES key itself (its
// level read or the decryption) answers the same `keystore` code as a record that really does not open, so those Dart
// callers can still take it for "no record".
// `publicKeys` uses no private key and is not gated here; the first-install self-test (Keys.firstRun) is not a use for
// the app.

/** What KeyHandlers needs from the Keystore: the live levels (null = no such key) and the private-key uses. */
interface KeyUses {
    /** Throws when a key cannot be read — never a null for a key that may still be there. */
    fun levels(): Map<KeyRole, Int?>
    /** One key's live level (null = no such key); throws when it cannot be read. */
    fun level(role: KeyRole): Int?
    fun sign(role: KeyRole, input: ByteArray): ByteArray
    fun ecdh(peer: PublicKey): ByteArray
    fun seal(plain: ByteArray, aad: ByteArray): ByteArray
    /** AES-GCM open of iv ‖ ciphertext with the record AES key */
    fun open(sealed: ByteArray, aad: ByteArray): ByteArray
    /** owner_enc's public key, uncompressed SEC1 (65 B): what a sig_enc may bind */
    fun ownerEncPub(): ByteArray
}

/** A handler's answer: a value for result.success, or the error triple for result.error. */
sealed class KeyAnswer {
    class Ok(val value: Any) : KeyAnswer()
    data class Err(val code: String, val message: String?, val details: Any?) : KeyAnswer()

    companion object {
        /**
         * Hand [a] to the channel's result ([success] / [error]). With [wipe], a ByteArray answer is zeroed right after
         * [success] returns (#329 PR 7 T2): the channel codec has encoded it by then, so this copy of the secret (ECDH z,
         * an opened record) is gone. Not a claim that the plaintext is gone: the codec's buffer, the Cipher's internals
         * and the Dart side still hold copies (#329 N5).
         */
        fun deliver(a: KeyAnswer, wipe: Boolean, success: (Any) -> Unit, error: (String, String?, Any?) -> Unit) {
            when (a) {
                is Ok -> { success(a.value); if (wipe) (a.value as? ByteArray)?.fill(0) }
                is Err -> error(a.code, a.message, a.details)
            }
        }
    }
}

class KeyHandlers(private val keys: KeyUses, private val devTrust: Boolean) {
    /** The live level of each key by role name (null = no key) and what that allows; an unreadable key = error `keystore`. */
    fun keyLevels(): KeyAnswer = try {
        val levels = keys.levels()
        val a = KeyPolicy.abilities(levels, devTrust)
        KeyAnswer.Ok(KeyRole.values().associate { it.name to levels[it] } + mapOf(
            "appUsable" to a.appUsable, "claim" to a.claim, "login" to a.login,
            "recover" to a.recover, "makeNetwork" to a.makeNetwork, "softOwnerEnc" to a.softOwnerEnc,
        ))
    } catch (e: Exception) {
        KeyAnswer.Err("keystore", e.javaClass.simpleName, null)
    }

    /**
     * The owner key; binding owner_enc (sig_enc, at claim and in a join request) also needs owner_enc at its level, and
     * the bound key must BE this phone's owner_enc (exactly label ‖ ownerEncPub), else refused before the key is used.
     */
    fun signOwner(input: ByteArray?): KeyAnswer {
        val bind = input != null && SignAllowList.bindsOwnerEnc(input)
        return use(if (bind) KeyOp.BIND_OWNER_ENC else KeyOp.SIGN_OWNER, "keystore", ::detail) {
            if (bind) require(SignAllowList.boundKey(input!!).contentEquals(keys.ownerEncPub())) { "refused: sig_enc binds a key that is not this phone's owner_enc" }
            keys.sign(KeyRole.OWNER_SIGN, requireNotNull(input) { "no input" })
        }
    }

    fun signAdmin(input: ByteArray?): KeyAnswer =
        use(KeyOp.SIGN_ADMIN, "keystore", ::detail) { keys.sign(KeyRole.ADMIN_SIGN, requireNotNull(input) { "no input" }) }

    /** Dev builds only; the peer must be a P-256 point (EcdhPeer); z is 32 bytes (the caller zeroes it once handed over). */
    fun ecdh(peer: ByteArray?): KeyAnswer {
        val pk = EcdhPeer.accept(devTrust, peer)
            ?: return KeyAnswer.Err("ecdh", if (devTrust) "not a P-256 point" else "dev builds only", null)
        return use(KeyOp.ECDH, "ecdh", { it.javaClass.simpleName }) { keys.ecdh(pk).also { check(it.size == 32) { "z is not 32 bytes" } } }
    }

    fun seal(plain: ByteArray?, aad: ByteArray?): KeyAnswer =
        use(KeyOp.SEAL, "keystore", ::detail) { keys.seal(requireNotNull(plain) { "no plain" }, requireNotNull(aad) { "no aad" }) }

    /**
     * #329 PR 7 T1: record decryption, gated on the record AES key's live level only (KeyOp.OPEN). Another key that
     * cannot be read, is missing or is not allowed does not stop it: a failed open is read by the Dart callers as "no
     * record" and written over (ui/state-v1, mpend). Same errors as the other uses: `keyLevel` (role RECORD_AES, its
     * level) or `keystore`. The plaintext is zeroed once handed over (MainActivity: wipe = true).
     */
    fun open(sealed: ByteArray?, aad: ByteArray?): KeyAnswer =
        use(KeyOp.OPEN, "keystore", ::detail, { mapOf(KeyRole.RECORD_AES to keys.level(KeyRole.RECORD_AES)) }) {
            keys.open(requireNotNull(sealed) { "no record" }, requireNotNull(aad) { "no aad" })
        }

    /**
     * The one gate: the live levels are read ([levels]: all four, unless an op needs fewer) and KeyPolicy decides before
     * the key is touched, whatever the Dart side checked. A refusal is error `keyLevel` (message = the key's role,
     * details = its level, null = no key); an unreadable level or a failing use is error [code].
     */
    private fun use(op: KeyOp, code: String, message: (Exception) -> String, levels: () -> Map<KeyRole, Int?> = keys::levels, f: () -> ByteArray): KeyAnswer = try {
        when (val no = KeyPolicy.refused(op, levels(), devTrust)) {
            null -> KeyAnswer.Ok(f())
            else -> KeyAnswer.Err("keyLevel", no.role.name, no.level)
        }
    } catch (e: Exception) {
        KeyAnswer.Err(code, message(e), null)
    }

    private fun detail(e: Exception) = "${e.javaClass.simpleName}: ${e.message}"
}
