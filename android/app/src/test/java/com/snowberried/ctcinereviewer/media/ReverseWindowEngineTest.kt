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
    fun `rolling tail remains the next anchor after every appended target is consumed`() {
        val video = video(20)
        val initial = plan(video, anchorIndex = 14, targetCount = 5)
        val engine = readyEngine(initial)
        initial.publicationTargets.take(2).forEach { engine.consume(it.key, IDENTITY) }
        val firstRolling = plan(video, anchorIndex = 9, targetCount = 2)
        assertTrue(
            engine.appendRefill(firstRolling, firstRolling.publicationTargets.map { it.key }, IDENTITY) is
                ReverseWindowRefillResult.Ready,
        )

        engine.snapshot().remainingTargetKeys.forEach { engine.consume(it, IDENTITY) }
        assertEquals(ReverseWindowSlotState.EXHAUSTED, engine.snapshot().state)
        assertEquals(7, engine.snapshot().oldestTarget?.displayFrameIndex)

        val secondRolling = plan(video, anchorIndex = 7, targetCount = 2)
        assertTrue(
            engine.appendRefill(secondRolling, secondRolling.publicationTargets.map { it.key }, IDENTITY) is
                ReverseWindowRefillResult.Ready,
        )
        assertEquals(listOf(6, 5), engine.snapshot().remainingTargetKeys.map { it.displayFrameIndex })
        assertEquals(5, engine.snapshot().oldestTarget?.displayFrameIndex)
    }

    @Test
    fun `publication ticket consumes only the same current-next target after a successful swap`() {
        val video = video(16)
        val initial = plan(video, anchorIndex = 12, targetCount = 5)
        val engine = readyEngine(initial)
        val expected = initial.publicationTargets.first()
        val ticket = checkNotNull(engine.acquirePublicationTicket(expected.key, -1))
        assertEquals(IDENTITY, ticket.identity)
        assertEquals(ticket, engine.acquirePublicationTicket(expected.key, -1, IDENTITY))
        assertTrue(engine.isPublicationTicketCurrent(ticket))

        val hit = engine.consume(ticket, IDENTITY) as ReverseWindowConsumeResult.Hit
        assertEquals(expected, hit.target)
        assertEquals(4, hit.remainingTargetCount)
        assertFalse(engine.isPublicationTicketCurrent(ticket))

        val reused = engine.consume(ticket, IDENTITY) as ReverseWindowConsumeResult.Fallback
        assertEquals(ReverseWindowFallbackReason.PUBLICATION_TICKET_STALE, reused.reason)
        assertEquals(ReverseWindowSlotState.READY, engine.snapshot().state)
        assertEquals(0L, engine.snapshot().invalidationCount)
        assertEquals(null, engine.acquirePublicationTicket(initial.publicationTargets[2].key, -1, IDENTITY))
        assertEquals(null, engine.acquirePublicationTicket(initial.publicationTargets[1].key, -5, IDENTITY))
    }

    @Test
    fun `publication ticket survives an ordered append behind it but not a replacement window`() {
        val video = video(20)
        val initial = plan(video, anchorIndex = 14, targetCount = 5)
        val engine = readyEngine(initial)
        initial.publicationTargets.take(2).forEach { engine.consume(it.key, IDENTITY) }
        val ticket = checkNotNull(engine.acquirePublicationTicket(initial.publicationTargets[2].key, -1))
        val rolling = plan(video, anchorIndex = 9, targetCount = 2)
        rolling.decodeTargets.forEach { target ->
            engine.stageRefillTarget(rolling, target.key, IDENTITY)
        }
        assertTrue(engine.isPublicationTicketCurrent(ticket))
        assertTrue(engine.consume(ticket, IDENTITY) is ReverseWindowConsumeResult.Hit)

        val replacementTicket = checkNotNull(engine.acquirePublicationTicket(initial.publicationTargets[3].key, -1))
        engine.invalidate(ReverseWindowFallbackReason.CANCELLED)
        assertTrue(
            engine.refill(initial, initial.publicationTargets.map { it.key }, IDENTITY) is
                ReverseWindowRefillResult.Ready,
        )
        assertFalse(engine.isPublicationTicketCurrent(replacementTicket))
        assertEquals(
            ReverseWindowFallbackReason.PUBLICATION_TICKET_STALE,
            (engine.consume(replacementTicket, IDENTITY) as ReverseWindowConsumeResult.Fallback).reason,
        )
        assertEquals(ReverseWindowSlotState.READY, engine.snapshot().state)
    }

    @Test
    fun `ordered staged append hides an older output until the contiguous prefix is ready`() {
        val video = video(20)
        val initial = plan(video, anchorIndex = 14, targetCount = 5)
        val engine = readyEngine(initial)
        initial.publicationTargets.take(2).forEach { engine.consume(it.key, IDENTITY) }
        val rolling = plan(video, anchorIndex = 9, targetCount = 2)

        val olderFirst = engine.stageRefillTarget(
            rolling,
            rolling.publicationTargets.last().key,
            IDENTITY,
        ) as ReverseWindowPartialAppendResult.Accepted
        assertTrue(olderFirst.appendedTargets.isEmpty())
        assertFalse(olderFirst.completed)
        assertEquals(listOf(11, 10, 9), engine.snapshot().remainingTargetKeys.map { it.displayFrameIndex })
        assertEquals(1, engine.snapshot().stagedReadyCount)

        val contiguous = engine.stageRefillTarget(
            rolling,
            rolling.publicationTargets.first().key,
            IDENTITY,
        ) as ReverseWindowPartialAppendResult.Accepted
        assertEquals(listOf(8, 7), contiguous.appendedTargets.map { it.key.displayFrameIndex })
        assertTrue(contiguous.completed)
        assertEquals(listOf(11, 10, 9, 8, 7), engine.snapshot().remainingTargetKeys.map { it.displayFrameIndex })
        assertEquals(0, engine.snapshot().stagedTargetCount)
        assertEquals(1L, engine.snapshot().partialAppendCount)
        assertEquals(1L, engine.snapshot().rollingAppendRefillCount)
    }

    @Test
    fun `staged refill enforces capacity and discards only uncommitted keys`() {
        val video = video(20)
        val initial = plan(video, anchorIndex = 14, targetCount = 5)
        val engine = readyEngine(initial)
        initial.publicationTargets.take(2).forEach { engine.consume(it.key, IDENTITY) }

        val tooLarge = plan(video, anchorIndex = 9, targetCount = 3)
        val rejected = engine.stageRefillTarget(tooLarge, tooLarge.publicationTargets.last().key, IDENTITY)
        assertEquals(
            ReverseWindowFallbackReason.READY_KEYS_MISMATCH,
            (rejected as ReverseWindowPartialAppendResult.Fallback).reason,
        )
        assertEquals(listOf(11, 10, 9), engine.snapshot().remainingTargetKeys.map { it.displayFrameIndex })

        val rolling = plan(video, anchorIndex = 9, targetCount = 2)
        val stagedKey = rolling.publicationTargets.last().key
        engine.stageRefillTarget(rolling, stagedKey, IDENTITY)
        val wrong = engine.stageRefillTarget(rolling, video.frames[0].key, IDENTITY)
        assertTrue(wrong is ReverseWindowPartialAppendResult.Fallback)
        assertEquals(setOf(stagedKey), engine.discardStagedRefill(ReverseWindowFallbackReason.CANCELLED))
        assertEquals(listOf(11, 10, 9), engine.snapshot().remainingTargetKeys.map { it.displayFrameIndex })
        assertEquals(ReverseWindowSlotState.READY, engine.snapshot().state)
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
