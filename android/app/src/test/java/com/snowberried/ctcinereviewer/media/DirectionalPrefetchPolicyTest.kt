package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectionalPrefetchPolicyTest {
    private val cacheBudget = 128L * 1024L * 1024L

    @Test
    fun `initial and forward requests look ahead by at most twelve frames`() {
        val initial = directionalPrefetchPlan(null, 0, 100)
        val forward = directionalPrefetchPlan(10, 15, 100)

        assertEquals(DirectionalPrefetchDirection.FORWARD, initial.direction)
        assertEquals(1..12, initial.frameIndexes)
        assertEquals(DirectionalPrefetchDirection.FORWARD, forward.direction)
        assertEquals(16..27, forward.frameIndexes)
    }

    @Test
    fun `reverse request caches only the bounded look-behind window`() {
        val reverse = directionalPrefetchPlan(50, 30, 100)
        val clipped = directionalPrefetchPlan(10, 3, 100)

        assertEquals(DirectionalPrefetchDirection.REVERSE, reverse.direction)
        assertEquals(18 until 30, reverse.frameIndexes)
        assertEquals(0 until 3, clipped.frameIndexes)
        assertEquals(DIRECTIONAL_PREFETCH_FRAME_LIMIT, reverse.frameIndexes.count())
    }

    @Test
    fun `prefetch window clips to file boundaries`() {
        assertEquals(96..99, directionalPrefetchPlan(90, 95, 100).frameIndexes)
        assertTrue(directionalPrefetchPlan(98, 99, 100).frameIndexes.isEmpty())
        assertTrue(directionalPrefetchPlan(1, 0, 100).frameIndexes.isEmpty())
    }

    @Test
    fun `canonical RGBA bytes and effective limits scale with resolution`() {
        val p720 = prefetchBudgetDecision(1280, 720, cacheBudget)
        val p1080 = prefetchBudgetDecision(1920, 1080, cacheBudget)
        val p1440 = prefetchBudgetDecision(2560, 1440, cacheBudget)
        val p4k = prefetchBudgetDecision(3840, 2160, cacheBudget)

        assertEquals(3_686_400L, p720.canonicalFrameBytes)
        assertEquals(8_294_400L, p1080.canonicalFrameBytes)
        assertEquals(14_745_600L, p1440.canonicalFrameBytes)
        assertEquals(33_177_600L, p4k.canonicalFrameBytes)
        assertEquals(12, p720.effectivePrefetchLimit)
        assertEquals(12, p1080.effectivePrefetchLimit)
        assertEquals(5, p1440.effectivePrefetchLimit)
        assertEquals(0, p4k.effectivePrefetchLimit)
    }

    @Test
    fun `invalid overflow and frame larger than budget disable prefetch`() {
        assertEquals(0L, canonicalFrameBytes(0, 720))
        assertEquals(0L, canonicalFrameBytes(Int.MAX_VALUE, Int.MAX_VALUE))
        assertEquals(0, prefetchBudgetDecision(3840, 2160, 30_000_000L).effectivePrefetchLimit)
        assertTrue(directionalPrefetchPlan(null, 4, 10, frameLimit = 0).frameIndexes.isEmpty())
    }

    @Test
    fun `direction reversal and foreground request invalidate old prefetch run`() {
        val oldToken = GenerationToken(fileGeneration = 7, requestGeneration = 3)
        val run = PrefetchRunState(
            token = oldToken,
            direction = DirectionalPrefetchDirection.FORWARD,
            targetFrameIndex = 10,
            candidates = listOf(11, 12, 13),
        )
        assertTrue(run.isCurrent(oldToken))
        assertEquals(false, run.isCurrent(oldToken.copy(requestGeneration = 4)))
        assertEquals(false, run.isCurrent(oldToken.copy(fileGeneration = 8)))

        run.markStarted(11)
        val cancellation = run.cancel()
        assertEquals(3, cancellation.cancelled)
        assertEquals(1, cancellation.wasted)
        assertTrue(run.isComplete)
    }

    @Test
    fun `accepted foreground request preempts post-publication prefetch token immediately`() {
        val gate = PublicationGate()
        val fileToken = gate.beginFile()
        val first = gate.acceptInitialRequest(fileToken, 10, FrameKey(10, 10_000, 0))!!.request
        val run = PrefetchRunState(
            token = first.token,
            direction = DirectionalPrefetchDirection.FORWARD,
            targetFrameIndex = 10,
            candidates = listOf(11, 12),
        )
        assertTrue(gate.isCurrent(run.token))

        gate.acceptRequest(fileToken.fileGeneration, 15, FrameKey(15, 15_000, 0))

        assertEquals(false, gate.isCurrent(run.token))
        assertEquals(PrefetchCancellation(cancelled = 2, wasted = 0), run.cancel())
    }

    @Test
    fun `recalculated canonical size drops farthest unstarted work`() {
        val run = PrefetchRunState(
            token = GenerationToken(1, 1),
            direction = DirectionalPrefetchDirection.REVERSE,
            targetFrameIndex = 20,
            candidates = listOf(8, 9, 10, 11, 12),
        )
        val cancellation = run.limitTo(2)

        assertEquals(3, cancellation.cancelled)
        assertTrue(run.contains(11))
        assertTrue(run.contains(12))
    }
}
