package com.snowberried.ctcinereviewer.media

internal const val DIRECTIONAL_PREFETCH_FRAME_LIMIT = 12

internal enum class DirectionalPrefetchDirection { FORWARD, REVERSE }

internal data class DirectionalPrefetchPlan(
    val direction: DirectionalPrefetchDirection,
    val frameIndexes: IntRange,
)

internal fun directionalPrefetchPlan(
    previousDisplayedFrameIndex: Int?,
    targetFrameIndex: Int,
    frameCount: Int,
    frameLimit: Int = DIRECTIONAL_PREFETCH_FRAME_LIMIT,
): DirectionalPrefetchPlan {
    require(frameCount > 0)
    require(targetFrameIndex in 0 until frameCount)
    require(previousDisplayedFrameIndex == null || previousDisplayedFrameIndex in 0 until frameCount)
    require(frameLimit > 0)

    val reverse = previousDisplayedFrameIndex != null && targetFrameIndex < previousDisplayedFrameIndex
    return if (reverse) {
        DirectionalPrefetchPlan(
            direction = DirectionalPrefetchDirection.REVERSE,
            frameIndexes = (targetFrameIndex - frameLimit).coerceAtLeast(0) until targetFrameIndex,
        )
    } else {
        DirectionalPrefetchPlan(
            direction = DirectionalPrefetchDirection.FORWARD,
            frameIndexes = (targetFrameIndex + 1)..(targetFrameIndex + frameLimit).coerceAtMost(frameCount - 1),
        )
    }
}
