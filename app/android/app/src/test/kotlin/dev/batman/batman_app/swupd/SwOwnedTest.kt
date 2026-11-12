package dev.batman.batman_app.swupd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Code review r2 (B m-r2-1): every registered Specifier callback is unregistered by its own join when the join fails
 * or a cancel overtook it — also when the cancel came between the claim and the registration. A fake platform: a
 * register / unregister of a callback that is not registered is the platform's IllegalArgumentException (counted).
 */
class SwOwnedTest {
    private class Platform {
        val registered = HashSet<String>()
        var unknownUnregisters = 0
        fun register(c: String) { registered.add(c) }
        fun unregister(c: String) { if (!registered.remove(c)) unknownUnregisters++ }
    }

    @Test fun aCancelBeforeTheRegistrationLeavesNoRequest() {
        val p = Platform(); val o = SwOwned<String>(p::unregister)
        o.claim("cb1")
        o.release() // the cancel lands here: cb1 is not registered yet (the platform refuses that unregister)
        p.register("cb1") // the join registers it anyway
        assertFalse(o.settle("cb1", ok = false))
        assertTrue("the request leaked: ${p.registered}", p.registered.isEmpty())
    }

    @Test fun aCancelAfterASuccessfulJoinStillLeavesNoRequest() {
        val p = Platform(); val o = SwOwned<String>(p::unregister)
        o.claim("cb1"); p.register("cb1")
        o.release()
        assertFalse("released meanwhile: not kept", o.settle("cb1", ok = true))
        assertTrue(p.registered.isEmpty())
    }

    @Test fun aFailedJoinUnregistersItsOwnCallback() {
        val p = Platform(); val o = SwOwned<String>(p::unregister)
        o.claim("cb1"); p.register("cb1")
        assertFalse(o.settle("cb1", ok = false))
        assertTrue(p.registered.isEmpty())
        assertEquals(0, p.unknownUnregisters)
    }

    @Test fun aGoodJoinIsKeptUntilTheStageEnds() {
        val p = Platform(); val o = SwOwned<String>(p::unregister)
        o.claim("cb1"); p.register("cb1")
        assertTrue(o.settle("cb1", ok = true))
        assertEquals(setOf("cb1"), p.registered)
        assertTrue(o.isCurrent("cb1"))
        o.release()
        assertTrue(p.registered.isEmpty())
        o.release()
        assertEquals("a second release is harmless", 0, p.unknownUnregisters)
    }
}
