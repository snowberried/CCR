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
        appendLine("decode.seek=${diagnostics.seekCount}")
        appendLine("decode.flush=${diagnostics.flushCount}")
        appendLine("decode.sequentialEntry=${diagnostics.sequentialEntryCount}")
        appendLine("decode.sequentialFallback=${diagnostics.sequentialFallbackCount}")
        appendLine("decode.sequentialOutput=${diagnostics.sequentialOutputCount}")
        appendLine("request.coalesced=${diagnostics.requestCoalescedCount}")
        appendLine("request.actorQueueDepth=${diagnostics.actorQueueDepth}")
        appendLine("cache.hit=${diagnostics.cacheHitCount}")
        appendLine("cache.miss=${diagnostics.cacheMissCount}")
        appendLine("cachedNavigation.attempt=${diagnostics.cachedNavigationAttemptCount}")
        appendLine("cachedNavigation.actorBypass=${diagnostics.cachedNavigationActorBypassCount}")
        appendLine("cachedNavigation.missFallback=${diagnostics.cachedNavigationMissFallbackCount}")
        appendLine("cachedNavigation.stale=${diagnostics.cachedNavigationStaleCount}")
        appendLine("cachedNavigation.error=${diagnostics.cachedNavigationErrorCount}")
        appendLine("cachedNavigation.queueWaitMaxUs=${diagnostics.cachedNavigationQueueWaitMaxUs}")
        appendLine("cache.bytes=${diagnostics.cacheBytes}")
        appendLine("cache.peakBytes=${diagnostics.peakCacheBytes}")
        appendLine("cache.budgetBytes=${diagnostics.cacheBudgetBytes}")
        appendLine("cache.protectedTextures=${diagnostics.protectedTextureCount}")
        appendLine("history.capacity=${diagnostics.backwardHistoryCapacity}")
        appendLine("history.depth=${diagnostics.backwardHistoryDepth}")
        appendLine("history.hit=${diagnostics.backwardHistoryHitCount}")
        appendLine("reverseWindow.ready=${diagnostics.reverseWindowReadyCount}")
        appendLine("reverseWindow.remaining=${diagnostics.reverseWindowRemainingTargetCount}")
        appendLine("reverseWindow.staged=${diagnostics.reverseWindowStagedTargetCount}")
        appendLine("reverseWindow.stagedReady=${diagnostics.reverseWindowStagedReadyCount}")
        appendLine("reverseWindow.hit=${diagnostics.reverseWindowHitCount}")
        appendLine("reverseWindow.build=${diagnostics.reverseWindowBuildCount}")
        appendLine("reverseWindow.fallback=${diagnostics.reverseWindowFallbackCount}")
        appendLine("reverseWindow.seek=${diagnostics.reverseWindowSeekCount}")
        appendLine("reverseWindow.cached=${diagnostics.reverseWindowCachedFrameCount}")
        appendLine("reverseWindow.refill=${diagnostics.reverseWindowRefillCount}")
        appendLine("reverseWindow.refillStall=${diagnostics.reverseWindowRefillStallCount}")
        appendLine("reverseWindow.refillStallMaxUs=${diagnostics.reverseWindowRefillStallMaxUs}")
        appendLine("reverseWindow.refillStallOver250Ms=${diagnostics.reverseWindowRefillStallOver250MsCount}")
        appendLine("reverseWindow.consumed=${diagnostics.reverseWindowConsumedCount}")
        appendLine("reverseWindow.invalidated=${diagnostics.reverseWindowInvalidationCount}")
        appendLine("reverseRefill.generation=${diagnostics.reverseRefillGenerationCount}")
        appendLine("reverseRefill.inProgress=${diagnostics.reverseRefillInProgress}")
        appendLine("reverseRefill.initialSeek=${diagnostics.reverseRefillInitialSeekCount}")
        appendLine("reverseRefill.initialFlush=${diagnostics.reverseRefillInitialFlushCount}")
        appendLine("reverseRefill.resumedSlice=${diagnostics.reverseRefillResumedSliceCount}")
        appendLine("reverseRefill.restart=${diagnostics.reverseRefillRestartCount}")
        appendLine("reverseRefill.maxSeekPerGeneration=${diagnostics.reverseRefillMaxSeekPerGeneration}")
        appendLine("reverseRefill.maxFlushPerGeneration=${diagnostics.reverseRefillMaxFlushPerGeneration}")
        appendLine("reverseRefill.cachedTarget=${diagnostics.reverseRefillCachedTargetCount}")
        appendLine("reverseRefill.consumedDuringBuild=${diagnostics.reverseRefillConsumedDuringBuildCount}")
        appendLine("reverseRefill.cancelledReason=${safeToken(diagnostics.reverseRefillLastCancelledReason)}")
        appendLine("reverseRefill.lowWaterTrigger=${diagnostics.reverseLowWaterTriggerCount}")
        appendLine("reverseRefill.startedRemaining=${diagnostics.reverseRefillStartedRemainingTargets}")
        appendLine("reverseRefill.partialAppend=${diagnostics.reversePartialAppendCount}")
        appendLine("reverseRefill.completedBeforeDepletion=${diagnostics.reverseRefillCompletedBeforeDepletionCount}")
        appendLine("reverseRefill.depletionBeforeComplete=${diagnostics.reverseDepletionBeforeRefillCount}")
        appendLine("reverseRefill.associatedGap=${diagnostics.reverseRefillAssociatedGapCount}")
        appendLine("randomSeek.attemptedPlan=${safeToken(diagnostics.lastRandomSeekAttemptedPlanKind)}")
        appendLine("randomSeek.selectedPlan=${safeToken(diagnostics.lastRandomSeekPlanKind)}")
        appendLine("randomSeek.fallback=${safeToken(diagnostics.lastRandomSeekFallbackReason)}")
        appendLine("randomSeek.decoderCursorFrame=${diagnostics.lastRandomSeekDecoderCursorFrameIndex ?: "-"}")
        appendLine("randomSeek.previousSyncFrame=${diagnostics.lastRandomSeekPreviousSyncFrameIndex ?: "-"}")
        appendLine("randomSeek.auxiliaryUsed=${diagnostics.lastRandomSeekAuxiliaryUsed}")
        appendLine("randomSeek.cacheSource=${safeToken(diagnostics.lastRandomSeekCacheSource)}")
        appendLine("randomSeek.estimatedOutputs=${diagnostics.lastRandomSeekEstimatedOutputCount ?: "-"}")
        appendLine("randomSeek.actualOutputs=${diagnostics.lastRandomSeekActualOutputCount ?: "-"}")
        appendLine("randomSeek.noOp=${diagnostics.randomSeekNoOpPlanCount}")
        appendLine("randomSeek.cache=${diagnostics.randomSeekCachePlanCount}")
        appendLine("randomSeek.history=${diagnostics.randomSeekHistoryPlanCount}")
        appendLine("randomSeek.reverseWindow=${diagnostics.randomSeekReverseWindowPlanCount}")
        appendLine("randomSeek.sequential=${diagnostics.randomSeekSequentialPlanCount}")
        appendLine("randomSeek.sameGop=${diagnostics.randomSeekSameGopPlanCount}")
        appendLine("randomSeek.previousSync=${diagnostics.randomSeekPreviousSyncPlanCount}")
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
