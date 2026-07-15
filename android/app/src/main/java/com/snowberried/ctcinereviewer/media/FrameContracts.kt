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

    val frameCount: Int get() = frames.size

    fun frameForOutput(ptsUs: Long, duplicateOrdinal: Int): IndexedFrame? =
        frames.firstOrNull { it.key.ptsUs == ptsUs && it.key.duplicateOrdinal == duplicateOrdinal }

    fun previousSyncSample(target: IndexedFrame): IndexedSample =
        samples.asSequence()
            .filter { it.sync && it.sampleOrdinal <= target.sampleOrdinal }
            .maxByOrNull(IndexedSample::sampleOrdinal)
            ?: samples.first()
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

sealed interface FrameResult {
    val request: FrameRequest

    data class Published(
        override val request: FrameRequest,
        val textureTimestampNs: Long,
        val cacheHit: Boolean,
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

data class VideoMetadata(
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

data class DecoderDiagnostics(
    val indexBuildMs: Long = 0,
    val decodeOrdinal: Long = 0,
    val renderedCallbackCount: Long = 0,
    val cacheHitCount: Long = 0,
    val cacheMissCount: Long = 0,
    val cacheBytes: Long = 0,
    val staleDiscardCount: Long = 0,
    val stalePublishCount: Long = 0,
    val decoderRecreateCount: Long = 0,
)

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
