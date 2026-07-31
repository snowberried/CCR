package com.snowberried.ctcinereviewer

import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameRequest
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.GenerationToken
import org.junit.Assert.assertEquals
import org.junit.Test

class ViewerStateTest {
    @Test
    fun `rapid moves accumulate from requested while displayed remains unchanged`() {
        val displayed = FrameKey(0, 0, 0)
        var state = ViewerUiState(metadata = metadata(), displayedFrame = displayed)

        repeat(3) { state = state.moveRequestedBy(1) }
        state = state.moveRequestedBy(5)

        assertEquals(8, state.requestedFrameIndex)
        assertEquals(displayed, state.displayedFrame)
        assertEquals(11, state.moveRequestedBy(100).requestedFrameIndex)
        assertEquals(0, state.moveRequestedBy(-100).requestedFrameIndex)
    }

    @Test
    fun `only current file Published changes displayed frame`() {
        val original = FrameKey(1, 1_000, 0)
        val target = FrameKey(7, 7_000, 0)
        val state = ViewerUiState(
            metadata = metadata(),
            requestedFrameIndex = 7,
            displayedFrame = original,
            activeFileGeneration = 4,
            activeRequestGeneration = 9,
        )
        val currentRequest = FrameRequest(GenerationToken(4, 9), 7, target)
        val oldRequest = FrameRequest(GenerationToken(3, 99), 8, FrameKey(8, 8_000, 0))
        val oldSameFileRequest = FrameRequest(GenerationToken(4, 8), 6, FrameKey(6, 6_000, 0))

        val published = state.applyFrameResult(
            FrameResult.Published(currentRequest, 7_000_000, false, null),
            DecoderDiagnostics(),
        )
        assertEquals(target, published.displayedFrame)
        assertEquals(7, published.requestedFrameIndex)

        val stale = published.applyFrameResult(
            FrameResult.DiscardedStale(currentRequest, "test"),
            DecoderDiagnostics(staleDiscardCount = 1),
        )
        assertEquals(target, stale.displayedFrame)

        val ignoredOldFile = stale.applyFrameResult(
            FrameResult.Published(oldRequest, 8_000_000, false, null),
            DecoderDiagnostics(),
        )
        assertEquals(stale, ignoredOldFile)

        val ignoredOldRequest = stale.applyFrameResult(
            FrameResult.Error(oldSameFileRequest, "DECODE_FAILED"),
            DecoderDiagnostics(),
        )
        assertEquals(stale, ignoredOldRequest)
    }

    private fun metadata(): ContainerMetadata = ContainerMetadata(
        fileGeneration = 4,
        mime = "video/avc",
        profile = null,
        codedWidth = 16,
        codedHeight = 16,
        cropLeft = 0,
        cropTop = 0,
        cropRight = 15,
        cropBottom = 15,
        rotationDegrees = 0,
        pixelAspectRatioWidth = 1,
        pixelAspectRatioHeight = 1,
        durationUs = 12_000,
        frameCount = 12,
        codecComponent = "hardware.decoder",
        hardwareAccelerated = true,
    )
}
