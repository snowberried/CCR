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
    val stagedTargetCount: Int,
    val stagedReadyCount: Int,
    val partialAppendCount: Long,
)

internal data class ReverseWindowPublicationTicket(
    internal val windowId: Long,
    val target: IndexedFrame,
    val identity: ReverseWindowIdentity,
    val signedStride: Int,
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

internal sealed interface ReverseWindowPartialAppendResult {
    data class Accepted(
        val appendedTargets: List<IndexedFrame>,
        val remainingTargetCount: Int,
        val completed: Boolean,
    ) : ReverseWindowPartialAppendResult

    data class Fallback(val reason: ReverseWindowFallbackReason) : ReverseWindowPartialAppendResult
}

/**
 * A one-slot, key-only READY window. Texture ownership stays with the renderer cache.
 * Full refills remain compatible while staged refills expose only an exact contiguous prefix.
 */
internal class ReverseWindowEngine {
    private data class StagedAppend(
        val plan: ReverseWindowPlan,
        val readyKeys: MutableSet<FrameKey> = mutableSetOf(),
        var committedCount: Int = 0,
    )

    private data class ReadyWindow(
        val id: Long,
        val plan: ReverseWindowPlan,
        val remainingTargets: ArrayDeque<IndexedFrame>,
        var tailKey: FrameKey,
        var stagedAppend: StagedAppend? = null,
    )

    private var readyWindow: ReadyWindow? = null
    private var nextWindowId = 0L
    private var initialWindowReadyCount = 0L
    private var rollingAppendRefillCount = 0L
    private var consumedCount = 0L
    private var invalidationCount = 0L
    private var partialAppendCount = 0L
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

        readyWindow = ReadyWindow(
            id = ++nextWindowId,
            plan = plan,
            remainingTargets = ArrayDeque(plan.publicationTargets),
            tailKey = plan.publicationTargets.last().key,
        )
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

        return consumeCurrentNext(window, next)
    }

    /**
     * Captures the exact current-next target without consuming it. A renderer may hold this
     * ticket until a successful swap, then call [consume] to re-check the same window and key.
     */
    @Synchronized
    fun acquirePublicationTicket(
        expectedKey: FrameKey,
        signedStride: Int,
        currentIdentity: ReverseWindowIdentity,
    ): ReverseWindowPublicationTicket? {
        val window = readyWindow ?: return null
        if (identityMismatch(window.plan.identity, currentIdentity) != null) return null
        return acquirePublicationTicket(window, expectedKey, signedStride)
    }

    /** Uses the READY window's own identity so UI callers never read actor-owned codec state. */
    @Synchronized
    fun acquirePublicationTicket(
        expectedKey: FrameKey,
        signedStride: Int,
    ): ReverseWindowPublicationTicket? {
        val window = readyWindow ?: return null
        return acquirePublicationTicket(window, expectedKey, signedStride)
    }

    private fun acquirePublicationTicket(
        window: ReadyWindow,
        expectedKey: FrameKey,
        signedStride: Int,
    ): ReverseWindowPublicationTicket? {
        if (window.plan.signedStride != signedStride) return null
        val next = window.remainingTargets.firstOrNull() ?: return null
        if (next.key != expectedKey) return null
        return ReverseWindowPublicationTicket(
            windowId = window.id,
            target = next,
            identity = window.plan.identity,
            signedStride = signedStride,
        )
    }

    /** Side-effect-free check intended for the renderer's swap-time publication predicate. */
    @Synchronized
    fun isPublicationTicketCurrent(ticket: ReverseWindowPublicationTicket): Boolean {
        val window = readyWindow ?: return false
        return window.id == ticket.windowId &&
            window.plan.identity == ticket.identity &&
            window.plan.signedStride == ticket.signedStride &&
            window.remainingTargets.firstOrNull()?.key == ticket.target.key
    }

    /** Consumes only if the ticket still names the current-next target of the same READY window. */
    @Synchronized
    fun consume(
        ticket: ReverseWindowPublicationTicket,
        currentIdentity: ReverseWindowIdentity,
    ): ReverseWindowConsumeResult {
        val window = readyWindow
            ?: return consumeFallback(ReverseWindowFallbackReason.PUBLICATION_TICKET_STALE, invalidate = false)
        identityMismatch(window.plan.identity, currentIdentity)?.let { reason ->
            return consumeFallback(reason, invalidate = true)
        }
        val next = window.remainingTargets.firstOrNull()
        if (
            window.id != ticket.windowId ||
            window.plan.signedStride != ticket.signedStride ||
            ticket.identity != currentIdentity ||
            next?.key != ticket.target.key
        ) {
            return consumeFallback(ReverseWindowFallbackReason.PUBLICATION_TICKET_STALE, invalidate = false)
        }
        return consumeCurrentNext(window, next)
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
        if (window.stagedAppend != null) {
            return refillFallback(ReverseWindowFallbackReason.REFILL_ALREADY_IN_PROGRESS)
        }
        val expectedKeys = plan.publicationTargets.map { it.key }
        val valid = plan.signedStride == window.plan.signedStride &&
            plan.anchorKey == window.tailKey &&
            readyKeys.size == expectedKeys.size &&
            readyKeys.toSet() == expectedKeys.toSet() &&
            window.remainingTargets.none { it.key in expectedKeys } &&
            window.remainingTargets.size + expectedKeys.size <= window.plan.capacity.targetCount
        if (!valid) return refillFallback(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)

        plan.publicationTargets.forEach(window.remainingTargets::addLast)
        window.tailKey = plan.publicationTargets.last().key
        rollingAppendRefillCount += 1
        lastFallbackReason = null
        return ReverseWindowRefillResult.Ready(plan, expectedKeys.size)
    }

    /**
     * Stages one exact cache-ready target. Only the contiguous publication-order prefix becomes
     * consumable, so an older decoder output can never create a gap in reverse navigation.
     */
    @Synchronized
    fun stageRefillTarget(
        plan: ReverseWindowPlan,
        readyKey: FrameKey,
        currentIdentity: ReverseWindowIdentity,
    ): ReverseWindowPartialAppendResult {
        val window = readyWindow
            ?: return partialFallback(ReverseWindowFallbackReason.WINDOW_NOT_READY)
        identityMismatch(window.plan.identity, currentIdentity)?.let { reason ->
            invalidateInternal(reason)
            return ReverseWindowPartialAppendResult.Fallback(reason)
        }
        identityMismatch(plan.identity, currentIdentity)?.let { reason ->
            return partialFallback(reason)
        }

        var staged = window.stagedAppend
        if (staged == null) {
            val expectedKeys = plan.publicationTargets.map { it.key }
            val valid = plan.signedStride == window.plan.signedStride &&
                plan.anchorKey == window.tailKey &&
                expectedKeys.toSet().size == expectedKeys.size &&
                window.remainingTargets.none { it.key in expectedKeys } &&
                window.remainingTargets.size + expectedKeys.size <= window.plan.capacity.targetCount
            if (!valid) return partialFallback(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)
            staged = StagedAppend(plan)
            window.stagedAppend = staged
        } else if (staged.plan != plan) {
            return partialFallback(ReverseWindowFallbackReason.REFILL_ALREADY_IN_PROGRESS)
        }

        val targetIndex = staged.plan.publicationTargets.indexOfFirst { it.key == readyKey }
        if (
            targetIndex !in staged.committedCount until staged.plan.publicationTargets.size ||
            !staged.readyKeys.add(readyKey)
        ) {
            return partialFallback(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)
        }

        val appended = mutableListOf<IndexedFrame>()
        while (staged.committedCount < staged.plan.publicationTargets.size) {
            val next = staged.plan.publicationTargets[staged.committedCount]
            if (!staged.readyKeys.remove(next.key)) break
            if (window.remainingTargets.size >= window.plan.capacity.targetCount) {
                return partialFallback(ReverseWindowFallbackReason.CAPACITY_UNAVAILABLE)
            }
            window.remainingTargets.addLast(next)
            window.tailKey = next.key
            staged.committedCount += 1
            appended += next
        }
        if (appended.isNotEmpty()) partialAppendCount += 1
        val completed = staged.committedCount == staged.plan.publicationTargets.size
        if (completed) {
            window.stagedAppend = null
            rollingAppendRefillCount += 1
        }
        lastFallbackReason = null
        return ReverseWindowPartialAppendResult.Accepted(
            appendedTargets = appended,
            remainingTargetCount = window.remainingTargets.size,
            completed = completed,
        )
    }

    /** Returns only uncommitted cache keys; the existing READY deque remains intact. */
    @Synchronized
    fun discardStagedRefill(reason: ReverseWindowFallbackReason): Set<FrameKey> {
        val staged = readyWindow?.stagedAppend ?: return emptySet()
        readyWindow?.stagedAppend = null
        lastFallbackReason = reason
        return staged.readyKeys.toSet()
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
            oldestTarget = window?.remainingTargets?.lastOrNull()?.key ?: window?.tailKey,
            signedStride = window?.plan?.signedStride,
            targetCapacity = window?.plan?.capacity?.targetCount ?: 0,
            refillNeeded = window != null && remainingCount == 0,
            refillCount = initialWindowReadyCount + rollingAppendRefillCount,
            initialWindowReadyCount = initialWindowReadyCount,
            rollingAppendRefillCount = rollingAppendRefillCount,
            consumedCount = consumedCount,
            invalidationCount = invalidationCount,
            lastFallbackReason = lastFallbackReason,
            stagedTargetCount = window?.stagedAppend?.plan?.publicationTargets?.size ?: 0,
            stagedReadyCount = window?.stagedAppend?.readyKeys?.size ?: 0,
            partialAppendCount = partialAppendCount,
        )
    }

    @Synchronized
    fun isReadyNextTarget(key: FrameKey, signedStride: Int): Boolean {
        val window = readyWindow ?: return false
        return window.plan.signedStride == signedStride && window.remainingTargets.firstOrNull()?.key == key
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

    private fun consumeCurrentNext(
        window: ReadyWindow,
        next: IndexedFrame,
    ): ReverseWindowConsumeResult.Hit {
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

    private fun partialFallback(reason: ReverseWindowFallbackReason): ReverseWindowPartialAppendResult.Fallback {
        lastFallbackReason = reason
        return ReverseWindowPartialAppendResult.Fallback(reason)
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
