package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CodecInputStateTest {
    @Test
    fun `fresh codec skips flush until input has been queued`() {
        val state = CodecInputState()

        assertFalse(state.flushRequiredBeforeDecode)

        state.onInputQueued()

        assertTrue(state.flushRequiredBeforeDecode)

        state.onFlushCompleted()

        assertFalse(state.flushRequiredBeforeDecode)
    }

    @Test
    fun `recreated codec clears pending flush requirement`() {
        val state = CodecInputState()
        state.onInputQueued()

        state.onCodecCreated()

        assertFalse(state.flushRequiredBeforeDecode)
    }
}
