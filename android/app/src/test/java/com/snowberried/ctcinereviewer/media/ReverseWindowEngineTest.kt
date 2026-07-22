package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReverseWindowEngineTest {
    @Test
    fun `same-semantic reverse hit preserves an in-flight refill cache target`() {
        val video = video(12)
        val plan = plan(video, anchorIndex = 10, targetCount = 3)
        val engine = readyEngine(plan)

        assertTrue(engine.isReadyNextTarget(plan.publicationTargets.first().key, -1))
        assertFalse(engine.isReadyNextTarget(plan.publicationTargets[1].key, -1))
        assertFalse(engine.isReadyNextTarget(plan.publicationTargets.first().key, -5))

        engine.consume(plan.publicationTargets.first().key, IDENTITY)
        assertTrue(engine.isReadyNextTarget(plan.publicationTargets[1].key, -1))
        plan.publicationTargets.drop(1).forEach { engine.consume(it.key, IDENTITY) }
        assertFalse(engine.isReadyNextTarget(plan.publicationTargets.last().key, -1))
    }

    @Test
    fun `foreground requests pause without changing the semantic refill epoch`() {
        val epochs = ReverseRefillEpochs()
        val semantic = epochs.semanticEpoch()

        assertEquals(1L, epochs.acceptForeground())
        assertEquals(2L, epochs.acceptForeground())
        assertTrue(epochs.isSemanticCurrent(semantic))

        epochs.invalidateSemantic()
        assertFalse(epochs.isSemanticCurrent(semantic))
    }

    @Test
    fun `one READY slot consumes publication order then permits refill`() {
        val video = video(12)
        val firstPlan = plan(video, anchorIndex = 10, targetCount = 3)
        val engine = ReverseWindowEngine()

        val refill = engine.refill(firstPlan, firstPlan.decodeTargets.map { it.key }, IDENTITY)
        assertTrue(refill is ReverseWindowRefillResult.Ready)
        assertEquals(ReverseWindowSlotState.READY, engine.snapshot().state)
        assertEquals(1, engine.snapshot().readyWindowCount)
        assertEquals(9, engine.snapshot().nextTarget?.displayFrameIndex)

        val duplicateRefill = engine.refill(firstPlan, firstPlan.publicationTargets.map { it.key }, IDENTITY)
        assertEquals(
            ReverseWindowFallbackReason.WINDOW_ALREADY_READY,
            (duplicateRefill as ReverseWindowRefillResult.Fallback).reason,
        )
        assertEquals(1, engine.snapshot().readyWindowCount)

        firstPlan.publicationTargets.forEachIndexed { index, target ->
            val hit = engine.consume(target.key, IDENTITY) as ReverseWindowConsumeResult.Hit
            assertEquals(2 - index, hit.remainingTargetCount)
            assertEquals(index == 2, hit.refillRequired)
        }
        assertEquals(ReverseWindowSlotState.EXHAUSTED, engine.snapshot().state)
        assertTrue(engine.snapshot().refillNeeded)

        val secondPlan = plan(video, anchorIndex = 7, targetCount = 3)
        assertTrue(
            engine.refill(secondPlan, secondPlan.publicationTargets.map { it.key }, IDENTITY) is
                ReverseWindowRefillResult.Ready,
        )
        assertEquals(2L, engine.snapshot().refillCount)
        assertEquals(2L, engine.snapshot().initialWindowReadyCount)
        assertEquals(0L, engine.snapshot().rollingAppendRefillCount)
        assertEquals(3L, engine.snapshot().consumedCount)
    }

    @Test
    fun `ready membership requires exact duplicate PTS FrameKeys`() {
        val video = duplicatePtsVideo()
        val plan = plan(video, anchorIndex = 4, targetCount = 3)
        val keys = plan.publicationTargets.map { it.key }.toMutableList()
        keys[0] = keys[0].copy(duplicateOrdinal = keys[0].duplicateOrdinal + 1)
        val engine = ReverseWindowEngine()

        val result = engine.refill(plan, keys, IDENTITY)

        assertEquals(
            ReverseWindowFallbackReason.READY_KEYS_MISMATCH,
            (result as ReverseWindowRefillResult.Fallback).reason,
        )
        assertEquals(ReverseWindowSlotState.EMPTY, engine.snapshot().state)
    }

    @Test
    fun `rolling refill appends only freed capacity behind the remaining deque`() {
        val video = video(16)
        val initial = plan(video, anchorIndex = 12, targetCount = 5)
        val engine = readyEngine(initial)
        engine.consume(initial.publicationTargets[0].key, IDENTITY)
        engine.consume(initial.publicationTargets[1].key, IDENTITY)
        val before = engine.snapshot()
        assertEquals(3, before.remainingTargetCount)
        assertEquals(7, before.oldestTarget?.displayFrameIndex)
        assertEquals(5, before.targetCapacity)

        val refill = plan(video, anchorIndex = 7, targetCount = 2)
        val result = engine.appendRefill(refill, refill.publicationTargets.map { it.key }, IDENTITY)

        assertTrue(result is ReverseWindowRefillResult.Ready)
        assertEquals(5, engine.snapshot().remainingTargetCount)
        assertEquals(
            listOf(9, 8, 7, 6, 5),
            engine.snapshot().remainingTargetKeys.map { it.displayFrameIndex },
        )
        assertEquals(9, engine.snapshot().nextTarget?.displayFrameIndex)
        assertEquals(5, engine.snapshot().oldestTarget?.displayFrameIndex)
        assertEquals(2L, engine.snapshot().refillCount)
        assertEquals(1L, engine.snapshot().initialWindowReadyCount)
        assertEquals(1L, engine.snapshot().rollingAppendRefillCount)
        assertFalse(engine.snapshot().refillNeeded)
    }

    @Test
    fun `exhausted refill-needed latch survives until a rolling append becomes READY`() {
        val video = video(16)
        val initial = plan(video, anchorIndex = 8, targetCount = 2)
        val engine = readyEngine(initial)
        initial.publicationTargets.forEach { engine.consume(it.key, IDENTITY) }

        val exhausted = engine.snapshot()
        assertEquals(ReverseWindowSlotState.EXHAUSTED, exhausted.state)
        assertEquals(0, exhausted.readyWindowCount)
        assertEquals(0, exhausted.remainingTargetCount)
        assertTrue(exhausted.refillNeeded)
        assertEquals(initial.publicationTargets.last().key, exhausted.oldestTarget)
        assertEquals(1L, exhausted.initialWindowReadyCount)
        assertEquals(0L, exhausted.rollingAppendRefillCount)

        val rolling = plan(video, anchorIndex = 6, targetCount = 2)
        assertTrue(
            engine.appendRefill(rolling, rolling.publicationTargets.map { it.key }, IDENTITY) is
                ReverseWindowRefillResult.Ready,
        )
        val ready = engine.snapshot()
        assertEquals(ReverseWindowSlotState.READY, ready.state)
        assertFalse(ready.refillNeeded)
        assertEquals(1L, ready.initialWindowReadyCount)
        assertEquals(1L, ready.rollingAppendRefillCount)
        assertEquals(2L, ready.refillCount)
    }

    @Test
    fun `consume rejects wrong duplicate ordinal and discards stale window`() {
        val video = duplicatePtsVideo()
        val plan = plan(video, anchorIndex = 4, targetCount = 3)
        val engine = readyEngine(plan)
        val exact = plan.publicationTargets.first().key

        val result = engine.consume(exact.copy(duplicateOrdinal = exact.duplicateOrdinal + 1), IDENTITY)

        assertEquals(
            ReverseWindowFallbackReason.FRAME_KEY_MISMATCH,
            (result as ReverseWindowConsumeResult.Fallback).reason,
        )
        assertEquals(ReverseWindowSlotState.EMPTY, engine.snapshot().state)
        assertEquals(1L, engine.snapshot().invalidationCount)
    }

    @Test
    fun `out of order and outside targets fail closed with distinct reasons`() {
        val video = video(12)
        val plan = plan(video, anchorIndex = 10, targetCount = 3)

        val outOfOrder = readyEngine(plan).consume(plan.publicationTargets[1].key, IDENTITY)
        assertEquals(
            ReverseWindowFallbackReason.TARGET_NOT_NEXT,
            (outOfOrder as ReverseWindowConsumeResult.Fallback).reason,
        )

        val outside = readyEngine(plan).consume(video.frames[1].key, IDENTITY)
        assertEquals(
            ReverseWindowFallbackReason.TARGET_NOT_IN_WINDOW,
            (outside as ReverseWindowConsumeResult.Fallback).reason,
        )
    }

    @Test
    fun `file codec surface and gesture epochs independently invalidate READY`() {
        val video = video(12)
        val plan = plan(video, anchorIndex = 10, targetCount = 3)
        val changes = listOf(
            IDENTITY.copy(fileGeneration = 2) to ReverseWindowFallbackReason.FILE_GENERATION_CHANGED,
            IDENTITY.copy(codecGeneration = 3) to ReverseWindowFallbackReason.CODEC_GENERATION_CHANGED,
            IDENTITY.copy(surfaceGeneration = 4) to ReverseWindowFallbackReason.SURFACE_GENERATION_CHANGED,
            IDENTITY.copy(gestureEpoch = 5) to ReverseWindowFallbackReason.GESTURE_EPOCH_CHANGED,
        )

        changes.forEach { (changed, reason) ->
            val engine = readyEngine(plan)
            val result = engine.consume(plan.publicationTargets.first().key, changed)
            assertEquals(reason, (result as ReverseWindowConsumeResult.Fallback).reason)
            assertEquals(ReverseWindowSlotState.EMPTY, engine.snapshot().state)
            assertEquals(1L, engine.snapshot().invalidationCount)
        }
    }

    @Test
    fun `stale refill cannot create a READY slot`() {
        val video = video(12)
        val plan = plan(video, anchorIndex = 10, targetCount = 3)
        val engine = ReverseWindowEngine()
        val result = engine.refill(
            plan,
            plan.publicationTargets.map { it.key },
            IDENTITY.copy(surfaceGeneration = IDENTITY.surfaceGeneration + 1),
        )

        assertEquals(
            ReverseWindowFallbackReason.SURFACE_GENERATION_CHANGED,
            (result as ReverseWindowRefillResult.Fallback).reason,
        )
        assertEquals(ReverseWindowSlotState.EMPTY, engine.snapshot().state)
    }

    @Test
    fun `explicit direction direct seek and cancel invalidations remove READY`() {
        val video = video(12)
        val plan = plan(video, anchorIndex = 10, targetCount = 3)
        listOf(
            ReverseWindowFallbackReason.DIRECTION_CHANGED,
            ReverseWindowFallbackReason.DIRECT_SEEK,
            ReverseWindowFallbackReason.CANCELLED,
        ).forEach { reason ->
            val engine = readyEngine(plan)
            engine.invalidate(reason)
            val snapshot = engine.snapshot()
            assertEquals(ReverseWindowSlotState.EMPTY, snapshot.state)
            assertEquals(reason, snapshot.lastFallbackReason)
            assertEquals(1L, snapshot.invalidationCount)
        }
    }

    @Test
    fun `consume without READY reports fallback without a false invalidation`() {
        val engine = ReverseWindowEngine()
        val result = engine.consume(FrameKey(1, 1_000, 0), IDENTITY)

        assertEquals(
            ReverseWindowFallbackReason.WINDOW_NOT_READY,
            (result as ReverseWindowConsumeResult.Fallback).reason,
        )
        assertEquals(0L, engine.snapshot().invalidationCount)
        assertFalse(engine.snapshot().readyWindowCount > 0)
    }

    private fun readyEngine(plan: ReverseWindowPlan): ReverseWindowEngine =
        ReverseWindowEngine().also { engine ->
            assertTrue(
                engine.refill(plan, plan.publicationTargets.map { it.key }, IDENTITY) is
                    ReverseWindowRefillResult.Ready,
            )
        }

    private fun plan(
        video: IndexedVideo,
        anchorIndex: Int,
        targetCount: Int,
    ): ReverseWindowPlan = (
        buildReverseWindowPlan(
            video,
            IDENTITY,
            video.frames[anchorIndex].key,
            -1,
            ReverseWindowCapacity.fromBytes(targetCount * 100L, 100L),
        ) as ReverseWindowPlanDecision.Planned
        ).plan

    private fun video(frameCount: Int): IndexedVideo = buildFrameIndex(
        fileGeneration = IDENTITY.fileGeneration,
        samples = List(frameCount) { index -> IndexedSample(index, index * 1_000L, index % 5 == 0) },
    )

    private fun duplicatePtsVideo(): IndexedVideo = buildFrameIndex(
        fileGeneration = IDENTITY.fileGeneration,
        samples = listOf(
            IndexedSample(0, 0, true),
            IndexedSample(1, 1_000, false),
            IndexedSample(2, 1_000, false),
            IndexedSample(3, 1_000, false),
            IndexedSample(4, 2_000, false),
        ),
    )

    private companion object {
        val IDENTITY = ReverseWindowIdentity(1, 2, 3, 4)
    }
}
