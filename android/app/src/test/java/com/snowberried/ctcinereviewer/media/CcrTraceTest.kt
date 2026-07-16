package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CcrTraceTest {
    @Test
    fun `request trace label is bounded and contains only numeric request metadata`() {
        val request = FrameRequest(
            GenerationToken(Long.MAX_VALUE, Long.MAX_VALUE),
            Int.MAX_VALUE,
            FrameKey(Int.MAX_VALUE, Long.MAX_VALUE, 0),
        )
        val label = CcrTrace.requestLabel(CcrTrace.ACTOR_START, request)

        assertTrue(label.startsWith("CCR.actor.start f="))
        assertTrue(label.length <= 127)
        assertFalse(label.contains("content://"))
        assertFalse(label.contains("/storage/"))
        assertFalse(label.contains("\\"))
    }

    @Test
    fun `safe section always executes body when platform trace is unavailable`() {
        assertEquals(42, CcrTrace.section("CCR.test") { 42 })
    }
}
