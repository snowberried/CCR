package com.snowberried.ctcinereviewer.media

internal data class ReverseWindowIdentity(
    val fileGeneration: Long,
    val codecGeneration: Long,
    val surfaceGeneration: Long,
    val gestureEpoch: Long,
)

internal data class ReverseWindowCapacity private constructor(
    val availableBytes: Long,
    val canonicalFrameBytes: Long,
    val targetCount: Int,
) {
    companion object {
        fun fromBytes(availableBytes: Long, canonicalFrameBytes: Long): ReverseWindowCapacity {
            require(availableBytes >= 0)
            require(canonicalFrameBytes > 0)
            val count = (availableBytes / canonicalFrameBytes)
                .coerceAtMost(Int.MAX_VALUE.toLong())
                .toInt()
            return ReverseWindowCapacity(availableBytes, canonicalFrameBytes, count)
        }
    }
}

internal enum class ReverseWindowFallbackReason {
    UNSUPPORTED_STRIDE,
    CAPACITY_UNAVAILABLE,
    ANCHOR_KEY_MISMATCH,
    NO_OLDER_TARGET,
    WINDOW_ALREADY_READY,
    WINDOW_NOT_READY,
    READY_KEYS_MISMATCH,
    TARGET_NOT_NEXT,
    TARGET_NOT_IN_WINDOW,
    FRAME_KEY_MISMATCH,
    FILE_GENERATION_CHANGED,
    CODEC_GENERATION_CHANGED,
    SURFACE_GENERATION_CHANGED,
    GESTURE_EPOCH_CHANGED,
    WINDOW_BUILD_FAILED,
    CACHE_ADMISSION_FAILED,
    UNSUPPORTED_CODEC_STATE,
    DIRECTION_CHANGED,
    DIRECT_SEEK,
    CANCELLED,
    OUTPUT_FORMAT_CHANGED,
    CODEC_ERROR,
}

internal data class ReverseWindowDecodeAccounting(
    val seekCount: Int = 1,
    val flushCount: Int = 1,
) {
    init {
        require(seekCount == 1)
        require(flushCount == 1)
    }
}

internal data class ReverseWindowPlan(
    val identity: ReverseWindowIdentity,
    val signedStride: Int,
    val anchorKey: FrameKey,
    val capacity: ReverseWindowCapacity,
    val publicationTargets: List<IndexedFrame>,
    val decodeTargets: List<IndexedFrame>,
    val previousSyncSample: IndexedSample,
    val accounting: ReverseWindowDecodeAccounting = ReverseWindowDecodeAccounting(),
) {
    init {
        require(signedStride == -1 || signedStride == -5)
        require(publicationTargets.isNotEmpty())
        require(publicationTargets.size <= capacity.targetCount)
        require(publicationTargets.zipWithNext().all { (newer, older) ->
            newer.key.displayFrameIndex - older.key.displayFrameIndex == -signedStride
        })
        require(decodeTargets == publicationTargets.asReversed())
        require(decodeTargets.zipWithNext().all { (older, newer) ->
            older.key.displayFrameIndex < newer.key.displayFrameIndex
        })
    }
}

internal sealed interface ReverseWindowPlanDecision {
    data class Planned(val plan: ReverseWindowPlan) : ReverseWindowPlanDecision

    data class Fallback(val reason: ReverseWindowFallbackReason) : ReverseWindowPlanDecision
}

internal fun buildReverseWindowPlan(
    video: IndexedVideo,
    identity: ReverseWindowIdentity,
    anchorKey: FrameKey,
    signedStride: Int,
    capacity: ReverseWindowCapacity,
): ReverseWindowPlanDecision {
    if (signedStride != -1 && signedStride != -5) {
        return ReverseWindowPlanDecision.Fallback(ReverseWindowFallbackReason.UNSUPPORTED_STRIDE)
    }
    if (capacity.targetCount == 0) {
        return ReverseWindowPlanDecision.Fallback(ReverseWindowFallbackReason.CAPACITY_UNAVAILABLE)
    }
    val anchor = video.frames.getOrNull(anchorKey.displayFrameIndex)
    if (anchor?.key != anchorKey) {
        return ReverseWindowPlanDecision.Fallback(ReverseWindowFallbackReason.ANCHOR_KEY_MISMATCH)
    }

    val publicationTargets = buildList {
        var targetIndex = anchorKey.displayFrameIndex + signedStride
        while (targetIndex >= 0 && size < capacity.targetCount) {
            add(video.frames[targetIndex])
            targetIndex += signedStride
        }
    }
    if (publicationTargets.isEmpty()) {
        return ReverseWindowPlanDecision.Fallback(ReverseWindowFallbackReason.NO_OLDER_TARGET)
    }

    val decodeTargets = publicationTargets.asReversed()
    return ReverseWindowPlanDecision.Planned(
        ReverseWindowPlan(
            identity = identity,
            signedStride = signedStride,
            anchorKey = anchor.key,
            capacity = capacity,
            publicationTargets = publicationTargets,
            decodeTargets = decodeTargets,
            previousSyncSample = video.previousSyncSample(decodeTargets.first()),
        ),
    )
}
