package com.snowberried.ctcinereviewer

import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SanitizedDiagnosticsTest {
    @Test
    fun `copy report contains operational fields and excludes free-form state`() {
        val state = ViewerUiState(
            status = "error",
            detail = "C:/Users/person/patient-name.mp4",
            notice = "content://patient/123",
            metadata = ContainerMetadata(
                fileGeneration = 7,
                mime = "video/avc",
                profile = 8,
                codedWidth = 1920,
                codedHeight = 1080,
                cropLeft = 0,
                cropTop = 0,
                cropRight = 1919,
                cropBottom = 1079,
                rotationDegrees = 0,
                pixelAspectRatioWidth = 1,
                pixelAspectRatioHeight = 1,
                durationUs = 1_000_000,
                frameCount = 24,
                codecComponent = "c2.vendor.avc.decoder",
                hardwareAccelerated = true,
            ),
            requestedFrameIndex = 4,
            diagnostics = DecoderDiagnostics(
                cacheHitCount = 2,
                cacheMissCount = 1,
                foregroundDecodedFrameCount = 3,
                requestCoalescedCount = 4,
                prefetchRequested = 6,
                prefetchWasted = 1,
                cacheBudgetBytes = 128L * 1024 * 1024,
            ),
            activeFileGeneration = 7,
            activeRequestGeneration = 9,
            currentDecodeTarget = 4,
            latestPendingRequest = 5,
            recentRequestToPublishLatencyMs = listOf(3.0, 1.0, 2.0),
            lastPublicationResult = "PUBLISHED",
            surfaceGeneration = 2,
            lastErrorCode = "DECODE_FAILED",
        )

        val report = buildSanitizedDiagnostics(
            state,
            DiagnosticBuildInfo("0.2.0-alpha.2", 3, "abc123", "SM-S928N", 36),
        )

        for (required in listOf(
            "app.version=0.2.0-alpha.2",
            "codec.component=c2.vendor.avc.decoder",
            "video.canonical=1920x1080",
            "frame.decodeTarget=4",
            "frame.latestPending=5",
            "frame.foregroundDecoded=3",
            "request.coalesced=4",
            "prefetch.wasted=1",
            "latency.requestToPublish.p95Ms=3.000",
            "generation.surface=2",
            "error.last=DECODE_FAILED",
        )) assertTrue(required, report.contains(required))
        for (forbidden in listOf("C:/Users", "patient-name", "content://", "patient/123")) {
            assertFalse(forbidden, report.contains(forbidden, ignoreCase = true))
        }
    }

    @Test
    fun `error code accepts only bounded non-sensitive tokens`() {
        assertTrue(sanitizedErrorCode("DECODE_FAILED") == "DECODE_FAILED")
        assertTrue(sanitizedErrorCode("/storage/emulated/0/private.mp4") == "UNCLASSIFIED_ERROR")
        val report = buildSanitizedDiagnostics(
            ViewerUiState(lastErrorCode = "/storage/emulated/0/private.mp4"),
            DiagnosticBuildInfo("0.2.0-alpha.2", 3, "abc123", "SM-S928N", 36),
        )
        assertFalse(report.contains("private.mp4"))
        assertFalse(report.contains("storage", ignoreCase = true))
    }
}
