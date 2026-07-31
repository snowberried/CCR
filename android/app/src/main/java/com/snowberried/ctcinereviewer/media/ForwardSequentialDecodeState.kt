package com.snowberried.ctcinereviewer.media

internal enum class ForwardSequentialFallbackReason {
    NONE,
    NOT_REQUESTED,
    UNSUPPORTED_STRIDE,
    NO_PUBLISHED_CURSOR,
    FILE_CHANGED,
    CODEC_CHANGED,
    EOS_REACHED,
    TARGET_NOT_NEXT,
}

internal data class ForwardSequentialDecision(
    val enter: Boolean,
    val fallbackReason: ForwardSequentialFallbackReason,
    val duplicateCounts: Map<Long, Int> = emptyMap(),
    val inputEos: Boolean = false,
)

/**
 * Cursor for a decoder that stopped immediately after publishing an exact foreground target.
 * It never owns MediaCodec resources; synchronized invalidation also permits Surface callbacks
 * to revoke continuity before the actor handles its next request.
 */
internal class ForwardSequentialDecodeState {
    private data class Cursor(
        val fileGeneration: Long,
        val codecGeneration: Long,
        val lastOutputFrameIndex: Int,
        val duplicateCounts: Map<Long, Int>,
        val inputEos: Boolean,
        val outputEos: Boolean,
    )

    private var cursor: Cursor? = null

    @Synchronized
    fun decide(
        fileGeneration: Long,
        codecGeneration: Long,
        targetFrameIndex: Int,
        stride: Int?,
    ): ForwardSequentialDecision {
        if (stride == null) {
            invalidate()
            return ForwardSequentialDecision(false, ForwardSequentialFallbackReason.NOT_REQUESTED)
        }
        if (stride != 1 && stride != 5) {
            invalidate()
            return ForwardSequentialDecision(false, ForwardSequentialFallbackReason.UNSUPPORTED_STRIDE)
        }
        val current = cursor ?: return ForwardSequentialDecision(
            false,
            ForwardSequentialFallbackReason.NO_PUBLISHED_CURSOR,
        )
        val reason = when {
            current.fileGeneration != fileGeneration -> ForwardSequentialFallbackReason.FILE_CHANGED
            current.codecGeneration != codecGeneration -> ForwardSequentialFallbackReason.CODEC_CHANGED
            current.outputEos -> ForwardSequentialFallbackReason.EOS_REACHED
            targetFrameIndex != current.lastOutputFrameIndex + stride ->
                ForwardSequentialFallbackReason.TARGET_NOT_NEXT
            else -> ForwardSequentialFallbackReason.NONE
        }
        if (reason != ForwardSequentialFallbackReason.NONE) {
            invalidate()
            return ForwardSequentialDecision(false, reason)
        }
        return ForwardSequentialDecision(
            enter = true,
            fallbackReason = ForwardSequentialFallbackReason.NONE,
            duplicateCounts = current.duplicateCounts,
            inputEos = current.inputEos,
        )
    }

    @Synchronized
    fun recordPublished(
        fileGeneration: Long,
        codecGeneration: Long,
        outputFrameIndex: Int,
        duplicateCounts: Map<Long, Int>,
        inputEos: Boolean,
        outputEos: Boolean,
    ) {
        cursor = Cursor(
            fileGeneration = fileGeneration,
            codecGeneration = codecGeneration,
            lastOutputFrameIndex = outputFrameIndex,
            duplicateCounts = duplicateCounts.toMap(),
            inputEos = inputEos,
            outputEos = outputEos,
        )
    }

    @Synchronized
    fun randomSeekCursor(
        video: IndexedVideo,
        fileGeneration: Long,
        codecGeneration: Long,
    ): RandomSeekDecoderCursor? {
        val current = cursor ?: return null
        if (
            current.fileGeneration != fileGeneration ||
            current.codecGeneration != codecGeneration ||
            current.outputEos
        ) return null
        val frame = video.frames.getOrNull(current.lastOutputFrameIndex) ?: return null
        return RandomSeekDecoderCursor(
            fileGeneration = current.fileGeneration,
            codecGeneration = current.codecGeneration,
            frame = frame,
            duplicateCounts = current.duplicateCounts,
            inputEos = current.inputEos,
            continuationAvailable = !current.outputEos,
        )
    }

    @Synchronized
    fun invalidate() {
        cursor = null
    }
}
