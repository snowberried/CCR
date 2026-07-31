package com.snowberried.ctcinereviewer.render

import com.snowberried.ctcinereviewer.media.FrameImageProbe
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FrameProbePolicyTest {
    @Test
    fun `pilot mode never invokes full-frame readback`() {
        var calls = 0
        val policy = FrameProbePolicy(FrameRenderMode.PILOT)

        val probe = policy.capture {
            calls += 1
            FrameImageProbe(7, listOf(1, 2, 3))
        }

        assertNull(probe)
        assertEquals(0, calls)
        assertEquals(0L, policy.readbackCount())
    }

    @Test
    fun `exactness mode invokes and counts the injected readback`() {
        val policy = FrameProbePolicy(FrameRenderMode.EXACTNESS)
        val expected = FrameImageProbe(7, listOf(1, 2, 3))

        assertEquals(expected, policy.capture { expected })
        assertEquals(1L, policy.readbackCount())
    }
}
