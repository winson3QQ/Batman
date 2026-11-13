package dev.batman.batman_app.qr

import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicReference

/**
 * 254-app-qr §2: the one pending `scanQr` call of the process. [put] fills the empty slot; only [take] with the same gen
 * empties it, and whoever takes it answers — so a call is answered at most once, and only by the QrScanActivity it
 * started (the gen travels in that Activity's Intent). [dropOwner] clears only its own owner's entry. The scanned text
 * passes through [Reply.done] in memory only.
 */
class QrScan {
    /** the answer to one call; MainActivity wraps a MethodChannel.Result (no Flutter here, so the JVM tests run it) */
    interface Reply {
        fun done(text: String?)
        fun fail()
    }

    private class Entry(val gen: Long, val owner: Any, val reply: Reply)

    private val slot = AtomicReference<Entry?>(null)

    /** the new call's gen, or null when one is already pending (busy) */
    fun put(owner: Any, reply: Reply): Long? {
        val e = Entry(random.nextLong(), owner, reply) // A r3-2: a restarted process never meets an old Intent's gen
        return if (slot.compareAndSet(null, e)) e.gen else null
    }

    fun isCurrent(gen: Long): Boolean = slot.get()?.gen == gen

    /** the reply of call [gen], once; null when it was answered, dropped, or the slot holds another call */
    fun take(gen: Long): Reply? {
        val e = slot.get() ?: return null
        return if (e.gen == gen && slot.compareAndSet(e, null)) e.reply else null
    }

    /** the engine of [owner] is going away: its call is dropped unanswered; another owner's call stays (A r2-m3) */
    fun dropOwner(owner: Any) {
        val e = slot.get() ?: return
        if (e.owner === owner) slot.compareAndSet(e, null)
    }

    companion object {
        private val random = SecureRandom()
        val shared = QrScan()
    }
}
