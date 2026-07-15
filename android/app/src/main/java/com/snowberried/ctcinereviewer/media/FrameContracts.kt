package com.snowberried.ctcinereviewer.media

import java.math.BigInteger

data class FrameKey(
    val displayFrameIndex: Int,
    val ptsUs: Long,
    val duplicateOrdinal: Int,
)

data class IndexedSample(
    val sampleOrdinal: Int,
    val ptsUs: Long,
    val sync: Boolean,
)

data class IndexedFrame(
    val key: FrameKey,
    val sampleOrdinal: Int,
    val sync: Boolean,
)

data class IndexedVideo(
    val fileGeneration: Long,
    val samples: List<IndexedSample>,
    val frames: List<IndexedFrame>,
) {
    init {
        require(frames.indices.all { frames[it].key.displayFrameIndex == it })
    }

    private val framesByOutputKey = frames.associateBy { frame ->
        frame.key.ptsUs to frame.key.duplicateOrdinal
    }
    private val syncSamples = samples.filter(IndexedSample::sync)

    val frameCount: Int get() = frames.size

    fun frameForOutput(ptsUs: Long, duplicateOrdinal: Int): IndexedFrame? =
        framesByOutputKey[ptsUs to duplicateOrdinal]

    fun previousSyncSample(target: IndexedFrame): IndexedSample {
        if (syncSamples.isEmpty()) return samples.first()
        val result = syncSamples.binarySearchBy(target.sampleOrdinal) { it.sampleOrdinal }
        if (result >= 0) return syncSamples[result]
        val insertionIndex = -result - 1
        return if (insertionIndex == 0) samples.first() else syncSamples[insertionIndex - 1]
    }
}

data class GenerationToken(
    val fileGeneration: Long,
    val requestGeneration: Long,
)

data class FrameRequest(
    val token: GenerationToken,
    val requestedFrameIndex: Int,
    val expectedKey: FrameKey,
)

data class RequestAcceptance(
    val request: FrameRequest,
    val eventSequence: Long,
    val elapsedRealtimeNanos: Long,
)

enum class PublicationResult {
    PUBLISHED,
    STALE_BEFORE_SWAP,
    SWAP_FAILED,
    SURFACE_INVALID,
}

data class PublicationEvent(
    val eventSequence: Long,
    val elapsedRealtimeNanos: Long,
    val fileGeneration: Long,
    val requestGeneration: Long,
    val requestedFrameIndex: Int,
    val expectedKey: FrameKey,
    val currentFileGeneration: Long,
    val currentRequestGeneration: Long,
    val textureTimestampNs: Long,
    val swapAttempted: Boolean,
    val eglSwapBuffersResult: Boolean?,
    val result: PublicationResult,
)

data class PublicationStats(
    val publishedSwapCount: Long = 0,
    val staleBeforeSwapCount: Long = 0,
    val swapFailureCount: Long = 0,
    val surfaceInvalidCount: Long = 0,
    val publicationInvariantViolationCount: Long = 0,
)

data class FrameImageProbe(
    val embeddedFrameId: Int?,
    val imageSignature: List<Int>,
)

sealed interface FrameResult {
    val request: FrameRequest

    data class Published(
        override val request: FrameRequest,
        val textureTimestampNs: Long,
        val cacheHit: Boolean,
        val imageProbe: FrameImageProbe?,
    ) : FrameResult

    data class DiscardedStale(
        override val request: FrameRequest,
        val stage: String,
    ) : FrameResult

    data class Unsupported(
        override val request: FrameRequest,
        val reason: String,
    ) : FrameResult

    data class Error(
        override val request: FrameRequest,
        val code: String,
    ) : FrameResult
}

data class ContainerMetadata(
    val fileGeneration: Long,
    val mime: String,
    val profile: Int?,
    val codedWidth: Int,
    val codedHeight: Int,
    val cropLeft: Int,
    val cropTop: Int,
    val cropRight: Int,
    val cropBottom: Int,
    val rotationDegrees: Int,
    val pixelAspectRatioWidth: Int,
    val pixelAspectRatioHeight: Int,
    val durationUs: Long?,
    val frameCount: Int,
    val codecComponent: String,
    val hardwareAccelerated: Boolean,
)

