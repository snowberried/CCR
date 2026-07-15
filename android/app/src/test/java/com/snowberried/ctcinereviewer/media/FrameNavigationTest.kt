package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Test

class FrameNavigationTest {
    @Test
    fun `clamps one and five frame movement at both boundaries`() {
        assertEquals(0, boundedFrameIndex(0, -1, 10))
        assertEquals(0, boundedFrameIndex(2, -5, 10))
        assertEquals(9, boundedFrameIndex(9, 1, 10))
        assertEquals(9, boundedFrameIndex(7, 5, 10))
        assertEquals(4, boundedFrameIndex(5, -1, 10))
        assertEquals(6, boundedFrameIndex(5, 1, 10))
    }

    @Test
    fun `avoids integer overflow while clamping`() {
        assertEquals(9, boundedFrameIndex(5, Int.MAX_VALUE, 10))
        assertEquals(0, boundedFrameIndex(5, Int.MIN_VALUE, 10))
    }
}
