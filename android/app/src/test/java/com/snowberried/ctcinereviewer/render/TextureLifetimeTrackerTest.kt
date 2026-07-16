package com.snowberried.ctcinereviewer.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextureLifetimeTrackerTest {
    @Test
    fun `created released and live counts preserve exact once accounting`() {
        val tracker = TextureLifetimeTracker()
        tracker.onCreated(1)
        tracker.onCreated(2)

        assertTrue(tracker.onReleased(1))
        assertTrue(tracker.onReleased(2))

        assertEquals(2L, tracker.createdCount)
        assertEquals(2L, tracker.releasedCount)
        assertEquals(0, tracker.liveCount)
        assertEquals(2, tracker.peakLiveCount)
        assertEquals(0L, tracker.doubleReleaseCount)
    }

    @Test
    fun `second release is rejected without affecting a reused GL id allocation`() {
        val tracker = TextureLifetimeTracker()
        tracker.onCreated(10)
        assertTrue(tracker.onReleased(10))
        tracker.onCreated(11)

        assertFalse(tracker.onReleased(10))

        assertEquals(2L, tracker.createdCount)
        assertEquals(1L, tracker.releasedCount)
        assertEquals(1, tracker.liveCount)
        assertEquals(1L, tracker.doubleReleaseCount)
        assertTrue(tracker.onReleased(11))
    }
}
