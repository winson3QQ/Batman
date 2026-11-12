package dev.batman.batman_app.swupd

/**
 * The one Specifier request callback an upload stage owns (code review r2, B m-r2-1). A cancel ([release]) can land
 * between the claim and the platform registration; the join that registered the callback then unregisters ITS OWN
 * callback in [settle] — a failed join and one overtaken by a cancel never leave a request behind (a request left
 * registered keeps the phone on the node AP: TAK down). Plain JVM (no android.*): the JVM tests drive it with a fake
 * register / unregister.
 */
class SwOwned<C : Any>(private val unregister: (C) -> Unit) {
    private val lock = Any()
    private var current: C? = null

    fun claim(c: C) = synchronized(lock) { current = c }

    fun isCurrent(c: C): Boolean = synchronized(lock) { current === c }

    /** Cancel / the end of the stage: the current callback is dropped and unregistered. Harmless when there is none. */
    fun release() {
        val c = synchronized(lock) { current.also { current = null } }
        if (c != null) unregister(c)
    }

    /**
     * After the registration: true = [c] stays (the join succeeded and nothing released it meanwhile); false = [c] is
     * unregistered here, by its own join, whether or not a release saw it registered.
     */
    fun settle(c: C, ok: Boolean): Boolean {
        val keep = synchronized(lock) {
            val mine = current === c
            if (!ok && mine) current = null
            ok && mine
        }
        if (!keep) unregister(c)
        return keep
    }
}
