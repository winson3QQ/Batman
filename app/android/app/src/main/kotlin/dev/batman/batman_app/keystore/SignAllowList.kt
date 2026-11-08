package dev.batman.batman_app.keystore

// Design §2: every Keystore key signs only the formats it exists for (proto.go:26-33). Purpose separation only — it
// does not stop an attacker inside the app process (honest boundary, design §2). Kotlin never parses records; this
// check looks only at the bytes it is asked to sign.
object SignAllowList {
    private val OWNER_PREFIXES = listOf("batman-owner-enc-v1", "batman-owner-auth-v1", "batman-owner-op-v1")
        .map { it.toByteArray(Charsets.US_ASCII) }
    private val ADMIN_LABELS = listOf("batman-netcfg-v1", "batman-members-v1", "batman-secrets-v1")
        .map { it.toByteArray(Charsets.US_ASCII) }

    private fun startsWith(b: ByteArray, p: ByteArray) = b.size > p.size && b.copyOfRange(0, p.size).contentEquals(p)

    /** The owner key signs only inputs that start with one of its three labels (and carry something after it). */
    fun ownerMaySign(input: ByteArray): Boolean = OWNER_PREFIXES.any { startsWith(input, it) }

    /**
     * The admin key signs only a COSE Sig_structure: CBOR array(4) ["Signature1", protected bstr, external_aad bstr,
     * payload bstr] whose external_aad is exactly one of the three labels. Parsed strictly enough to find the aad;
     * anything else is refused.
     */
    fun adminMaySign(tbs: ByteArray): Boolean {
        var i = 0
        fun byte(): Int = if (i < tbs.size) tbs[i++].toInt() and 0xff else -1
        // a definite-length major-type-2/3 head; returns the length, or -1
        fun len(major: Int): Long {
            val h = byte(); if (h < 0 || h shr 5 != major) return -1
            val ai = h and 0x1f
            return when {
                ai < 24 -> ai.toLong()
                ai == 24 -> byte().toLong()
                ai == 25 -> (byte().toLong() shl 8) or byte().toLong()
                ai == 26 -> (0 until 4).fold(0L) { a, _ -> (a shl 8) or byte().toLong() }
                else -> -1
            }
        }
        if (byte() != 0x84) return false
        val ctx = len(3); if (ctx != 10L || i + 10 > tbs.size) return false
        if (!tbs.copyOfRange(i, i + 10).contentEquals("Signature1".toByteArray(Charsets.US_ASCII))) return false
        i += 10
        val prot = len(2); if (prot < 0 || i + prot > tbs.size) return false
        i += prot.toInt()
        val aadLen = len(2); if (aadLen < 0 || i + aadLen > tbs.size) return false
        val aad = tbs.copyOfRange(i, i + aadLen.toInt())
        i += aadLen.toInt()
        val pl = len(2); if (pl < 0 || i + pl != tbs.size.toLong()) return false
        return ADMIN_LABELS.any { it.contentEquals(aad) }
    }
}
