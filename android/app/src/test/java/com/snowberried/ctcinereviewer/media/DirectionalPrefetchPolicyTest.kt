package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectionalPrefetchPolicyTest {
    @Test
    fun `initial and forward requests look ahead by at most twelve frames`() {
        val initial = directionalPrefetchPlan(null, 0, 100)
        val forward = directionalPrefetchPlan(10, 15, 100)

        assertEquals(DirectionalPrefetchDirection.FORWARD, initial.direction)
        assertEquals(1..12, initial.frameIndexes)
        assertEquals(DirectionalPrefetchDirection.FORWARD, forward.direction)
        assertEquals(16..27, forward.frameIndexes)
    }

    @Test
    fun `reverse request caches only the bounded look-behind window`() {
        val reverse = directionalPrefetchPlan(50, 30, 100)
        val clipped = directionalPrefetchPlan(10, 3, 100)

        assertEquals(DirectionalPrefetchDirection.REVERSE, reverse.direction)
        assertEquals(18 until 30, reverse.frameIndexes)
        assertEquals(0 until 3, clipped.frameIndexes)
        assertEquals(DIRECTIONAL_PREFETCH_FRAME_LIMIT, reverse.frameIndexes.count())
    }

    @Test
    fun `prefetch window clips to file boundaries`() {
        assertEquals(96..99, directionalPrefetchPlan(90, 95, 100).frameIndexes)
        assertTrue(directionalPrefetchPlan(98, 99, 100).frameIndexes.isEmpty())
        assertTrue(directionalPrefetchPlan(1, 0, 100).frameIndexes.isEmpty())
    }
}
