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

    @Test
    fun `timeline position follows VFR PTS instead of average frame spacing`() {
        val ptsUs = listOf(0L, 100_000L, 900_000L, 1_000_000L)

        assertEquals(0.1f, timelineFractionForFrame(ptsUs, 1), 0.0001f)
        assertEquals(0.9f, timelineFractionForFrame(ptsUs, 2), 0.0001f)
        assertEquals(1, nearestFrameIndexForTimelineFraction(ptsUs, 0.5f))
        assertEquals(2, nearestFrameIndexForTimelineFraction(ptsUs, 0.89f))
    }

    @Test
    fun `timeline duplicate PTS resolves to first display frame at that position`() {
        val ptsUs = listOf(10L, 20L, 20L, 30L)

        assertEquals(1, nearestFrameIndexForTimelineFraction(ptsUs, 0.5f))
        assertEquals(0, nearestFrameIndexForTimelineFraction(ptsUs, -1f))
        assertEquals(3, nearestFrameIndexForTimelineFraction(ptsUs, 2f))
    }
}
