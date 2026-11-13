package dev.batman.batman_app.qr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** 254-app-qr on-device fix: the preview keeps the camera image's aspect ratio and covers the screen */
class ViewfinderFitTest {
    private fun fit(bufW: Int, bufH: Int, rot: Int, cw: Int, ch: Int): Pair<Int, Int> {
        val (w, h) = ViewfinderFit.displayed(bufW, bufH, rot)
        return ViewfinderFit.centerCrop(w, h, cw, ch)
    }

    private fun check(v: Pair<Int, Int>, aspectW: Int, aspectH: Int, cw: Int, ch: Int) {
        assertEquals("aspect of $v", aspectW.toDouble() / aspectH, v.first.toDouble() / v.second, 0.01)
        assertTrue("covers the container: $v", v.first >= cw && v.second >= ch)
        assertTrue("one side fits exactly: $v", v.first == cw || v.second == ch)
    }

    @Test fun portraitSensorAt90() {
        val v169 = fit(1920, 1080, 90, 1080, 2400) // 16:9 buffer, S20-like portrait screen
        assertEquals(1350 to 2400, v169)
        check(v169, 9, 16, 1080, 2400)
        check(fit(1440, 1080, 90, 1080, 2400), 3, 4, 1080, 2400) // 4:3
        check(fit(1920, 1080, 270, 1080, 2400), 9, 16, 1080, 2400)
    }

    @Test fun landscapeNoRotation() {
        val v169 = fit(1920, 1080, 0, 2400, 1080)
        assertEquals(2400 to 1350, v169)
        check(v169, 16, 9, 2400, 1080)
        check(fit(1440, 1080, 0, 2400, 1080), 4, 3, 2400, 1080)
        check(fit(1440, 1080, 180, 2400, 1080), 4, 3, 2400, 1080)
    }

    @Test fun unknownSizesFallBackToTheContainer() {
        assertEquals(1080 to 2400, ViewfinderFit.centerCrop(0, 0, 1080, 2400))
    }
}
