package dev.batman.batman_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** design 254-app-s1 §4: only `set` with a Boolean changes the window's FLAG_SECURE; anything else changes nothing */
class SecureScreenTest {
    @Test
    fun setWithABooleanIsTheStateAskedFor() {
        assertEquals(true, SecureScreen.wanted("set", true))
        assertEquals(false, SecureScreen.wanted("set", false))
    }

    @Test
    fun anythingElseIsNotACall() {
        assertNull(SecureScreen.wanted("set", null))
        assertNull(SecureScreen.wanted("set", "true"))
        assertNull(SecureScreen.wanted("set", 1))
        assertNull(SecureScreen.wanted("set", mapOf("on" to true)))
        assertNull(SecureScreen.wanted("clear", true))
        assertNull(SecureScreen.wanted("", false))
    }
}
