package com.snowberried.ctcinereviewer.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReverseWindowPlanTest {
    @Test
    fun `byte budget supplies target capacity without a frame-count constant`() {
        val capacity = ReverseWindowCapacity.fromBytes(
            availableBytes = 3_686_400L * 4L + 1L,
            canonicalFrameBytes = 3_686_400L,
        )

        assertEquals(4, capacity.targetCount)
        assertEquals(3_686_400L * 4L + 1L, capacity.availableBytes)
    }

    @Test
    fun `minus one publishes descending decodes ascending and seeks previous sync once`() {
        val video = video(frameCount = 16, syncIndices = setOf(0, 5, 10, 15))
        val result = buildReverseWindowPlan(
            video = video,
            identity = IDENTITY,
            anchorKey = video.frames[11].key,
            signedStride = -1,
            capacity = capacity(4),
        ) as ReverseWindowPlanDecision.Planned

        assertEquals(listOf(10, 9, 8, 7), result.plan.publicationTargets.indices())
        assertEquals(listOf(7, 8, 9, 10), result.plan.decodeTargets.indices())
        assertEquals(5, result.plan.previousSyncSample.sampleOrdinal)
        assertEquals(1, result.plan.accounting.seekCount)
        assertEquals(1, result.plan.accounting.flushCount)
    }

    @Test
    fun `minus five retains only stride targets while decode order stays ascending`() {
        val video = video(frameCount = 25, syncIndices = setOf(0, 5, 10, 15, 20))
        val result = buildReverseWindowPlan(
            video = video,
            identity = IDENTITY,
            anchorKey = video.frames[23].key,
            signedStride = -5,
            capacity = capacity(3),
        ) as ReverseWindowPlanDecision.Planned

        assertEquals(listOf(18, 13, 8), result.plan.publicationTargets.indices())
        assertEquals(listOf(8, 13, 18), result.plan.decodeTargets.indices())
        assertEquals(5, result.plan.previousSyncSample.sampleOrdinal)
        assertEquals(3, result.plan.publicationTargets.size)
    }

    @Test
    fun `unsupported stride capacity anchor and first frame fail closed`() {
        val video = video(frameCount = 3, syncIndices = setOf(0))

        assertFallback(video, video.frames[2].key, -2, capacity(2), ReverseWindowFallbackReason.UNSUPPORTED_STRIDE)
        assertFallback(video, video.frames[2].key, -1, capacity(0), ReverseWindowFallbackReason.CAPACITY_UNAVAILABLE)
        assertFallback(
            video,
            video.frames[2].key.copy(duplicateOrdinal = 1),
            -1,
            capacity(2),
            ReverseWindowFallbackReason.ANCHOR_KEY_MISMATCH,
        )
        assertFallback(video, video.frames[0].key, -1, capacity(2), ReverseWindowFallbackReason.NO_OLDER_TARGET)
    }

    @Test
    fun `duplicate PTS targets keep their exact duplicate ordinals`() {
        val samples = listOf(
            IndexedSample(0, 0, true),
            IndexedSample(1, 1_000, false),
            IndexedSample(2, 1_000, false),
            IndexedSample(3, 1_000, false),
            IndexedSample(4, 2_000, false),
        )
        val video = buildFrameIndex(1, samples)
        val result = buildReverseWindowPlan(
            video,
            IDENTITY,
            video.frames[4].key,
            -1,
            capacity(3),
        ) as ReverseWindowPlanDecision.Planned

        assertEquals(listOf(2, 1, 0), result.plan.publicationTargets.map { it.key.duplicateOrdinal })
        assertEquals(listOf(0, 1, 2), result.plan.decodeTargets.map { it.key.duplicateOrdinal })
        assertEquals(listOf(1_000L, 1_000L, 1_000L), result.plan.decodeTargets.map { it.key.ptsUs })
    }

    private fun assertFallback(
        video: IndexedVideo,
        anchor: FrameKey,
        stride: Int,
        capacity: ReverseWindowCapacity,
        reason: ReverseWindowFallbackReason,
    ) {
        val result = buildReverseWindowPlan(video, IDENTITY, anchor, stride, capacity)
        assertTrue(result is ReverseWindowPlanDecision.Fallback)
        assertEquals(reason, (result as ReverseWindowPlanDecision.Fallback).reason)
    }

    private fun video(frameCount: Int, syncIndices: Set<Int>): IndexedVideo = buildFrameIndex(
        fileGeneration = IDENTITY.fileGeneration,
        samples = List(frameCount) { index ->
            IndexedSample(index, index * 1_000L, index in syncIndices)
        },
    )

    private fun capacity(targetCount: Int): ReverseWindowCapacity = ReverseWindowCapacity.fromBytes(
        availableBytes = targetCount * 100L,
        canonicalFrameBytes = 100L,
    )

    private fun List<IndexedFrame>.indices() = map { it.key.displayFrameIndex }

    private companion object {
        val IDENTITY = ReverseWindowIdentity(7, 11, 13, 17)
    }
}
