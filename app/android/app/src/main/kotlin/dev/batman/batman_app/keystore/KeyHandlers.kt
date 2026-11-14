package dev.batman.batman_app.keystore

import java.security.PublicKey

// Design 254-app-s1 §4.1 / §8-4: the platform channel's key handlers (keyLevels / signOwner / signAdmin / ecdh / seal).
// Pure Kotlin: the live levels and the private-key operations come in through [KeyUses], so the JVM tests drive the
// handlers with fake levels and fake keys. MainActivity only forwards a call here and the answer back; it cannot reach
// a private-key operation itself (Keys.sign / ecdh / seal are private, handed only to the KeyHandlers it builds).
// `open` (record decryption) and `publicKeys` use no private key for a node-facing act and are not gated here; the
// first-install self-test (Keys.firstRun) is not a use for the app.

/** What KeyHandlers needs from the Keystore: the live levels (null = no such key) and the three private-key uses. */
interface KeyUses {
    /** Throws when a key cannot be read — never a null for a key that may still be there. */
    fun levels(): Map<KeyRole, Int?>
    fun sign(role: KeyRole, input: ByteArray): ByteArray
    fun ecdh(peer: PublicKey): ByteArray
    fun seal(plain: ByteArray, aad: ByteArray): ByteArray
    /** owner_enc's public key, uncompressed SEC1 (65 B): what a sig_enc may bind */
    fun ownerEncPub(): ByteArray
}

/** A handler's answer: a value for result.success, or the error triple for result.error. */
sealed class KeyAnswer {
    class Ok(val value: Any) : KeyAnswer()
    data class Err(val code: String, val message: String?, val details: Any?) : KeyAnswer()
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
     * The one gate: the live levels are read and KeyPolicy decides before the key is touched, whatever the Dart side
     * checked. A refusal is error `keyLevel` (message = the key's role, details = its level, null = no key); an
     * unreadable level or a failing use is error [code].
     */
    private fun use(op: KeyOp, code: String, message: (Exception) -> String, f: () -> ByteArray): KeyAnswer = try {
        when (val no = KeyPolicy.refused(op, keys.levels(), devTrust)) {
            null -> KeyAnswer.Ok(f())
            else -> KeyAnswer.Err("keyLevel", no.role.name, no.level)
        }
    } catch (e: Exception) {
        KeyAnswer.Err(code, message(e), null)
    }

    private fun detail(e: Exception) = "${e.javaClass.simpleName}: ${e.message}"
}
