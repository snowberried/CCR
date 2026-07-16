package com.snowberried.ctcinereviewer

import com.snowberried.ctcinereviewer.render.CanonicalGeometry
import kotlin.math.ceil

internal data class DiagnosticBuildInfo(
    val versionName: String,
    val versionCode: Int,
    val commitSha: String,
    val deviceModel: String,
    val sdk: Int,
)

internal fun buildSanitizedDiagnostics(
    state: ViewerUiState,
    build: DiagnosticBuildInfo,
): String {
    val metadata = state.metadata
    val output = state.diagnostics.decodedOutputFormatHistory.lastOrNull()
        ?: state.diagnostics.configuredOutputMetadata
    val geometry = metadata?.let {
        runCatching {
            CanonicalGeometry.fromInclusiveCrop(
                cropLeft = output?.cropLeft ?: it.cropLeft,
                cropTop = output?.cropTop ?: it.cropTop,
                cropRight = output?.cropRight ?: it.cropRight,
                cropBottom = output?.cropBottom ?: it.cropBottom,
                pixelAspectRatioWidth = it.pixelAspectRatioWidth,
                pixelAspectRatioHeight = it.pixelAspectRatioHeight,
                rotationDegrees = it.rotationDegrees,
            )
        }.getOrNull()
    }
    val latency = state.recentRequestToPublishLatencyMs.sorted()
    val diagnostics = state.diagnostics
    return buildString {
        appendLine("CCR_SANITIZED_DIAGNOSTICS_V1")
        appendLine("app.version=${build.versionName}")
        appendLine("app.versionCode=${build.versionCode}")
        appendLine("app.commit=${safeToken(build.commitSha)}")
        appendLine("device.model=${safeToken(build.deviceModel)}")
        appendLine("device.sdk=${build.sdk}")
        appendLine("codec.component=${safeToken(metadata?.codecComponent)}")
        appendLine("video.coded=${metadata?.let { "${it.codedWidth}x${it.codedHeight}" } ?: "-"}")
        appendLine("video.canonical=${geometry?.let { "${it.width}x${it.height}" } ?: "-"}")
        appendLine("video.rotation=${metadata?.rotationDegrees ?: "-"}")
        appendLine("frame.requested=${state.requestedFrameIndex}")
        appendLine("frame.displayed=${state.displayedFrameIndex ?: "-"}")
        appendLine("frame.decodeTarget=${state.currentDecodeTarget ?: "-"}")
        appendLine("frame.latestPending=${state.latestPendingRequest ?: "-"}")
        appendLine("frame.foregroundDecoded=${diagnostics.foregroundDecodedFrameCount}")
        appendLine("request.coalesced=${diagnostics.requestCoalescedCount}")
        appendLine("cache.hit=${diagnostics.cacheHitCount}")
        appendLine("cache.miss=${diagnostics.cacheMissCount}")
        appendLine("cache.bytes=${diagnostics.cacheBytes}")
        appendLine("cache.budgetBytes=${diagnostics.cacheBudgetBytes}")
        appendLine("prefetch.requested=${diagnostics.prefetchRequested}")
        appendLine("prefetch.started=${diagnostics.prefetchStarted}")
        appendLine("prefetch.completed=${diagnostics.prefetchCompleted}")
        appendLine("prefetch.cacheHit=${diagnostics.prefetchCacheHit}")
        appendLine("prefetch.cancelled=${diagnostics.prefetchCancelled}")
        appendLine("prefetch.evictedBeforeUse=${diagnostics.prefetchEvictedBeforeUse}")
        appendLine("prefetch.wasted=${diagnostics.prefetchWasted}")
        appendLine("prefetch.depth=${diagnostics.currentPrefetchDepth}")
        appendLine("prefetch.effectiveLimit=${diagnostics.effectivePrefetchLimit}")
        appendLine("prefetch.canonicalFrameBytes=${diagnostics.canonicalFrameBytes}")
        appendLine("latency.requestToPublish.count=${latency.size}")
        appendLine("latency.requestToPublish.p50Ms=${latency.percentile(0.50)}")
        appendLine("latency.requestToPublish.p95Ms=${latency.percentile(0.95)}")
        appendLine("latency.requestToPublish.maxMs=${latency.maxOrNull()?.formatMs() ?: "-"}")
        appendLine("publication.last=${safeToken(state.lastPublicationResult)}")
        appendLine("generation.file=${state.activeFileGeneration ?: "-"}")
        appendLine("generation.request=${state.activeRequestGeneration ?: "-"}")
        appendLine("generation.surface=${state.surfaceGeneration}")
        appendLine("output.formatChanges=${diagnostics.outputFormatChangeCount}")
        appendLine("error.last=${safeToken(sanitizedErrorCode(state.lastErrorCode))}")
    }
}

internal fun sanitizedErrorCode(value: String?): String? = value
    ?.takeIf { it.matches(Regex("[A-Z0-9_]{1,64}")) }
    ?: value?.let { "UNCLASSIFIED_ERROR" }

private fun safeToken(value: String?): String = value
    ?.take(96)
    ?.replace(Regex("[^A-Za-z0-9._:+-]"), "_")
    ?.takeIf(String::isNotBlank)
    ?: "-"

private fun List<Double>.percentile(fraction: Double): String {
    if (isEmpty()) return "-"
    val index = (ceil(size * fraction).toInt() - 1).coerceIn(0, lastIndex)
    return this[index].formatMs()
}

private fun Double.formatMs(): String = "%.3f".format(java.util.Locale.ROOT, this)
