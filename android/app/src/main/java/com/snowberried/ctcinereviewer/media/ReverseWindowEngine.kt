package com.snowberried.ctcinereviewer.media

internal enum class ReverseWindowSlotState {
    EMPTY,
    READY,
    EXHAUSTED,
}

internal data class ReverseWindowSnapshot(
    val state: ReverseWindowSlotState,
    val readyWindowCount: Int,
    val remainingTargetCount: Int,
    val remainingTargetKeys: List<FrameKey>,
    val nextTarget: FrameKey?,
    val oldestTarget: FrameKey?,
    val signedStride: Int?,
    val targetCapacity: Int,
    val refillNeeded: Boolean,
    /** Compatibility total: initialWindowReadyCount + rollingAppendRefillCount. */
    val refillCount: Long,
    val initialWindowReadyCount: Long,
    val rollingAppendRefillCount: Long,
    val consumedCount: Long,
    val invalidationCount: Long,
    val lastFallbackReason: ReverseWindowFallbackReason?,
)

internal sealed interface ReverseWindowRefillResult {
    data class Ready(
        val plan: ReverseWindowPlan,
        val targetCount: Int,
    ) : ReverseWindowRefillResult

    data class Fallback(val reason: ReverseWindowFallbackReason) : ReverseWindowRefillResult
}

internal sealed interface ReverseWindowConsumeResult {
    data class Hit(
        val target: IndexedFrame,
        val remainingTargetCount: Int,
        val refillRequired: Boolean,
    ) : ReverseWindowConsumeResult

    data class Fallback(val reason: ReverseWindowFallbackReason) : ReverseWindowConsumeResult
}

/**
 * A one-slot, key-only READY window. Texture ownership stays with the renderer cache.
 * A caller builds every target cache-only, then atomically installs the exact key set.
 */
internal class ReverseWindowEngine {
    private data class ReadyWindow(
        val plan: ReverseWindowPlan,
        val remainingTargets: ArrayDeque<IndexedFrame>,
    )

    private var readyWindow: ReadyWindow? = null
    private var initialWindowReadyCount = 0L
    private var rollingAppendRefillCount = 0L
    private var consumedCount = 0L
    private var invalidationCount = 0L
    private var lastFallbackReason: ReverseWindowFallbackReason? = null

    @Synchronized
    fun refill(
        plan: ReverseWindowPlan,
        readyKeys: Collection<FrameKey>,
        currentIdentity: ReverseWindowIdentity,
    ): ReverseWindowRefillResult {
        identityMismatch(plan.identity, currentIdentity)?.let { reason ->
            invalidateInternal(reason)
            return ReverseWindowRefillResult.Fallback(reason)
        }
        if (readyWindow?.remainingTargets?.isNotEmpty() == true) {
            return refillFallback(ReverseWindowFallbackReason.WINDOW_ALREADY_READY)
        }

        val expectedKeys = plan.publicationTargets.map { it.key }
        if (readyKeys.size != expectedKeys.size || readyKeys.toSet() != expectedKeys.toSet()) {
            return refillFallback(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)
        }

        readyWindow = ReadyWindow(plan, ArrayDeque(plan.publicationTargets))
        initialWindowReadyCount += 1
        lastFallbackReason = null
        return ReverseWindowRefillResult.Ready(plan, expectedKeys.size)
    }

    @Synchronized
    fun consume(
        expectedKey: FrameKey,
        currentIdentity: ReverseWindowIdentity,
    ): ReverseWindowConsumeResult {
        val window = readyWindow
            ?: return consumeFallback(ReverseWindowFallbackReason.WINDOW_NOT_READY, invalidate = false)
        identityMismatch(window.plan.identity, currentIdentity)?.let { reason ->
            return consumeFallback(reason, invalidate = true)
        }

        val next = window.remainingTargets.firstOrNull()
            ?: return consumeFallback(ReverseWindowFallbackReason.WINDOW_NOT_READY, invalidate = false)
        if (expectedKey != next.key) {
            val reason = when {
                expectedKey.displayFrameIndex == next.key.displayFrameIndex ||
                    expectedKey.ptsUs == next.key.ptsUs -> ReverseWindowFallbackReason.FRAME_KEY_MISMATCH
                window.remainingTargets.any { it.key == expectedKey } ->
                    ReverseWindowFallbackReason.TARGET_NOT_NEXT
                else -> ReverseWindowFallbackReason.TARGET_NOT_IN_WINDOW
            }
            return consumeFallback(reason, invalidate = true)
        }

        window.remainingTargets.removeFirst()
        consumedCount += 1
        val remaining = window.remainingTargets.size
        lastFallbackReason = null
        return ReverseWindowConsumeResult.Hit(
            target = next,
            remainingTargetCount = remaining,
            refillRequired = remaining == 0,
        )
    }

