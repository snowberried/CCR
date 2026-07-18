package com.snowberried.ctcinereviewer.media

internal enum class RandomSeekPlanKind {
    NO_OP,
    CACHE,
    HISTORY,
    REVERSE_WINDOW,
    SEQUENTIAL_AHEAD,
    SAME_GOP_CURSOR,
    PREVIOUS_SYNC,
}

internal enum class RandomSeekCacheExpectation {
    CURRENT_FRAME,
    TEXTURE_CACHE_HIT,
    BACKWARD_HISTORY_HIT,
    REVERSE_WINDOW_HIT,
    CACHE_MISS,
}

internal data class RandomSeekDecoderCursor(
    val fileGeneration: Long,
    val codecGeneration: Long,
    val frame: IndexedFrame,
    val duplicateCounts: Map<Long, Int> = emptyMap(),
    val inputEos: Boolean = false,
    val continuationAvailable: Boolean = true,
)

internal data class RandomSeekInput(
    val video: IndexedVideo,
    val generation: GenerationToken,
    val codecGeneration: Long,
    val displayedKey: FrameKey?,
    val targetKey: FrameKey,
    val decoderCursor: RandomSeekDecoderCursor? = null,
    val textureCacheKeys: Set<FrameKey> = emptySet(),
    val backwardHistoryKeys: Set<FrameKey> = emptySet(),
    val reverseWindowKeys: Set<FrameKey> = emptySet(),
)

internal data class RandomSeekPlan(
    val kind: RandomSeekPlanKind,
    val sourceDecoderCursor: RandomSeekDecoderCursor?,
    val targetKey: FrameKey,
    val previousSync: IndexedSample,
    val estimatedDecodeOutputCount: Int,
    val actualDecodeOutputCount: Int?,
    val flushRequired: Boolean,
    val expectedCacheResult: RandomSeekCacheExpectation,
    val generation: GenerationToken,
) {
    fun withActualDecodeOutputCount(count: Int): RandomSeekPlan {
        require(count >= 0)
        return copy(actualDecodeOutputCount = count)
    }
}

/**
 * Platform-free exact-seek decision policy. It plans only; extractor, codec and texture ownership
 * stay with their existing actors.
 */
