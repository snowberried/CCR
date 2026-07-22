package com.snowberried.ctcinereviewer.media

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReverseRefillPolicyTest {
    @Test
    fun `cold-start low-water follows byte-capacity candidates`() {
        assertFalse(decision(0).enabled)
        assertFalse(decision(1).enabled)
        assertEquals(1, decision(2).remainingTargetMark)
        assertEquals(2, decision(3).remainingTargetMark)
        assertEquals(3, decision(4).remainingTargetMark)
        assertEquals(4, decision(5).remainingTargetMark)
        assertEquals(4, decision(6).remainingTargetMark)
        assertEquals(4, decision(12).remainingTargetMark)
    }

    @Test
    fun `measured latency raises and clamps the low-water mark by cadence`() {
        val raised = reverseRefillLowWaterDecision(
            targetCapacity = 8,
            measuredRefillLatencyUs = 400_003,
            cadenceUs = 66_667,
        )
        assertEquals(7, raised.latencyTargetCount)
        assertEquals(7, raised.remainingTargetMark)

        val clamped = reverseRefillLowWaterDecision(
            targetCapacity = 6,
            measuredRefillLatencyUs = 2_000_000,
            cadenceUs = 66_667,
        )
        assertEquals(30, clamped.latencyTargetCount)
        assertEquals(5, clamped.remainingTargetMark)
    }

    @Test
    fun `low-water start predicate never enables a disabled capacity`() {
        assertFalse(decision(1).shouldStart(0))
        assertTrue(decision(6).shouldStart(4))
        assertFalse(decision(6).shouldStart(5))
    }

    @Test
    fun `generation accounting rejects a second seek or flush and closes exactly once`() {
        val generation = ReverseRefillGenerationState(7)
        generation.recordFlush()
        generation.recordSeek()
        repeat(3) { generation.recordResumedSlice() }
        repeat(2) { generation.recordCachedTarget() }
        generation.recordConsumedDuringBuild()

        assertFails { generation.recordSeek() }
        assertFails { generation.recordFlush() }
        assertTrue(generation.complete())
        assertFalse(generation.complete())
        assertFalse(generation.cancel(ReverseWindowFallbackReason.CANCELLED))
        val snapshot = generation.snapshot()
        assertEquals(ReverseRefillGenerationPhase.COMPLETED, snapshot.phase)
        assertEquals(1, snapshot.seekCount)
        assertEquals(1, snapshot.flushCount)
        assertEquals(3L, snapshot.resumedSliceCount)
        assertEquals(2, snapshot.cachedTargetCount)
        assertEquals(1, snapshot.consumedDuringBuildCount)
    }

    @Test
    fun `generation cancellation preserves the first exact reason`() {
        val generation = ReverseRefillGenerationState(8)
        assertTrue(generation.cancel(ReverseWindowFallbackReason.DIRECTION_CHANGED))
        assertFalse(generation.cancel(ReverseWindowFallbackReason.CANCELLED))
        assertEquals(
            ReverseWindowFallbackReason.DIRECTION_CHANGED,
            generation.snapshot().cancelledReason,
        )
        assertFails { generation.recordResumedSlice() }
    }

    @Test
    fun `depletion latch remembers a transient zero until generation completion`() {
        val completedBeforeDepletion = ReverseRefillDepletionLatch(4)
        completedBeforeDepletion.observeRemainingTargetCount(2)
        assertFalse(completedBeforeDepletion.depletedDuringBuild)

        val depletedThenRefilled = ReverseRefillDepletionLatch(2)
        depletedThenRefilled.observeRemainingTargetCount(0)
        depletedThenRefilled.observeRemainingTargetCount(3)
        assertTrue(depletedThenRefilled.depletedDuringBuild)

        assertTrue(ReverseRefillDepletionLatch(0).depletedDuringBuild)
        assertFails { ReverseRefillDepletionLatch(-1) }
    }

    @Test
    fun `depletion tracker orders an EGL consume before generation completion`() {
        val identity = ReverseWindowIdentity(1, 2, 3, 4)
        val observation = ReverseRefillDepletionObservation(
            identity = identity,
            generationId = 9,
            latch = ReverseRefillDepletionLatch(1),
        )
        val tracker = ReverseRefillDepletionTracker().also { it.activate(observation) }
        val consumeEntered = CountDownLatch(1)
        val releaseConsume = CountDownLatch(1)
        val consumed = AtomicReference<ReverseWindowConsumeResult>()
        val consumeThread = thread {
            consumed.set(
                tracker.consumeAndObserve(identity) {
                    consumeEntered.countDown()
                    assertTrue(releaseConsume.await(1, TimeUnit.SECONDS))
                    ReverseWindowConsumeResult.Hit(frame(7), 0, true)
                },
            )
        }
        assertTrue(consumeEntered.await(1, TimeUnit.SECONDS))
        val completedDepleted = AtomicReference<Boolean>()
        val finishThread = thread { completedDepleted.set(tracker.finish(observation)) }

        releaseConsume.countDown()
        consumeThread.join(1_000)
        finishThread.join(1_000)

        assertTrue(consumed.get() is ReverseWindowConsumeResult.Hit)
        assertEquals(true, completedDepleted.get())
    }

    @Test
    fun `depletion tracker ignores a different window identity`() {
        val identity = ReverseWindowIdentity(1, 2, 3, 4)
        val observation = ReverseRefillDepletionObservation(
            identity = identity,
            generationId = 10,
            latch = ReverseRefillDepletionLatch(1),
        )
        val tracker = ReverseRefillDepletionTracker().also { it.activate(observation) }

        tracker.consumeAndObserve(identity.copy(gestureEpoch = 5)) {
            ReverseWindowConsumeResult.Hit(frame(6), 0, true)
        }

        assertFalse(tracker.finish(observation))
    }

    private fun decision(capacity: Int) = reverseRefillLowWaterDecision(
        targetCapacity = capacity,
        cadenceUs = 66_667,
    )

    private fun frame(index: Int) = IndexedFrame(
        key = FrameKey(index, index * 1_000L, 0),
        sampleOrdinal = index,
        sync = false,
    )

    private fun assertFails(block: () -> Unit) {
        assertTrue(runCatching(block).isFailure)
    }
}
