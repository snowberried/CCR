package com.snowberried.ctcinereviewer.render

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceLeaseTrackerTest {
    @Test
    fun staleDetachCannotReleaseNewSurface() {
        val leases = SurfaceLeaseTracker()

        assertTrue(leases.attach(1))
        assertTrue(leases.attach(2))
        assertFalse(leases.detach(1))
        assertTrue(leases.isActive(2))
        assertTrue(leases.detach(2))
    }
}