data class DecodedOutputMetadata(
    val width: Int,
    val height: Int,
    val cropLeft: Int,
    val cropTop: Int,
    val cropRight: Int,
    val cropBottom: Int,
    val colorStandard: Int?,
    val colorRange: Int?,
    val colorTransfer: Int?,
    val mime: String?,
    val profile: Int?,
    val colorFormat: Int?,
    val hdrStaticInfoPresent: Boolean,
)

data class DecoderDiagnostics(
    val indexBuildMs: Long = 0,
    val decodeOrdinal: Long = 0,
    val renderedCallbackCount: Long = 0,
    val cacheHitCount: Long = 0,
    val cacheMissCount: Long = 0,
    val prefetchedFrameCount: Long = 0,
    val prefetchRequested: Long = 0,
    val prefetchStarted: Long = 0,
    val prefetchCompleted: Long = 0,
    val prefetchCacheHit: Long = 0,
    val prefetchCancelled: Long = 0,
    val prefetchEvictedBeforeUse: Long = 0,
    val prefetchWasted: Long = 0,
    val currentPrefetchDepth: Int = 0,
    val effectivePrefetchLimit: Int = 0,
    val canonicalFrameBytes: Long = 0,
    val cacheBudgetBytes: Long = 0,
    val cacheBytes: Long = 0,
    val staleDiscardCount: Long = 0,
    val decoderRecreateCount: Long = 0,
    val configuredOutputMetadata: DecodedOutputMetadata? = null,
    val decodedOutputFormatHistory: List<DecodedOutputMetadata> = emptyList(),
    val outputFormatChangeCount: Long = 0,
    val publishedSwapCount: Long = 0,
    val staleBeforeSwapCount: Long = 0,
    val swapFailureCount: Long = 0,
    val surfaceInvalidCount: Long = 0,
    val publicationInvariantViolationCount: Long = 0,
    val fullFrameReadbackCount: Long = 0,
    val publicationEventHistory: List<PublicationEvent> = emptyList(),
)

fun publicationInvariantViolationCount(events: Iterable<PublicationEvent>): Long = events.count { event ->
    event.result == PublicationResult.PUBLISHED && (
        event.fileGeneration != event.currentFileGeneration ||
            event.requestGeneration != event.currentRequestGeneration ||
            !event.swapAttempted ||
            event.eglSwapBuffersResult != true
        )
}.toLong()

fun buildFrameIndex(fileGeneration: Long, samples: List<IndexedSample>): IndexedVideo {
    require(samples.isNotEmpty())
    require(samples.map(IndexedSample::sampleOrdinal).distinct().size == samples.size)
    val duplicateCounts = mutableMapOf<Long, Int>()
    val frames = samples
        .sortedWith(compareBy<IndexedSample> { it.ptsUs }.thenBy { it.sampleOrdinal })
        .mapIndexed { displayFrameIndex, sample ->
            val duplicateOrdinal = duplicateCounts.getOrDefault(sample.ptsUs, 0)
            duplicateCounts[sample.ptsUs] = duplicateOrdinal + 1
            IndexedFrame(
                key = FrameKey(displayFrameIndex, sample.ptsUs, duplicateOrdinal),
                sampleOrdinal = sample.sampleOrdinal,
                sync = sample.sync,
            )
        }
    return IndexedVideo(fileGeneration, samples.sortedBy(IndexedSample::sampleOrdinal), frames)
}

fun rescalePtsToUs(
    rawPts: String,
    timeBaseNumerator: Long,
    timeBaseDenominator: Long,
): Long {
    require(timeBaseDenominator != 0L)
    val value = BigInteger(rawPts)
        .multiply(BigInteger.valueOf(timeBaseNumerator))
        .multiply(BigInteger.valueOf(1_000_000L))
        .divide(BigInteger.valueOf(timeBaseDenominator))
    return value.longValueExact()
}
