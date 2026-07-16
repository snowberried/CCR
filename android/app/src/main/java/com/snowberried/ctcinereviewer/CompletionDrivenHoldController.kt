package com.snowberried.ctcinereviewer

import com.snowberried.ctcinereviewer.media.boundedFrameIndex

internal enum class NavigationMode {
    DISCRETE_TAP,
    TIMELINE_SEEK,
    HOLD_TRAVERSAL,
}

internal data class HoldTraversalTarget(
    val gestureGeneration: Long,
    val fileGeneration: Long,
    val stride: Int,
    val frameIndex: Int,
)

/** Keeps held navigation at one accepted-or-being-accepted target until publication completes. */
internal class CompletionDrivenHoldController {
    private data class Active(
        val gestureGeneration: Long,
        val fileGeneration: Long,
        val stride: Int,
    )

    private data class Outstanding(
        val target: HoldTraversalTarget,
        var requestGeneration: Long? = null,
    )

    private var active: Active? = null
    private var outstanding: Outstanding? = null

    val outstandingTargetCount: Int get() = if (outstanding == null) 0 else 1

    fun begin(gestureGeneration: Long, fileGeneration: Long, stride: Int) {
        require(stride in VALID_STRIDES)
        active = Active(gestureGeneration, fileGeneration, stride)
        if (outstanding?.requestGeneration == null) outstanding = null
    }

    fun reserveNext(
        displayedFrameIndex: Int?,
        frameCount: Int,
        foregroundRequestInFlight: Boolean,
    ): HoldTraversalTarget? {
        val current = active ?: return null
        val displayed = displayedFrameIndex ?: return null
        if (foregroundRequestInFlight || outstanding != null || frameCount <= 0) return null
        val targetIndex = boundedFrameIndex(displayed, current.stride, frameCount)
        if (targetIndex == displayed) {
            active = null
            return null
        }
        return HoldTraversalTarget(
            gestureGeneration = current.gestureGeneration,
            fileGeneration = current.fileGeneration,
            stride = current.stride,
            frameIndex = targetIndex,
        ).also { outstanding = Outstanding(it) }
    }

    fun canSubmit(target: HoldTraversalTarget): Boolean {
        val current = active
        val reserved = outstanding
        return current?.gestureGeneration == target.gestureGeneration &&
            current.fileGeneration == target.fileGeneration &&
            reserved?.target == target &&
            reserved.requestGeneration == null
    }

    fun markAccepted(target: HoldTraversalTarget, requestGeneration: Long): Boolean {
        val reserved = outstanding ?: return false
        if (reserved.target != target || reserved.requestGeneration != null) return false
        reserved.requestGeneration = requestGeneration
        return true
    }

    fun complete(
        fileGeneration: Long,
        requestGeneration: Long,
        published: Boolean,
    ) {
        val completed = outstanding?.takeIf {
            it.target.fileGeneration == fileGeneration && it.requestGeneration == requestGeneration
        } ?: return
        outstanding = null
        if (!published && active?.gestureGeneration == completed.target.gestureGeneration) active = null
    }

    fun abortActive() {
        active = null
        if (outstanding?.requestGeneration == null) outstanding = null
    }

    fun end(gestureGeneration: Long) {
        if (active?.gestureGeneration == gestureGeneration) active = null
        if (
            outstanding?.target?.gestureGeneration == gestureGeneration &&
            outstanding?.requestGeneration == null
        ) {
            outstanding = null
        }
    }

    fun invalidate() {
        active = null
        outstanding = null
    }

    private companion object {
        val VALID_STRIDES = setOf(-5, -1, 1, 5)
    }
}
