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

    @Test
    fun `cached navigation marker has a stable request identity contract`() {
        val request = FrameRequest(
            GenerationToken(3, 9),
            7,
            FrameKey(7, 7_000, 0),
        )

        val label = CcrTrace.requestLabel(CcrTrace.CACHED_NAVIGATION_START, request)

        assertEquals("CCR.cached-navigation.start f=3 r=9 i=7 p=7000", label)
    }

    @Test
    fun `navigation input label records mode stride requested and displayed without paths`() {
        val request = FrameRequest(
            GenerationToken(7, 11),
            31,
            FrameKey(31, 1_250_000, 0),
        )

        val label = CcrTrace.navigationInputLabel(request, "HOLD_REVERSE", -5, 36)

        assertTrue(label.startsWith("CCR.navigation.input f=7 r=11"))
        assertTrue(label.contains("m=HOLD_REVERSE s=-5 i=31 d=36 p=1250000"))
        assertTrue(label.length <= 127)
        assertFalse(label.contains("content://"))
        assertFalse(label.contains("/storage/"))
    }
}
