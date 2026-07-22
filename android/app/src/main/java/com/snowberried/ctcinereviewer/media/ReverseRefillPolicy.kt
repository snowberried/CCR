package com.snowberried.ctcinereviewer.media

internal data class ReverseRefillLowWaterDecision(
    val enabled: Boolean,
    val remainingTargetMark: Int,
    val latencyTargetCount: Int,
) {
    fun shouldStart(remainingTargetCount: Int): Boolean =
        enabled && remainingTargetCount in 0..remainingTargetMark
}

/** Pure byte-capacity/cadence policy; no codec or clock ownership lives here. */
internal fun reverseRefillLowWaterDecision(
    targetCapacity: Int,
    measuredRefillLatencyUs: Long? = null,
    cadenceUs: Long,
): ReverseRefillLowWaterDecision {
    require(targetCapacity >= 0)
    require(measuredRefillLatencyUs == null || measuredRefillLatencyUs >= 0)
    require(cadenceUs > 0)
    if (targetCapacity <= 1) {
        return ReverseRefillLowWaterDecision(
            enabled = false,
            remainingTargetMark = 0,
            latencyTargetCount = 0,
        )
    }

    val baseline = when (targetCapacity) {
        2 -> 1
        in 3..5 -> targetCapacity - 1
        else -> 4
    }
    val latencyTargets = measuredRefillLatencyUs?.let { latencyUs ->
        (latencyUs / cadenceUs + if (latencyUs % cadenceUs == 0L) 0 else 1)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
    } ?: 0
    return ReverseRefillLowWaterDecision(
        enabled = true,
        remainingTargetMark = maxOf(baseline, latencyTargets).coerceAtMost(targetCapacity - 1),
        latencyTargetCount = latencyTargets,
    )
}

internal enum class ReverseRefillGenerationPhase {
    ACTIVE,
    COMPLETED,
    CANCELLED,
}

internal class ReverseRefillDepletionLatch(initialRemainingTargetCount: Int) {
    var depletedDuringBuild: Boolean = initialRemainingTargetCount == 0
        private set

    init {
        require(initialRemainingTargetCount >= 0)
    }

    fun observeRemainingTargetCount(remainingTargetCount: Int) {
        require(remainingTargetCount >= 0)
        if (remainingTargetCount == 0) depletedDuringBuild = true
    }
}

internal data class ReverseRefillGenerationSnapshot(
    val generationId: Long,
    val phase: ReverseRefillGenerationPhase,
    val seekCount: Int,
    val flushCount: Int,
    val resumedSliceCount: Long,
    val cachedTargetCount: Int,
    val consumedDuringBuildCount: Int,
    val cancelledReason: ReverseWindowFallbackReason?,
)

/** Accounting guard that makes the one-seek/one-flush refill-generation contract executable. */
internal class ReverseRefillGenerationState(val generationId: Long) {
    private var phase = ReverseRefillGenerationPhase.ACTIVE
    private var seekCount = 0
    private var flushCount = 0
    private var resumedSliceCount = 0L
    private var cachedTargetCount = 0
    private var consumedDuringBuildCount = 0
    private var cancelledReason: ReverseWindowFallbackReason? = null

    init {
        require(generationId > 0)
    }

    fun recordSeek() {
        requireActive()
        check(seekCount == 0) { "reverse refill generation may seek at most once" }
        seekCount = 1
    }

    fun recordFlush() {
        requireActive()
        check(flushCount == 0) { "reverse refill generation may flush at most once" }
        flushCount = 1
    }

    fun recordResumedSlice() {
        requireActive()
        resumedSliceCount += 1
    }

    fun recordCachedTarget() {
        requireActive()
        cachedTargetCount += 1
    }

    fun recordConsumedDuringBuild() {
        requireActive()
        consumedDuringBuildCount += 1
    }

    fun complete(): Boolean {
        if (phase != ReverseRefillGenerationPhase.ACTIVE) return false
        phase = ReverseRefillGenerationPhase.COMPLETED
        return true
    }

    fun cancel(reason: ReverseWindowFallbackReason): Boolean {
        if (phase != ReverseRefillGenerationPhase.ACTIVE) return false
        phase = ReverseRefillGenerationPhase.CANCELLED
        cancelledReason = reason
        return true
    }

    fun snapshot(): ReverseRefillGenerationSnapshot = ReverseRefillGenerationSnapshot(
        generationId = generationId,
        phase = phase,
        seekCount = seekCount,
        flushCount = flushCount,
        resumedSliceCount = resumedSliceCount,
        cachedTargetCount = cachedTargetCount,
        consumedDuringBuildCount = consumedDuringBuildCount,
        cancelledReason = cancelledReason,
    )

    private fun requireActive() {
        check(phase == ReverseRefillGenerationPhase.ACTIVE) { "reverse refill generation is $phase" }
    }
}