    @Synchronized
    fun appendRefill(
        plan: ReverseWindowPlan,
        readyKeys: Collection<FrameKey>,
        currentIdentity: ReverseWindowIdentity,
    ): ReverseWindowRefillResult {
        val window = readyWindow
            ?: return refillFallback(ReverseWindowFallbackReason.WINDOW_NOT_READY)
        identityMismatch(window.plan.identity, currentIdentity)?.let { reason ->
            invalidateInternal(reason)
            return ReverseWindowRefillResult.Fallback(reason)
        }
        identityMismatch(plan.identity, currentIdentity)?.let { reason ->
            return refillFallback(reason)
        }
        val expectedKeys = plan.publicationTargets.map { it.key }
        val appendAnchor = window.remainingTargets.lastOrNull()?.key
            ?: window.plan.publicationTargets.lastOrNull()?.key
        val valid = plan.signedStride == window.plan.signedStride &&
            plan.anchorKey == appendAnchor &&
            readyKeys.size == expectedKeys.size &&
            readyKeys.toSet() == expectedKeys.toSet() &&
            window.remainingTargets.none { it.key in expectedKeys } &&
            window.remainingTargets.size + expectedKeys.size <= window.plan.capacity.targetCount
        if (!valid) return refillFallback(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)

        plan.publicationTargets.forEach(window.remainingTargets::addLast)
        rollingAppendRefillCount += 1
        lastFallbackReason = null
        return ReverseWindowRefillResult.Ready(plan, expectedKeys.size)
    }

    @Synchronized
    fun invalidate(reason: ReverseWindowFallbackReason) {
        invalidateInternal(reason)
    }

    @Synchronized
    fun snapshot(): ReverseWindowSnapshot {
        val window = readyWindow
        val remainingCount = window?.remainingTargets?.size ?: 0
        return ReverseWindowSnapshot(
            state = when {
                window == null -> ReverseWindowSlotState.EMPTY
                remainingCount == 0 -> ReverseWindowSlotState.EXHAUSTED
                else -> ReverseWindowSlotState.READY
            },
            readyWindowCount = if (remainingCount == 0) 0 else 1,
            remainingTargetCount = remainingCount,
            remainingTargetKeys = window?.remainingTargets?.map { it.key }.orEmpty(),
            nextTarget = window?.remainingTargets?.firstOrNull()?.key,
            oldestTarget = window?.remainingTargets?.lastOrNull()?.key
                ?: window?.plan?.publicationTargets?.lastOrNull()?.key,
            signedStride = window?.plan?.signedStride,
            targetCapacity = window?.plan?.capacity?.targetCount ?: 0,
            refillNeeded = window != null && remainingCount == 0,
            refillCount = initialWindowReadyCount + rollingAppendRefillCount,
            initialWindowReadyCount = initialWindowReadyCount,
            rollingAppendRefillCount = rollingAppendRefillCount,
            consumedCount = consumedCount,
            invalidationCount = invalidationCount,
            lastFallbackReason = lastFallbackReason,
        )
    }

    private fun refillFallback(reason: ReverseWindowFallbackReason): ReverseWindowRefillResult.Fallback {
        lastFallbackReason = reason
        return ReverseWindowRefillResult.Fallback(reason)
    }

    private fun consumeFallback(
        reason: ReverseWindowFallbackReason,
        invalidate: Boolean,
    ): ReverseWindowConsumeResult.Fallback {
        if (invalidate) invalidateInternal(reason) else lastFallbackReason = reason
        return ReverseWindowConsumeResult.Fallback(reason)
    }

    private fun invalidateInternal(reason: ReverseWindowFallbackReason) {
        if (readyWindow != null) invalidationCount += 1
        readyWindow = null
        lastFallbackReason = reason
    }

    private fun identityMismatch(
        expected: ReverseWindowIdentity,
        actual: ReverseWindowIdentity,
    ): ReverseWindowFallbackReason? = when {
        expected.fileGeneration != actual.fileGeneration ->
            ReverseWindowFallbackReason.FILE_GENERATION_CHANGED
        expected.codecGeneration != actual.codecGeneration ->
            ReverseWindowFallbackReason.CODEC_GENERATION_CHANGED
        expected.surfaceGeneration != actual.surfaceGeneration ->
            ReverseWindowFallbackReason.SURFACE_GENERATION_CHANGED
        expected.gestureEpoch != actual.gestureEpoch ->
            ReverseWindowFallbackReason.GESTURE_EPOCH_CHANGED
        else -> null
    }
}
