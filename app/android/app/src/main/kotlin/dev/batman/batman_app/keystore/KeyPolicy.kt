package dev.batman.batman_app.keystore

// Design v8.5.1 §4.1: which Keystore security levels each key may have, per build. Pure logic (no Android API) so the
// table is unit-tested with injected levels; the caller reads the level live (KeyInfo.securityLevel) at every start
// and before claim / recovery / login / network creation, and decides only with this table — the level stored in the
// install marker is display-only.

/** The four keys (design §3 / §4). */
enum class KeyRole { RECORD_AES, OWNER_SIGN, ADMIN_SIGN, OWNER_ENC }

/** android.security.keystore.KeyProperties.SECURITY_LEVEL_* values (API 31). */
object Level {
    const val UNKNOWN_SECURE = -2
    const val UNKNOWN = -1
    const val SOFTWARE = 0
    const val TRUSTED_ENVIRONMENT = 1
    const val STRONGBOX = 2

    /** Hardware = STRONGBOX, TEE, or UNKNOWN_SECURE ("secure hardware of unknown type"); SOFTWARE / UNKNOWN are not. */
    fun isHardware(level: Int): Boolean = level == STRONGBOX || level == TRUSTED_ENVIRONMENT || level == UNKNOWN_SECURE

    /** Generation keeps the better key, by the level READ BACK: STRONGBOX > TEE > UNKNOWN_SECURE > SOFTWARE > UNKNOWN. */
    fun rank(level: Int): Int = when (level) {
        STRONGBOX -> 4
        TRUSTED_ENVIRONMENT -> 3
        UNKNOWN_SECURE -> 2
        SOFTWARE -> 1
        else -> 0
    }
}

/**
 * The key operations the platform channel offers, and the keys each needs at an allowed level (the record AES key in
 * all of them: without it the app is off, §4).
 */
enum class KeyOp(val needs: List<KeyRole>) {
    SIGN_OWNER(listOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN)),
    /** the owner key signing "batman-owner-enc-v1" ‖ owner_enc_pub (sig_enc): it vouches for owner_enc, so owner_enc must fit too */
    BIND_OWNER_ENC(listOf(KeyRole.RECORD_AES, KeyRole.OWNER_SIGN, KeyRole.OWNER_ENC)),
    SIGN_ADMIN(listOf(KeyRole.RECORD_AES, KeyRole.ADMIN_SIGN)),
    ECDH(listOf(KeyRole.RECORD_AES, KeyRole.OWNER_ENC)),
    SEAL(listOf(KeyRole.RECORD_AES)),
}

object KeyPolicy {
    /** [op] was refused: [role]'s key is missing ([level] null) or its level is not allowed in this build. */
    class Refused(val role: KeyRole, val level: Int?) : Exception("$role level $level")

    /**
     * The one gate of the handlers that use a key (KeyHandlers: signOwner / signAdmin / ecdh / seal): null = go on; else the first
     * key of [op] that is missing from [levels] or not [allowed]. Fail closed: no entry, a null level, an unknown level.
     */
    fun refused(op: KeyOp, levels: Map<KeyRole, Int?>, devTrust: Boolean): Refused? {
        for (r in op.needs) {
            val l = levels[r]
            if (l == null || !allowed(r, l, devTrust)) return Refused(r, l)
        }
        return null
    }

    /** Is [level] allowed for [role] in a build with [devTrust]? Only owner_enc in the dev build may be SOFTWARE. */
    fun allowed(role: KeyRole, level: Int, devTrust: Boolean): Boolean = when (role) {
        KeyRole.OWNER_ENC -> Level.isHardware(level) || (devTrust && level == Level.SOFTWARE)
        else -> Level.isHardware(level)
    }

    /** What the app may do, from the four live levels (a missing key = null). */
    data class Abilities(
        val appUsable: Boolean,      // record AES: records can be stored / read
        val claim: Boolean,          // owner signing + owner_enc
        val login: Boolean,          // owner signing
        val recover: Boolean,        // owner signing + owner_enc
        val makeNetwork: Boolean,    // owner signing + admin
        val softOwnerEnc: Boolean,   // dev build with a SOFTWARE owner_enc: warn before the first claim
    )

    fun abilities(levels: Map<KeyRole, Int?>, devTrust: Boolean): Abilities {
        fun ok(r: KeyRole) = levels[r]?.let { allowed(r, it, devTrust) } ?: false
        val aes = ok(KeyRole.RECORD_AES)
        val sign = aes && ok(KeyRole.OWNER_SIGN)
        val enc = ok(KeyRole.OWNER_ENC)
        return Abilities(
            appUsable = aes,
            claim = sign && enc,
            login = sign,
            recover = sign && enc,
            makeNetwork = sign && ok(KeyRole.ADMIN_SIGN),
            softOwnerEnc = devTrust && levels[KeyRole.OWNER_ENC] == Level.SOFTWARE,
        )
    }
}
