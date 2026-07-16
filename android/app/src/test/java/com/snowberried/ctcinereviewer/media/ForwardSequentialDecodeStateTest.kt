package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForwardSequentialDecodeStateTest {
    @Test
    fun `published cursor enters only exact forward plus one or plus five`() {
        val state = ForwardSequentialDecodeState()
        state.recordPublished(3, 7, 10, mapOf(1_000L to 1), inputEos = false)

        val plusOne = state.decide(3, 7, 11, 1)
        assertTrue(plusOne.enter)
        assertEquals(mapOf(1_000L to 1), plusOne.duplicateCounts)

        state.recordPublished(3, 7, 11, mapOf(1_000L to 2), inputEos = false)
        assertTrue(state.decide(3, 7, 16, 5).enter)
    }

    @Test
    fun `direction jump file codec and eos invalidate cursor`() {
        fun decision(
            file: Long = 3,
            codec: Long = 7,
            target: Int = 11,
            stride: Int? = 1,
            eos: Boolean = false,
        ): ForwardSequentialDecision {
            val state = ForwardSequentialDecodeState()
            state.recordPublished(3, 7, 10, emptyMap(), eos)
            return state.decide(file, codec, target, stride)
        }

        assertEquals(ForwardSequentialFallbackReason.NOT_REQUESTED, decision(stride = null).fallbackReason)
        assertEquals(ForwardSequentialFallbackReason.UNSUPPORTED_STRIDE, decision(stride = -1).fallbackReason)
        assertEquals(ForwardSequentialFallbackReason.FILE_CHANGED, decision(file = 4).fallbackReason)
        assertEquals(ForwardSequentialFallbackReason.CODEC_CHANGED, decision(codec = 8).fallbackReason)
        assertEquals(ForwardSequentialFallbackReason.TARGET_NOT_NEXT, decision(target = 12).fallbackReason)
        assertEquals(ForwardSequentialFallbackReason.EOS_REACHED, decision(eos = true).fallbackReason)
    }

    @Test
    fun `failed entry clears old cursor and published maps are copied`() {
        val counts = mutableMapOf(4_000L to 1)
        val state = ForwardSequentialDecodeState()
        state.recordPublished(1, 1, 4, counts, inputEos = false)
        counts[4_000L] = 99

        assertEquals(1, state.decide(1, 1, 5, 1).duplicateCounts[4_000L])
        assertFalse(state.decide(1, 1, 20, 5).enter)
        assertEquals(
            ForwardSequentialFallbackReason.NO_PUBLISHED_CURSOR,
            state.decide(1, 1, 25, 5).fallbackReason,
        )
    }
}
