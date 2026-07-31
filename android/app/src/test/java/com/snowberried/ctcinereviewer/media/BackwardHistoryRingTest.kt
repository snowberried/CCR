package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackwardHistoryRingTest {
    @Test
    fun `64 MiB reserves current and inflight yielding sixteen 720p and six 1080p history frames`() {
        val ring = BackwardHistoryRing(CACHE_BUDGET)
        ring.configure(1280L * 720L * 4L)
        assertEquals(16, ring.snapshot().capacity)

        ring.configure(1920L * 1080L * 4L)
        assertEquals(6, ring.snapshot().capacity)
    }

    @Test
    fun `forward plus one retains exact recent keys for immediate reverse`() {
        val ring = BackwardHistoryRing(CACHE_BUDGET)
        ring.configure(1920L * 1080L * 4L)
        var current = key(100)
        repeat(6) { offset ->
            val next = key(101 + offset)
            ring.recordPublished(current, next)
            current = next
        }

        assertEquals((100..105).toList(), ring.snapshot().keys.map(FrameKey::displayFrameIndex))
        assertTrue(ring.contains(key(105)))
        assertFalse(ring.contains(current))
    }

    @Test
    fun `forward plus five prioritizes stride targets and exhausts by byte depth`() {
        val ring = BackwardHistoryRing(CACHE_BUDGET)
        ring.configure(1920L * 1080L * 4L)
        var current = key(0)
        repeat(10) { offset ->
            val next = key((offset + 1) * 5)
            ring.recordPublished(current, next)
            current = next
        }

        assertEquals(listOf(20, 25, 30, 35, 40, 45), ring.snapshot().keys.map(FrameKey::displayFrameIndex))
        assertFalse(ring.contains(key(15)))
        assertTrue(ring.contains(key(45)))
    }

    @Test
    fun `eviction file switch and memory trim remove only key references`() {
        val ring = BackwardHistoryRing(CACHE_BUDGET)
        ring.configure(1280L * 720L * 4L)
        ring.recordPublished(key(1), key(2))
        ring.recordPublished(key(2), key(3))
        assertTrue(ring.remove(key(1)))
        assertEquals(listOf(2), ring.snapshot().keys.map(FrameKey::displayFrameIndex))

        ring.configure(CACHE_BUDGET, availableBudgetBytes = 0)
        assertEquals(0, ring.snapshot().depth)
        assertEquals(0, ring.snapshot().capacity)
        ring.reset()
        assertEquals(0L, ring.snapshot().frameBytes)
    }

    private fun key(index: Int) = FrameKey(index, index * 1_000L, 0)

    private companion object {
        const val CACHE_BUDGET = 64L * 1024L * 1024L
    }
}