internal class RandomSeekPlanner(
    private val lowCostSequentialOutputLimit: Int = 5,
    private val flushCostOutputEquivalent: Int = 1,
) {
    init {
        require(lowCostSequentialOutputLimit >= 0)
        require(flushCostOutputEquivalent >= 0)
    }

    fun plan(input: RandomSeekInput): RandomSeekPlan {
        require(input.video.fileGeneration == input.generation.fileGeneration)
        val target = input.video.frames.getOrNull(input.targetKey.displayFrameIndex)
        require(target?.key == input.targetKey) {
            "Target FrameKey must exactly match the indexed frame"
        }
        val previousSync = input.video.previousSyncSample(target)

        if (input.displayedKey == input.targetKey) {
            return immediatePlan(
                input = input,
                previousSync = previousSync,
                kind = RandomSeekPlanKind.NO_OP,
                expectation = RandomSeekCacheExpectation.CURRENT_FRAME,
            )
        }
        if (input.targetKey in input.textureCacheKeys) {
            return immediatePlan(
                input = input,
                previousSync = previousSync,
                kind = RandomSeekPlanKind.CACHE,
                expectation = RandomSeekCacheExpectation.TEXTURE_CACHE_HIT,
            )
        }
        if (input.targetKey in input.backwardHistoryKeys) {
            return immediatePlan(
                input = input,
                previousSync = previousSync,
                kind = RandomSeekPlanKind.HISTORY,
                expectation = RandomSeekCacheExpectation.BACKWARD_HISTORY_HIT,
            )
        }
        if (input.targetKey in input.reverseWindowKeys) {
            return immediatePlan(
                input = input,
                previousSync = previousSync,
                kind = RandomSeekPlanKind.REVERSE_WINDOW,
                expectation = RandomSeekCacheExpectation.REVERSE_WINDOW_HIT,
            )
        }

        val previousSyncOutputs = estimatedOutputsFromPreviousSync(input.video, target, previousSync)
        val cursor = validCursor(input)
        if (cursor != null && target.key.displayFrameIndex > cursor.frame.key.displayFrameIndex) {
            val continuationOutputs = target.key.displayFrameIndex - cursor.frame.key.displayFrameIndex
            val previousSyncCost = previousSyncOutputs.toLong() + flushCostOutputEquivalent.toLong()
            val continuationIsCheaper = continuationOutputs.toLong() <= previousSyncCost
            if (continuationIsCheaper && continuationOutputs <= lowCostSequentialOutputLimit) {
                return decodePlan(
                    input = input,
                    previousSync = previousSync,
                    kind = RandomSeekPlanKind.SEQUENTIAL_AHEAD,
                    cursor = cursor,
                    estimatedOutputs = continuationOutputs,
                    flushRequired = false,
                )
            }

            val cursorSync = input.video.previousSyncSample(cursor.frame)
            if (continuationIsCheaper && cursorSync.sampleOrdinal == previousSync.sampleOrdinal) {
                return decodePlan(
                    input = input,
                    previousSync = previousSync,
                    kind = RandomSeekPlanKind.SAME_GOP_CURSOR,
                    cursor = cursor,
                    estimatedOutputs = continuationOutputs,
                    flushRequired = false,
                )
            }
        }

        return decodePlan(
            input = input,
            previousSync = previousSync,
            kind = RandomSeekPlanKind.PREVIOUS_SYNC,
            cursor = null,
            estimatedOutputs = previousSyncOutputs,
            flushRequired = true,
        )
    }

    private fun validCursor(input: RandomSeekInput): RandomSeekDecoderCursor? {
        val cursor = input.decoderCursor ?: return null
        if (
            !cursor.continuationAvailable ||
            cursor.inputEos ||
            cursor.fileGeneration != input.video.fileGeneration ||
            cursor.codecGeneration != input.codecGeneration
        ) return null
        val indexed = input.video.frames.getOrNull(cursor.frame.key.displayFrameIndex)
        return cursor.takeIf { indexed == cursor.frame }
    }

    private fun estimatedOutputsFromPreviousSync(
        video: IndexedVideo,
        target: IndexedFrame,
        previousSync: IndexedSample,
    ): Int {
        val syncDisplayIndex = video.frames.indexOfFirst { it.sampleOrdinal == previousSync.sampleOrdinal }
        if (syncDisplayIndex < 0) return target.key.displayFrameIndex + 1
        return (target.key.displayFrameIndex - syncDisplayIndex + 1).coerceAtLeast(1)
    }

    private fun immediatePlan(
        input: RandomSeekInput,
        previousSync: IndexedSample,
        kind: RandomSeekPlanKind,
        expectation: RandomSeekCacheExpectation,
    ) = RandomSeekPlan(
        kind = kind,
        sourceDecoderCursor = null,
        targetKey = input.targetKey,
        previousSync = previousSync,
        estimatedDecodeOutputCount = 0,
        actualDecodeOutputCount = 0,
        flushRequired = false,
        expectedCacheResult = expectation,
        generation = input.generation,
    )

    private fun decodePlan(
        input: RandomSeekInput,
        previousSync: IndexedSample,
        kind: RandomSeekPlanKind,
        cursor: RandomSeekDecoderCursor?,
        estimatedOutputs: Int,
        flushRequired: Boolean,
    ) = RandomSeekPlan(
        kind = kind,
        sourceDecoderCursor = cursor,
        targetKey = input.targetKey,
        previousSync = previousSync,
        estimatedDecodeOutputCount = estimatedOutputs,
        actualDecodeOutputCount = null,
        flushRequired = flushRequired,
        expectedCacheResult = RandomSeekCacheExpectation.CACHE_MISS,
        generation = input.generation,
    )
}
