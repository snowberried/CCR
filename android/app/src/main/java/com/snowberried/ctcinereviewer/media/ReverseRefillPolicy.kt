package com.snowberried.ctcinereviewer.media

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

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
    private val depleted = AtomicBoolean(initialRemainingTargetCount == 0)

    val depletedDuringBuild: Boolean
        get() = depleted.get()

    init {
        require(initialRemainingTargetCount >= 0)
    }

    fun observeRemainingTargetCount(remainingTargetCount: Int) {
        require(remainingTargetCount >= 0)
        if (remainingTargetCount == 0) depleted.set(true)
    }
}

internal data class ReverseRefillDepletionObservation(
    val identity: ReverseWindowIdentity,
    val generationId: Long,
    val latch: ReverseRefillDepletionLatch,
) {
    init {
        require(generationId > 0)
    }
}

/** Orders an EGL/actor consume against exact-once completion of the active refill generation. */
internal class ReverseRefillDepletionTracker {
    private val active = AtomicReference<ReverseRefillDepletionObservation?>()

    fun activate(observation: ReverseRefillDepletionObservation) {
        check(active.compareAndSet(null, observation)) { "reverse refill depletion generation already active" }
    }

    fun consumeAndObserve(
        identity: ReverseWindowIdentity,
        consume: () -> ReverseWindowConsumeResult,
    ): ReverseWindowConsumeResult {
        while (true) {
            val observation = active.get()
            if (observation == null || observation.identity != identity) return consume()
            val result = synchronized(observation) {
                if (active.get() !== observation) {
                    null
                } else {
                    consume().also { consumed ->
                        if (consumed is ReverseWindowConsumeResult.Hit) {
                            observation.latch.observeRemainingTargetCount(consumed.remainingTargetCount)
                        }
                    }
                }
            }
            if (result != null) return result
        }
    }

    fun finish(observation: ReverseRefillDepletionObservation): Boolean = synchronized(observation) {
        active.compareAndSet(observation, null)
        observation.latch.depletedDuringBuild
    }

    fun cancel(observation: ReverseRefillDepletionObservation) {
        synchronized(observation) {
            active.compareAndSet(observation, null)
        }
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
