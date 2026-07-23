package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CachedNavigationPublisherTest {
    @Test
    fun `published outcome wins exactly once even when lane calls back twice`() {
        val input = input()
        var published = 0
        var fallback = 0
        var terminal = 0
        val publisher = CachedNavigationPublisher { candidate, contextCurrent, complete ->
            assertSame(input, candidate)
            assertTrue(contextCurrent(candidate))
            complete(published(candidate))
            complete(CachedNavigationOutcome.Miss(candidate, CachedNavigationMissReason.NOT_CACHED))
            false
        }

        publisher.submit(
            input = input,
            contextCurrent = { true },
            onPublished = { published += 1 },
            onFallback = { fallback += 1 },
            onTerminal = { terminal += 1 },
        )

        assertEquals(1, published)
        assertEquals(0, fallback)
        assertEquals(0, terminal)
    }

    @Test
    fun `miss falls back once with the original accepted request and generations`() {
        val input = input()
        var observed: CachedNavigationOutcome.Miss? = null
        val publisher = CachedNavigationPublisher { candidate, _, complete ->
            complete(CachedNavigationOutcome.Miss(candidate, CachedNavigationMissReason.NOT_CACHED))
            true
        }

        publisher.submit(
            input = input,
            contextCurrent = { true },
            onPublished = { fail("unexpected publication") },
            onFallback = { observed = it },
            onTerminal = { fail("unexpected terminal outcome") },
        )

        assertSame(input, observed?.input)
        assertSame(input.request, observed?.input?.request)
        assertEquals(7L, observed?.input?.request?.token?.fileGeneration)
        assertEquals(11L, observed?.input?.request?.token?.requestGeneration)
        assertEquals(3L, observed?.input?.surfaceGeneration)
        assertEquals(5L, observed?.input?.gestureGeneration)
    }

    @Test
    fun `stale and error are terminal and never decode fallbacks`() {
        val input = input()
        for (outcome in listOf<CachedNavigationOutcome>(
            CachedNavigationOutcome.Stale(input, "FILE_CHANGED"),
            CachedNavigationOutcome.Error(input, "EGL_SWAP_FAILED"),
        )) {
            var fallback = 0
            var terminal: CachedNavigationOutcome? = null
            val publisher = CachedNavigationPublisher { _, _, complete ->
                complete(outcome)
                true
            }
            publisher.submit(
                input = input,
                contextCurrent = { true },
                onPublished = { fail("unexpected publication") },
                onFallback = { fallback += 1 },
                onTerminal = { terminal = it },
            )
            assertEquals(0, fallback)
            assertSame(outcome, terminal)
        }
    }

    @Test
    fun `queue rejection uses the same request for the actor fallback`() {
        val input = input()
        var fallback: CachedNavigationOutcome.Miss? = null
        CachedNavigationPublisher { _, _, _ -> false }.submit(
            input = input,
            contextCurrent = { true },
            onPublished = { fail("unexpected publication") },
            onFallback = { fallback = it },
            onTerminal = { fail("unexpected terminal outcome") },
        )

        assertSame(input, fallback?.input)
        assertEquals(CachedNavigationMissReason.QUEUE_REJECTED, fallback?.reason)
    }

    @Test
    fun `pending registry completes queued file change once and ignores late EGL result`() {
        val registry = CachedNavigationPendingRegistry()
        val input = input()
        val outcomes = mutableListOf<CachedNavigationOutcome>()
        val ticket = registry.register(input, outcomes::add)

        registry.completeAll { CachedNavigationOutcome.Stale(it, "FILE_CHANGED") }
        val acceptedLate = registry.complete(ticket, published(input))

        assertFalse(acceptedLate)
        assertEquals(1, outcomes.size)
        assertEquals("FILE_CHANGED", (outcomes.single() as CachedNavigationOutcome.Stale).code)
        assertEquals(0, registry.size)
    }

    @Test
    fun `pending registry drains close callbacks even when a callback throws`() {
        val registry = CachedNavigationPendingRegistry()
        val first = registry.register(input(requestGeneration = 11)) { error("listener failed") }
        var secondCount = 0
        registry.register(input(requestGeneration = 12)) { secondCount += 1 }

        registry.completeAll { CachedNavigationOutcome.Stale(it, "RENDERER_CLOSED") }

        assertFalse(registry.isPending(first))
        assertEquals(1, secondCount)
        assertEquals(0, registry.size)
    }

    @Test
    fun `input retains full frame key and rejects index-only mismatches`() {
        val exact = input()
        assertEquals(FrameKey(23, 958_333, 2), exact.request.expectedKey)
        assertEquals(setOf(CachedNavigationSource.BACKWARD_HISTORY, CachedNavigationSource.REVERSE_WINDOW), exact.allowedSources)

        try {
            input(requestedFrameIndex = 22)
            fail("index-only mismatch must be rejected")
        } catch (_: IllegalArgumentException) {
            Unit
        }
    }

    private fun input(
        requestGeneration: Long = 11,
        requestedFrameIndex: Int = 23,
    ): CachedNavigationInput = CachedNavigationInput(
        request = FrameRequest(
            token = GenerationToken(fileGeneration = 7, requestGeneration = requestGeneration),
            requestedFrameIndex = requestedFrameIndex,
            expectedKey = FrameKey(displayFrameIndex = 23, ptsUs = 958_333, duplicateOrdinal = 2),
        ),
        surfaceGeneration = 3,
        gestureGeneration = 5,
        signedStride = -1,
        allowedSources = setOf(
            CachedNavigationSource.BACKWARD_HISTORY,
            CachedNavigationSource.REVERSE_WINDOW,
        ),
    )

    private fun published(input: CachedNavigationInput): CachedNavigationOutcome.Published =
        CachedNavigationOutcome.Published(
            input = input,
            event = PublicationEvent(
                eventSequence = 1,
                elapsedRealtimeNanos = 2,
                fileGeneration = input.request.token.fileGeneration,
                requestGeneration = input.request.token.requestGeneration,
                requestedFrameIndex = input.request.requestedFrameIndex,
                expectedKey = input.request.expectedKey,
                currentFileGeneration = input.request.token.fileGeneration,
                currentRequestGeneration = input.request.token.requestGeneration,
                textureTimestampNs = input.request.expectedKey.ptsUs * 1_000,
                swapAttempted = true,
                eglSwapBuffersResult = true,
                result = PublicationResult.PUBLISHED,
            ),
            source = CachedNavigationSource.REVERSE_WINDOW,
            imageProbe = null,
        )
}
