package dev.batman.batman_app.qr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 254-app-qr §5 U6: the pending-call slot with a fake [QrScan.Reply] (no Flutter). At most one answer per call, only to
 * the call that started the Activity; an old owner's dropOwner leaves a new call alone.
 */
class QrScanTest {
    private class Fake : QrScan.Reply {
        val got = mutableListOf<String>()
        override fun done(text: String?) { got.add("done:$text") }
        override fun fail() { got.add("fail") }
    }

    @Test fun aSecondPutIsBusy() {
        val s = QrScan(); val a = Any()
        assertNotNull(s.put(a, Fake()))
        assertNull(s.put(a, Fake()))
    }

    @Test fun oneAnswerPerCall() {
        val s = QrScan(); val r = Fake()
        val gen = s.put(Any(), r)!!
        s.take(gen)?.done("x") // the decoded frame
        s.take(gen)?.done(null) // a later frame / onDestroy
        assertEquals(listOf("done:x"), r.got)
        assertNull(s.take(gen))
    }

    @Test fun anOldGenDoesNotAnswerANewCall() {
        val s = QrScan(); val old = Fake(); val new = Fake()
        val g1 = s.put(Any(), old)!!
        s.take(g1)?.done(null) // the first scan ended
        val g2 = s.put(Any(), new)!!
        s.take(g1)?.done("late") // the old Activity's late frame
        assertEquals(listOf<String>(), new.got)
        assertEquals(true, s.isCurrent(g2))
        s.take(g2)?.done("y")
        assertEquals(listOf("done:y"), new.got)
        assertEquals(listOf("done:null"), old.got)
    }

    @Test fun dropOwnerClearsOnlyItsOwn() {
        val s = QrScan(); val oldMain = Any(); val newMain = Any(); val r = Fake()
        val g1 = s.put(oldMain, Fake())!!
        s.dropOwner(oldMain) // the old engine went away: its call is dropped unanswered
        assertNull(s.take(g1))
        val g2 = s.put(newMain, r)!!
        s.dropOwner(oldMain) // the old MainActivity's onDestroy comes late
        s.take(g2)?.done("z")
        assertEquals(listOf("done:z"), r.got)
    }

    @Test fun aFailedStartFailsAndFreesTheSlot() {
        val s = QrScan(); val r = Fake(); val o = Any()
        val gen = s.put(o, r)!!
        s.take(gen)?.fail() // startActivity threw
        assertEquals(listOf("fail"), r.got)
        assertNotNull("the slot is free again", s.put(o, Fake()))
    }
}
