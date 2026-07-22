package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RandomSeekPlannerTest {
    @Test
    fun `no-op cache history and reverse window use exact fixed priority`() {
        val video = video()
        val target = video.frames[4].key
        val allHits = setOf(target)

        assertEquals(
            RandomSeekPlanKind.NO_OP,
            plan(video, target, displayed = target, cache = allHits, history = allHits, window = allHits).kind,
        )
        assertEquals(
            RandomSeekPlanKind.CACHE,
            plan(video, target, cache = allHits, history = allHits, window = allHits).kind,
        )
        assertEquals(
            RandomSeekPlanKind.HISTORY,
            plan(video, target, history = allHits, window = allHits).kind,
        )
        val windowPlan = plan(video, target, window = allHits)
        assertEquals(RandomSeekPlanKind.REVERSE_WINDOW, windowPlan.kind)
        assertEquals(0, windowPlan.actualDecodeOutputCount)
        assertFalse(windowPlan.flushRequired)
        assertEquals(RandomSeekFallbackReason.NONE, windowPlan.fallbackReason)
        assertEquals(0, windowPlan.previousSyncFrameIndex)
        assertFalse(windowPlan.auxiliaryUsed)
    }

    @Test
    fun `target requires exact indexed FrameKey including PTS and duplicate ordinal`() {
        val video = video()
        val indexed = video.frames[2].key

        assertFailsRequirement {
            plan(video, indexed.copy(ptsUs = indexed.ptsUs + 1))
        }
        assertFailsRequirement {
            plan(video, indexed.copy(duplicateOrdinal = indexed.duplicateOrdinal + 1))
        }
    }

    @Test
    fun `low-cost cursor continuation wins without flush`() {
        val video = video()
        val cursor = cursor(video, 1)
        val result = plan(video, video.frames[4].key, cursor = cursor)

        assertEquals(RandomSeekPlanKind.SEQUENTIAL_AHEAD, result.kind)
        assertEquals(cursor, result.sourceDecoderCursor)
        assertEquals(3, result.estimatedDecodeOutputCount)
        assertNull(result.actualDecodeOutputCount)
        assertFalse(result.flushRequired)
        assertEquals(RandomSeekCacheExpectation.CACHE_MISS, result.expectedCacheResult)
        assertEquals(TOKEN, result.generation)
        assertEquals(RandomSeekFallbackReason.NONE, result.fallbackReason)
        assertEquals(1, result.observedDecoderCursorFrameIndex)
        assertEquals(0, result.previousSyncFrameIndex)
    }

    @Test
    fun `same GOP cursor is reused beyond low-cost continuation limit`() {
        val video = video(syncOrdinals = setOf(0, 8))
        val cursor = cursor(video, 1)
        val result = RandomSeekPlanner(lowCostSequentialOutputLimit = 2).plan(
            input(video, video.frames[6].key, cursor = cursor),
        )

        assertEquals(RandomSeekPlanKind.SAME_GOP_CURSOR, result.kind)
        assertEquals(5, result.estimatedDecodeOutputCount)
        assertFalse(result.flushRequired)
        assertEquals(0, result.previousSync.sampleOrdinal)
    }

    @Test
    fun `runtime continuation fallback reports the final previous-sync plan`() {
        val video = video(syncOrdinals = setOf(0, 8))
        val planned = RandomSeekPlanner(lowCostSequentialOutputLimit = 2).plan(
            input(video, video.frames[6].key, cursor = cursor(video, 1)),
        )
        val selected = planned
            .fallbackToPreviousSync(RandomSeekFallbackReason.OUTPUT_FRAME_UNMAPPED, 7)
            .withActualDecodeOutputCount(9)

        assertEquals(RandomSeekPlanKind.SAME_GOP_CURSOR, planned.kind)
        assertEquals(RandomSeekPlanKind.PREVIOUS_SYNC, selected.kind)
        assertEquals(RandomSeekFallbackReason.OUTPUT_FRAME_UNMAPPED, selected.fallbackReason)
        assertEquals(7, selected.estimatedDecodeOutputCount)
        assertEquals(9, selected.actualDecodeOutputCount)
        assertTrue(selected.flushRequired)
        assertNull(selected.sourceDecoderCursor)
    }

    @Test
    fun `previous sync beats an expensive cross-GOP cursor and requires one flush`() {
        val video = video(syncOrdinals = setOf(0, 8))
        val cursor = cursor(video, 1)
        val result = RandomSeekPlanner(lowCostSequentialOutputLimit = 2).plan(
            input(video, video.frames[9].key, cursor = cursor),
        )

        assertEquals(RandomSeekPlanKind.PREVIOUS_SYNC, result.kind)
        assertNull(result.sourceDecoderCursor)
        assertEquals(8, result.previousSync.sampleOrdinal)
        assertEquals(2, result.estimatedDecodeOutputCount)
        assertTrue(result.flushRequired)
        assertEquals(7, result.withActualDecodeOutputCount(7).actualDecodeOutputCount)
        assertEquals(RandomSeekFallbackReason.PREVIOUS_SYNC_LOWER_COST, result.fallbackReason)
        assertEquals(1, result.observedDecoderCursorFrameIndex)
        assertEquals(8, result.previousSyncFrameIndex)
    }

    @Test
    fun `different GOP fallback is reported when continuation is cheap but not eligible`() {
        val video = video(syncOrdinals = setOf(0, 8))
        val cursor = cursor(video, 7)
        val result = RandomSeekPlanner(lowCostSequentialOutputLimit = 0).plan(
            input(video, video.frames[9].key, cursor = cursor),
        )

        assertEquals(RandomSeekPlanKind.PREVIOUS_SYNC, result.kind)
        assertEquals(RandomSeekFallbackReason.DIFFERENT_GOP, result.fallbackReason)
        assertEquals(7, result.observedDecoderCursorFrameIndex)
        assertEquals(8, result.previousSyncFrameIndex)
        assertTrue(result.flushRequired)
    }

    @Test
    fun `stale unavailable or malformed cursor safely falls back to previous sync`() {
        val video = video()
        val target = video.frames[3].key
        val stale = cursor(video, 2).copy(fileGeneration = video.fileGeneration + 1)
        val wrongCodec = cursor(video, 2).copy(codecGeneration = CODEC_GENERATION + 1)
        val unavailable = cursor(video, 2).copy(continuationAvailable = false)
        val malformed = RandomSeekDecoderCursor(
            video.fileGeneration,
            CODEC_GENERATION,
            video.frames[2].copy(sampleOrdinal = 999),
        )

        listOf(stale, wrongCodec, unavailable, malformed).forEach { cursor ->
            val result = plan(video, target, cursor = cursor)
            assertEquals(RandomSeekPlanKind.PREVIOUS_SYNC, result.kind)
            assertEquals(RandomSeekFallbackReason.CURSOR_STALE, result.fallbackReason)
            assertEquals(2, result.observedDecoderCursorFrameIndex)
        }
    }

    @Test
    fun `missing or backward cursor records a canonical fallback reason`() {
        val video = video()
        val missing = plan(video, video.frames[3].key)
        assertEquals(RandomSeekFallbackReason.CURSOR_UNAVAILABLE, missing.fallbackReason)
        assertNull(missing.observedDecoderCursorFrameIndex)

        val backward = plan(video, video.frames[2].key, cursor = cursor(video, 4))
        assertEquals(RandomSeekPlanKind.PREVIOUS_SYNC, backward.kind)
        assertEquals(RandomSeekFallbackReason.TARGET_NOT_AHEAD, backward.fallbackReason)
        assertEquals(4, backward.observedDecoderCursorFrameIndex)
    }

    private fun plan(
        video: IndexedVideo,
        target: FrameKey,
        displayed: FrameKey? = null,
        cursor: RandomSeekDecoderCursor? = null,
        cache: Set<FrameKey> = emptySet(),
        history: Set<FrameKey> = emptySet(),
        window: Set<FrameKey> = emptySet(),
    ): RandomSeekPlan = RandomSeekPlanner().plan(
        input(video, target, displayed, cursor, cache, history, window),
    )

    private fun input(
        video: IndexedVideo,
        target: FrameKey,
        displayed: FrameKey? = null,
        cursor: RandomSeekDecoderCursor? = null,
        cache: Set<FrameKey> = emptySet(),
        history: Set<FrameKey> = emptySet(),
        window: Set<FrameKey> = emptySet(),
    ) = RandomSeekInput(
        video = video,
        generation = TOKEN,
        codecGeneration = CODEC_GENERATION,
        displayedKey = displayed,
        targetKey = target,
        decoderCursor = cursor,
        textureCacheKeys = cache,
        backwardHistoryKeys = history,
        reverseWindowKeys = window,
    )

    private fun video(syncOrdinals: Set<Int> = setOf(0, 5)): IndexedVideo = buildFrameIndex(
        fileGeneration = TOKEN.fileGeneration,
        samples = (0 until 10).map { ordinal ->
            IndexedSample(
                sampleOrdinal = ordinal,
                ptsUs = ordinal * 1_000L,
                sync = ordinal in syncOrdinals,
            )
        },
    )

    private fun key(index: Int) = FrameKey(index, index * 1_000L, 0)

    private fun cursor(video: IndexedVideo, index: Int) = RandomSeekDecoderCursor(
        fileGeneration = video.fileGeneration,
        codecGeneration = CODEC_GENERATION,
        frame = video.frames[index],
    )

    private fun assertFailsRequirement(block: () -> Unit) {
        try {
            block()
            fail("Expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // Expected.
        }
    }

    private companion object {
        val TOKEN = GenerationToken(fileGeneration = 11, requestGeneration = 19)
        const val CODEC_GENERATION = 23L
    }
}
