package com.snowberried.ctcinereviewer.media

internal const val DIRECTIONAL_PREFETCH_FRAME_LIMIT = 12
internal const val PREFETCH_SAFETY_FRAME_COUNT = 2
internal const val PREFETCH_RESERVED_FRAME_COUNT = 2 + PREFETCH_SAFETY_FRAME_COUNT

internal enum class DirectionalPrefetchDirection { FORWARD, REVERSE }

internal data class DirectionalPrefetchPlan(
    val direction: DirectionalPrefetchDirection,
    val frameIndexes: IntRange,
)

internal data class PrefetchBudgetDecision(
    val canonicalFrameBytes: Long,
    val cacheBudgetBytes: Long,
    val availablePrefetchBytes: Long,
    val effectivePrefetchLimit: Int,
)

internal data class PrefetchCancellation(
    val cancelled: Int,
    val wasted: Int,
)

internal class PrefetchRunState(
    val token: GenerationToken,
    val direction: DirectionalPrefetchDirection,
    val targetFrameIndex: Int,
    candidates: List<Int>,
) {
    private val initialCandidates = candidates.toSet()
    private val remaining = initialCandidates.toMutableSet()
    private val started = mutableSetOf<Int>()
    private var completedCount = 0

    val isComplete: Boolean get() = remaining.isEmpty()
    val furthestFrameIndex: Int? get() = when (direction) {
        DirectionalPrefetchDirection.FORWARD -> initialCandidates.maxOrNull()
        DirectionalPrefetchDirection.REVERSE -> initialCandidates.minOrNull()
    }

    fun contains(frameIndex: Int): Boolean = frameIndex in remaining

    fun isCurrent(currentToken: GenerationToken): Boolean = token == currentToken

    fun markStarted(frameIndex: Int): Boolean =
        frameIndex in remaining && started.add(frameIndex)

    fun markCompleted(frameIndex: Int): Boolean {
        started.remove(frameIndex)
        return remaining.remove(frameIndex).also { removed -> if (removed) completedCount += 1 }
    }

    fun cancel(): PrefetchCancellation {
        val result = PrefetchCancellation(cancelled = remaining.size, wasted = started.size)
        remaining.clear()
        started.clear()
        return result
    }

    fun limitTo(frameLimit: Int): PrefetchCancellation {
        require(frameLimit >= 0)
        val keep = remaining
            .sortedBy { kotlin.math.abs(it.toLong() - targetFrameIndex.toLong()) }
            .take((frameLimit - completedCount).coerceAtLeast(0))
            .toSet()
        val dropped = remaining.filter { it !in keep && it !in started }
        remaining.removeAll(dropped.toSet())
        return PrefetchCancellation(cancelled = dropped.size, wasted = 0)
    }
}

internal fun canonicalFrameBytes(width: Int, height: Int): Long {
    if (width <= 0 || height <= 0) return 0
    return try {
        Math.multiplyExact(Math.multiplyExact(width.toLong(), height.toLong()), 4L)
    } catch (_: ArithmeticException) {
        0
    }
}

internal fun prefetchBudgetDecision(
    width: Int,
    height: Int,
    cacheBudgetBytes: Long,
    maximumFrameLimit: Int = DIRECTIONAL_PREFETCH_FRAME_LIMIT,
): PrefetchBudgetDecision {
    val frameBytes = canonicalFrameBytes(width, height)
    if (cacheBudgetBytes <= 0 || frameBytes <= 0 || maximumFrameLimit <= 0) {
        return PrefetchBudgetDecision(frameBytes, cacheBudgetBytes.coerceAtLeast(0), 0, 0)
    }
    val reservedBytes = try {
        Math.multiplyExact(frameBytes, PREFETCH_RESERVED_FRAME_COUNT.toLong())
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }
    val available = (cacheBudgetBytes - reservedBytes).coerceAtLeast(0)
    return PrefetchBudgetDecision(
        canonicalFrameBytes = frameBytes,
        cacheBudgetBytes = cacheBudgetBytes,
        availablePrefetchBytes = available,
        effectivePrefetchLimit = minOf(maximumFrameLimit, (available / frameBytes).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()),
    )
}

internal fun directionalPrefetchPlan(
    previousDisplayedFrameIndex: Int?,
    targetFrameIndex: Int,
    frameCount: Int,
    frameLimit: Int = DIRECTIONAL_PREFETCH_FRAME_LIMIT,
): DirectionalPrefetchPlan {
    require(frameCount > 0)
    require(targetFrameIndex in 0 until frameCount)
    require(previousDisplayedFrameIndex == null || previousDisplayedFrameIndex in 0 until frameCount)
    require(frameLimit >= 0)

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
