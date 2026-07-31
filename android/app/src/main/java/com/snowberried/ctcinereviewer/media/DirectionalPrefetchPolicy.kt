package com.snowberried.ctcinereviewer.media

import java.util.concurrent.atomic.AtomicLong

internal const val DIRECTIONAL_PREFETCH_FRAME_LIMIT = 12
internal const val DISCRETE_PREFETCH_MAX_DEPTH = 2
internal const val PREFETCH_SAFETY_FRAME_COUNT = 2
internal const val PREFETCH_RESERVED_FRAME_COUNT = 2 + PREFETCH_SAFETY_FRAME_COUNT
internal const val DIRECTIONAL_PREFETCH_IDLE_TIMEOUT_MS = 500L
internal const val RENDERER_CACHE_HARD_CAP_BYTES = 64L * 1024L * 1024L

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

internal data class PrefetchEfficiencySample(
    val completed: Long,
    val evictedBeforeUse: Long,
    val usefulHits: Long,
)

/**
 * Keeps the tiny discrete-navigation prefetch window from repeatedly filling and evicting itself.
 * Values are cumulative so callers do not need another hot-path allocation or event stream.
 */
internal class AdaptivePrefetchDepth(
    private val maximumDepth: Int = DISCRETE_PREFETCH_MAX_DEPTH,
) {
    init {
        require(maximumDepth >= 0)
    }

    private var previous = PrefetchEfficiencySample(0, 0, 0)
    private var usefulWindows = 0

    var currentDepth: Int = maximumDepth
        private set

    fun observe(sample: PrefetchEfficiencySample): Int {
        val completed = (sample.completed - previous.completed).coerceAtLeast(0)
        val evicted = (sample.evictedBeforeUse - previous.evictedBeforeUse).coerceAtLeast(0)
        val hits = (sample.usefulHits - previous.usefulHits).coerceAtLeast(0)
        previous = sample
        if (completed == 0L && evicted == 0L && hits == 0L) return currentDepth

        val evictionRatio = if (completed == 0L) {
            if (evicted == 0L) 0.0 else Double.POSITIVE_INFINITY
        } else {
            evicted.toDouble() / completed.toDouble()
        }
        when {
            evictionRatio > 0.50 -> {
                currentDepth = 0
                usefulWindows = 0
            }
            evictionRatio > 0.20 -> {
                currentDepth = (currentDepth / 2).coerceAtLeast(1).coerceAtMost(maximumDepth)
                usefulWindows = 0
            }
            hits > 0 && evicted == 0L -> {
                usefulWindows += 1
                if (usefulWindows >= 2) {
                    currentDepth = (currentDepth + 1).coerceAtMost(maximumDepth)
                    usefulWindows = 0
                }
            }
            else -> usefulWindows = 0
        }
        return currentDepth
    }

    fun reset() {
        previous = PrefetchEfficiencySample(0, 0, 0)
        usefulWindows = 0
        currentDepth = maximumDepth
    }
}

internal fun effectiveDiscretePrefetchLimit(rendererLimit: Int, adaptiveDepth: Int): Int = minOf(
    rendererLimit,
    DISCRETE_PREFETCH_MAX_DEPTH,
    adaptiveDepth,
).coerceAtLeast(0)

internal data class PrefetchPermit(
    val epoch: Long,
    val absoluteDeadlineElapsedRealtimeMs: Long,
    val direction: DirectionalPrefetchDirection,
)

internal class DirectionalPrefetchGate(
    private val elapsedRealtimeMs: () -> Long,
) {
    private val lock = Any()
    private val epoch = AtomicLong(0)
    @Volatile private var activeDirection: DirectionalPrefetchDirection? = null

    fun newPermit(
        absoluteDeadlineElapsedRealtimeMs: Long,
        direction: DirectionalPrefetchDirection,
    ): PrefetchPermit = synchronized(lock) {
        if (activeDirection != null && activeDirection != direction) epoch.incrementAndGet()
        activeDirection = direction
        PrefetchPermit(
            epoch = epoch.get(),
            absoluteDeadlineElapsedRealtimeMs = absoluteDeadlineElapsedRealtimeMs,
            direction = direction,
        )
    }

    fun suspend(): Long = synchronized(lock) {
        activeDirection = null
        epoch.incrementAndGet()
    }

    fun isActive(permit: PrefetchPermit): Boolean =
        permit.epoch == epoch.get() &&
            permit.direction == activeDirection &&
            elapsedRealtimeMs() < permit.absoluteDeadlineElapsedRealtimeMs
}

internal fun rendererCacheByteBudget(maxHeapBytes: Long): Long =
    minOf(RENDERER_CACHE_HARD_CAP_BYTES, maxHeapBytes.coerceAtLeast(0) / 4L)

internal fun directionalPrefetchDeadline(
    directionalInputElapsedRealtimeMs: Long,
    timeoutMs: Long = DIRECTIONAL_PREFETCH_IDLE_TIMEOUT_MS,
): Long {
    require(timeoutMs >= 0)
    return try {
        Math.addExact(directionalInputElapsedRealtimeMs, timeoutMs)
    } catch (_: ArithmeticException) {
        Long.MAX_VALUE
    }
}

internal class PrefetchRunState(
    val token: GenerationToken,
    val permit: PrefetchPermit,
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
    direction: DirectionalPrefetchDirection,
    targetFrameIndex: Int,
    frameCount: Int,
    frameLimit: Int = DIRECTIONAL_PREFETCH_FRAME_LIMIT,
): DirectionalPrefetchPlan {
    require(frameCount > 0)
    require(targetFrameIndex in 0 until frameCount)
    require(frameLimit >= 0)

    return if (direction == DirectionalPrefetchDirection.REVERSE) {
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
