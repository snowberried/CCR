package com.snowberried.ctcinereviewer.media

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.Surface
import com.snowberried.ctcinereviewer.NavigationMode
import com.snowberried.ctcinereviewer.render.EglFrameRenderer
import com.snowberried.ctcinereviewer.render.FrameRenderMode
import com.snowberried.ctcinereviewer.render.VideoViewport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

internal fun androidVideoBitDepth(mime: String, profile: Int?): Int = when (mime) {
    MediaFormat.MIMETYPE_VIDEO_AVC ->
        if (profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10) 10 else 8
    MediaFormat.MIMETYPE_VIDEO_HEVC ->
        if (profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10) 10 else 8
    else -> 8
}

internal fun androidDecodedVideoBitDepth(mime: String, profile: Int?, colorFormat: Int?): Int =
    if (colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010) {
        10
    } else {
        androidVideoBitDepth(mime, profile)
    }

internal fun androidDecodedOutputIsHdr(colorTransfer: Int?, hdrStaticInfoPresent: Boolean): Boolean =
    colorTransfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
        colorTransfer == MediaFormat.COLOR_TRANSFER_HLG ||
        (colorTransfer == null && hdrStaticInfoPresent)

internal class CodecInputState {
    var flushRequiredBeforeDecode: Boolean = false
        private set

    fun onInputQueued() {
        flushRequiredBeforeDecode = true
    }

    fun onFlushCompleted() {
        flushRequiredBeforeDecode = false
    }

    fun onCodecCreated() {
        flushRequiredBeforeDecode = false
    }
}

internal class ReverseRefillEpochs {
    private val foreground = AtomicLong(0)
    private val semantic = AtomicLong(0)

    fun acceptForeground(): Long = foreground.incrementAndGet()
    fun invalidateSemantic(): Long = semantic.incrementAndGet()
    fun semanticEpoch(): Long = semantic.get()
    fun isSemanticCurrent(epoch: Long): Boolean = semantic.get() == epoch
}

class ExactFrameSession(
    context: Context,
    private val listener: Listener,
    renderMode: FrameRenderMode = FrameRenderMode.PILOT,
) : AutoCloseable {
    interface Listener {
        fun onStatus(fileGeneration: Long?, status: String, detail: String? = null)
        fun onVideoOpened(metadata: ContainerMetadata)
        fun onVideoIndexed(video: IndexedVideo) = Unit
        fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics)
        fun onPublicationEvent(event: PublicationEvent) = Unit
        fun onSurfaceAvailabilityChanged(available: Boolean) = Unit
    }

    private data class DecoderResources(
        val fileGeneration: Long,
        val descriptor: ParcelFileDescriptor,
        val extractor: MediaExtractor,
        val trackIndex: Int,
        val format: MediaFormat,
        val codecInfo: MediaCodecInfo,
        var codec: MediaCodec,
        var codecGeneration: Long,
        var outputSurface: Surface,
        val video: IndexedVideo,
        val metadata: ContainerMetadata,
        val codecInputState: CodecInputState = CodecInputState(),
        var decodedOutputUnsupportedReason: String? = null,
    )

    private data class DecodeWork(
        val request: FrameRequest,
        val prefetchPermit: PrefetchPermit?,
        val holdTraversalStride: Int?,
        val holdGestureGeneration: Long?,
        val navigationMode: NavigationMode,
        val foregroundIntentEpoch: Long,
        val acceptedElapsedRealtimeNanos: Long,
    )

    private data class ReverseRefillTrigger(
        val request: FrameRequest,
        val identity: ReverseWindowIdentity,
        val semanticEpoch: Long,
    )

    private data class ReverseRefillWork(
        var trigger: ReverseRefillTrigger,
        val plan: ReverseWindowPlan,
        val duplicateCounts: MutableMap<Long, Int>,
        val generation: ReverseRefillGenerationState,
        val cachedKeys: MutableSet<FrameKey> = mutableSetOf(),
        var inputEos: Boolean = false,
        val wallStartedAtMs: Long = SystemClock.elapsedRealtime(),
        var lastProgressAtMs: Long = wallStartedAtMs,
        var sliceCount: Long = 0,
        val depletionObservation: ReverseRefillDepletionObservation,
    )

    private class ReverseWindowBuildBarrierForTest {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
    }

    private val appContext = context.applicationContext
    private val mainHandler = Handler(appContext.mainLooper)
    private val reverseRefillActive = AtomicBoolean(false)
    private val reverseRefillGenerationForPublication = AtomicLong(0)
    private val reverseRefillActivityForPublication = AtomicLong(0)
    private val reverseWindowBuildGenerationForPublication = AtomicLong(0)
    private val publicationGate = PublicationGate(
        clockNanos = SystemClock::elapsedRealtimeNanos,
        decorateEvent = { event ->
            event.copy(
                reverseRefillGeneration = reverseRefillGenerationForPublication.get(),
                reverseRefillActivitySequence = reverseRefillActivityForPublication.get(),
                reverseRefillInProgress = reverseRefillActive.get(),
                reverseWindowBuildGeneration = reverseWindowBuildGenerationForPublication.get(),
            )
        },
        onPublicationEvent = { event -> mainHandler.post { listener.onPublicationEvent(event) } },
    )
    private val prefetchGate = DirectionalPrefetchGate(SystemClock::elapsedRealtime)
    private val actorThread = HandlerThread("ccr-media-actor").apply { start() }
    private val actor = Handler(actorThread.looper)
    private val latestRequest = LatestRequestSlot<DecodeWork>()
    private val currentVideo = AtomicReference<IndexedVideo?>()
    private val surfaceChanged = AtomicBoolean(false)
    private val surfaceGeneration = AtomicLong(0)
    private val activeReverseGestureGeneration = AtomicLong(NO_GESTURE)
    private val activeReverseStride = AtomicLong(NO_REVERSE_STRIDE)
    private val reverseRefillEpochs = ReverseRefillEpochs()
    private val closed = AtomicBoolean(false)
    private val requestMessageToken = Any()
    private val reverseRefillMessageToken = Any()
    @Volatile private var beforeDecodeHookForTest: ((FrameRequest) -> Unit)? = null
    @Volatile private var beforePrefetchCacheHookForTest: ((FrameRequest, FrameKey) -> Unit)? = null
    private val reverseWindowBuildEntryCountForTest = AtomicLong(0)
    private val reverseWindowBuildBarrierForTest = AtomicReference<ReverseWindowBuildBarrierForTest?>()
    private val renderer: EglFrameRenderer = EglFrameRenderer(publicationGate, { available ->
        onRendererSurfaceChanged(available)
    }, renderMode)

    private fun onRendererSurfaceChanged(available: Boolean) {
        surfaceGeneration.incrementAndGet()
        surfaceChanged.set(true)
        reverseRefillEpochs.invalidateSemantic()
        reverseWindowEngine.invalidate(ReverseWindowFallbackReason.SURFACE_GENERATION_CHANGED)
        actor.post { renderer.invalidateReverseWindow() }
        if (!available) invalidateForSurfaceLoss()
        mainHandler.post { listener.onSurfaceAvailabilityChanged(available) }
    }

    private var resources: DecoderResources? = null
    @Volatile private var diagnostics = DecoderDiagnostics()
    @Volatile private var lastPublicationStats = PublicationStats()
    @Volatile private var lastPublicationEvents = emptyList<PublicationEvent>()
    private var activePrefetch: PrefetchRunState? = null
    private var prefetchCancellationWaste = 0L
    private val requestCoalescedCount = AtomicLong(0)
    private val cachedNavigationAttemptCount = AtomicLong(0)
    private val cachedNavigationActorBypassCount = AtomicLong(0)
    private val cachedNavigationMissFallbackCount = AtomicLong(0)
    private val cachedNavigationStaleCount = AtomicLong(0)
    private val cachedNavigationErrorCount = AtomicLong(0)
    private val cachedNavigationQueueWaitMaxUs = AtomicLong(0)
    private val activeCachedNavigationToken = AtomicReference<GenerationToken?>()
    private val forwardSequentialState = ForwardSequentialDecodeState()
    private val reverseWindowEngine = ReverseWindowEngine()
    private val reverseRefillDepletionTracker = ReverseRefillDepletionTracker()
    private val randomSeekPlanner = RandomSeekPlanner()
    private val adaptivePrefetchDepth = AdaptivePrefetchDepth()
    private var nextCodecGeneration = 0L
    private var reverseRefillTrigger: ReverseRefillTrigger? = null
    private var reverseRefillWork: ReverseRefillWork? = null
    private var reverseRefillScheduled = false
    private var nextReverseRefillGeneration = 0L
    private val reverseRefillLatencyUs = ArrayDeque<Long>()
    private val cachedNavigationPublisher = CachedNavigationPublisher(renderer::enqueueCachedNavigation)

    fun createViewport(context: Context): VideoViewport = VideoViewport(context, renderer)

    fun open(uri: Uri, initialFrameIndex: Int = 0): GenerationToken? {
        if (closed.get()) return null
        suspendPrefetch()
        val token = publicationGate.beginFile()
        return enqueueOpen(uri, initialFrameIndex, token)
    }

    fun tryOpen(uri: Uri, initialFrameIndex: Int = 0): GenerationToken? {
        if (closed.get()) return null
        suspendPrefetch()
        val token = publicationGate.tryBeginFile() ?: return null
        return enqueueOpen(uri, initialFrameIndex, token)
    }

    private fun enqueueOpen(uri: Uri, initialFrameIndex: Int, token: GenerationToken): GenerationToken {
        currentVideo.set(null)
        forwardSequentialState.invalidate()
        activeReverseGestureGeneration.set(NO_GESTURE)
        activeReverseStride.set(NO_REVERSE_STRIDE)
        reverseRefillEpochs.invalidateSemantic()
        reverseWindowEngine.invalidate(ReverseWindowFallbackReason.FILE_GENERATION_CHANGED)
        activeCachedNavigationToken.set(null)
        latestRequest.clear()
        actor.removeCallbacksAndMessages(requestMessageToken)
        notifyStatus(token.fileGeneration, "indexing")
        actor.post { openInternal(uri, token, initialFrameIndex) }
        return token
    }

    fun requestFrame(frameIndex: Int): RequestAcceptance? = requestFrameInternal(
        frameIndex = frameIndex,
        nonBlocking = false,
        prefetchPermit = null,
        holdTraversalStride = null,
        holdGestureGeneration = null,
        navigationMode = NavigationMode.DISCRETE_TAP,
    )

    fun tryRequestFrame(frameIndex: Int): RequestAcceptance? = requestFrameInternal(
        frameIndex = frameIndex,
        nonBlocking = true,
        prefetchPermit = null,
        holdTraversalStride = null,
        holdGestureGeneration = null,
        navigationMode = NavigationMode.DISCRETE_TAP,
    )

    internal fun requestDirectionalFrame(
        frameIndex: Int,
        direction: DirectionalPrefetchDirection = DirectionalPrefetchDirection.FORWARD,
        directionalInputElapsedRealtimeMs: Long = SystemClock.elapsedRealtime(),
    ): RequestAcceptance? = requestFrameInternal(
        frameIndex = frameIndex,
        nonBlocking = false,
        prefetchPermit = newDirectionalPrefetchPermit(direction, directionalInputElapsedRealtimeMs),
        holdTraversalStride = null,
        holdGestureGeneration = null,
        navigationMode = NavigationMode.DISCRETE_TAP,
    )

    internal fun requestNavigationFrame(
        frameIndex: Int,
        navigationMode: NavigationMode,
        holdTraversalStride: Int? = null,
        holdGestureGeneration: Long? = null,
    ): RequestAcceptance? = requestFrameInternal(
        frameIndex = frameIndex,
        nonBlocking = false,
        prefetchPermit = null,
        holdTraversalStride = holdTraversalStride,
        holdGestureGeneration = holdGestureGeneration,
        navigationMode = navigationMode,
    )

    internal fun tryRequestFrame(
        frameIndex: Int,
        prefetchPermit: PrefetchPermit?,
        holdTraversalStride: Int? = null,
        holdGestureGeneration: Long? = null,
        navigationMode: NavigationMode = NavigationMode.DISCRETE_TAP,
    ): RequestAcceptance? = requestFrameInternal(
        frameIndex = frameIndex,
        nonBlocking = true,
        prefetchPermit = prefetchPermit,
        holdTraversalStride = holdTraversalStride,
        holdGestureGeneration = holdGestureGeneration,
        navigationMode = navigationMode,
    )

    internal fun newDirectionalPrefetchPermit(
        direction: DirectionalPrefetchDirection,
        directionalInputElapsedRealtimeMs: Long = SystemClock.elapsedRealtime(),
    ): PrefetchPermit = prefetchGate.newPermit(
        absoluteDeadlineElapsedRealtimeMs = directionalPrefetchDeadline(directionalInputElapsedRealtimeMs),
        direction = direction,
    )

    private fun requestFrameInternal(
        frameIndex: Int,
        nonBlocking: Boolean,
        prefetchPermit: PrefetchPermit?,
        holdTraversalStride: Int?,
        holdGestureGeneration: Long?,
        navigationMode: NavigationMode,
    ): RequestAcceptance? {
        val video = currentVideo.get() ?: run {
            notifyStatus(null, "error", "VIDEO_NOT_READY")
            return null
        }
        if (frameIndex !in video.frames.indices) {
            notifyStatus(video.fileGeneration, "error", "FRAME_INDEX_OUT_OF_RANGE")
            return null
        }
        val acceptance = if (nonBlocking) {
            publicationGate.tryAcceptRequest(video.fileGeneration, frameIndex, video.frames[frameIndex].key)
        } else {
            publicationGate.acceptRequest(video.fileGeneration, frameIndex, video.frames[frameIndex].key)
        } ?: return null
        val intentEpoch = reverseRefillEpochs.acceptForeground()
        if (
            navigationMode == NavigationMode.HOLD_REVERSE &&
            holdTraversalStride in setOf(-1, -5) &&
            holdGestureGeneration != null
        ) {
            val reverseStride = requireNotNull(holdTraversalStride)
            val previousGesture = activeReverseGestureGeneration.getAndSet(holdGestureGeneration)
            val previousStride = activeReverseStride.getAndSet(reverseStride.toLong())
            if (
                previousGesture != holdGestureGeneration ||
                previousStride != reverseStride.toLong()
            ) {
                reverseRefillEpochs.invalidateSemantic()
                reverseWindowEngine.invalidate(ReverseWindowFallbackReason.GESTURE_EPOCH_CHANGED)
            }
        } else {
            activeReverseGestureGeneration.set(NO_GESTURE)
            activeReverseStride.set(NO_REVERSE_STRIDE)
            reverseRefillEpochs.invalidateSemantic()
            reverseWindowEngine.invalidate(
                when (navigationMode) {
                    NavigationMode.DIRECT_FRAME_SEEK,
                    NavigationMode.TIMELINE_SEEK -> ReverseWindowFallbackReason.DIRECT_SEEK
                    else -> ReverseWindowFallbackReason.DIRECTION_CHANGED
                },
            )
        }
        val preserveInFlightReverseCacheTarget = navigationMode == NavigationMode.HOLD_REVERSE &&
            holdTraversalStride != null &&
            reverseWindowEngine.isReadyNextTarget(acceptance.request.expectedKey, holdTraversalStride)
        val work = DecodeWork(
            request = acceptance.request,
            prefetchPermit = prefetchPermit,
            holdTraversalStride = holdTraversalStride,
            holdGestureGeneration = holdGestureGeneration,
            navigationMode = navigationMode,
            foregroundIntentEpoch = intentEpoch,
            acceptedElapsedRealtimeNanos = acceptance.elapsedRealtimeNanos,
        )
        CcrTrace.section(CcrTrace.requestLabel(CcrTrace.REQUEST_ACCEPT, acceptance.request)) {
            if (!trySubmitCachedNavigation(work)) {
                enqueueDecodeWork(work, preserveInFlightReverseCacheTarget)
            }
        }
        notifyStatus(acceptance.request.token.fileGeneration, "decoding")
        return acceptance
    }

    private fun enqueueDecodeWork(work: DecodeWork, preserveInFlightReverseCacheTarget: Boolean = false) {
        if (latestRequest.offer(work)) requestCoalescedCount.incrementAndGet()
        if (!preserveInFlightReverseCacheTarget) renderer.preemptReverseWindowCacheTarget()
        actor.removeCallbacksAndMessages(requestMessageToken)
        actor.postAtTime(
            { latestRequest.take()?.let(::decodeInternal) },
            requestMessageToken,
            SystemClock.uptimeMillis(),
        )
    }

    private fun trySubmitCachedNavigation(work: DecodeWork): Boolean {
        val stride = work.holdTraversalStride
        val gesture = work.holdGestureGeneration
        if (
            work.navigationMode != NavigationMode.HOLD_REVERSE ||
            stride !in setOf(-1, -5) ||
            gesture == null
        ) return false

        val ticket = reverseWindowEngine.acquirePublicationTicket(work.request.expectedKey, requireNotNull(stride))
        val window = reverseWindowEngine.snapshot()
        val allowedSources = when {
            ticket != null -> setOf(CachedNavigationSource.REVERSE_WINDOW)
            window.state == ReverseWindowSlotState.EMPTY -> setOf(CachedNavigationSource.BACKWARD_HISTORY)
            else -> return false
        }
        val input = CachedNavigationInput(
            request = work.request,
            surfaceGeneration = surfaceGeneration.get(),
            gestureGeneration = gesture,
            signedStride = stride,
            allowedSources = allowedSources,
        )
        cachedNavigationAttemptCount.incrementAndGet()
        activeCachedNavigationToken.set(work.request.token)
        cachedNavigationPublisher.submit(
            input = input,
            contextCurrent = { candidate ->
                isCachedNavigationContextCurrent(candidate) &&
                    (ticket == null || reverseWindowEngine.isPublicationTicketCurrent(ticket))
            },
            onPublished = { outcome ->
                activeCachedNavigationToken.compareAndSet(work.request.token, null)
                recordCachedNavigationQueueWait(work)
                cachedNavigationActorBypassCount.incrementAndGet()
                val consumed = ticket?.let {
                    consumeReverseWindowWithDepletionObservation(it.identity) {
                        reverseWindowEngine.consume(it, it.identity)
                    }
                }
                if (ticket != null && consumed !is ReverseWindowConsumeResult.Hit) {
                    reverseWindowEngine.invalidate(ReverseWindowFallbackReason.PUBLICATION_TICKET_STALE)
                    actor.post { renderer.invalidateReverseWindow() }
                }
                reportCachedNavigation(
                    FrameResult.Published(
                        request = work.request,
                        textureTimestampNs = outcome.event.textureTimestampNs,
                        cacheHit = true,
                        imageProbe = outcome.imageProbe,
                    ),
                    renderer.cachedNavigationSnapshot(),
                )
                if (consumed is ReverseWindowConsumeResult.Hit) {
                    val identity = requireNotNull(ticket).identity
                    actor.post { onCachedReverseWindowConsumed(work.request, identity) }
                }
            },
            onFallback = {
                activeCachedNavigationToken.compareAndSet(work.request.token, null)
                recordCachedNavigationQueueWait(work)
                cachedNavigationMissFallbackCount.incrementAndGet()
                enqueueDecodeWork(work)
            },
            onTerminal = { outcome ->
                activeCachedNavigationToken.compareAndSet(work.request.token, null)
                recordCachedNavigationQueueWait(work)
                when (outcome) {
                    is CachedNavigationOutcome.Stale -> {
                        cachedNavigationStaleCount.incrementAndGet()
                        reportCachedNavigation(FrameResult.DiscardedStale(work.request, outcome.code))
                    }
                    is CachedNavigationOutcome.Error -> {
                        cachedNavigationErrorCount.incrementAndGet()
                        reportCachedNavigation(FrameResult.Error(work.request, outcome.code))
                    }
                    is CachedNavigationOutcome.Published,
                    is CachedNavigationOutcome.Miss -> error("cached navigation terminal routing invariant")
                }
            },
        )
        return true
    }

    private fun isCachedNavigationContextCurrent(input: CachedNavigationInput): Boolean =
        !closed.get() &&
            currentVideo.get()?.fileGeneration == input.request.token.fileGeneration &&
            surfaceGeneration.get() == input.surfaceGeneration &&
            activeReverseGestureGeneration.get() == input.gestureGeneration &&
            activeReverseStride.get() == input.signedStride.toLong()

    private fun recordCachedNavigationQueueWait(work: DecodeWork) {
        val elapsedUs = ((SystemClock.elapsedRealtimeNanos() - work.acceptedElapsedRealtimeNanos) / 1_000L)
            .coerceAtLeast(0)
        cachedNavigationQueueWaitMaxUs.updateAndGet { current -> maxOf(current, elapsedUs) }
    }

    private fun onCachedReverseWindowConsumed(request: FrameRequest, identity: ReverseWindowIdentity) {
        val current = resources ?: return
        if (!isReverseWindowIdentityCurrent(current, identity)) return
        reverseRefillWork?.takeIf { it.trigger.identity == identity }?.let { refill ->
            refill.generation.recordConsumedDuringBuild()
            diagnostics = diagnostics.copy(
                reverseRefillConsumedDuringBuildCount =
                    diagnostics.reverseRefillConsumedDuringBuildCount + 1,
            )
        }
        scheduleReverseWindowRefill(current, request, identity)
    }

    fun cancel(): GenerationToken? = cancelInternal(nonBlocking = false)

    fun tryCancel(): GenerationToken? = cancelInternal(nonBlocking = true)

    private fun cancelInternal(nonBlocking: Boolean): GenerationToken? {
        if (closed.get()) return null
        suspendPrefetch()
        val token = if (nonBlocking) {
            publicationGate.tryInvalidateRequest()
        } else {
            publicationGate.invalidateRequest()
        } ?: return null
        activeCachedNavigationToken.set(null)
        latestRequest.clear()
        forwardSequentialState.invalidate()
        activeReverseGestureGeneration.set(NO_GESTURE)
        activeReverseStride.set(NO_REVERSE_STRIDE)
        reverseRefillEpochs.invalidateSemantic()
        reverseWindowEngine.invalidate(ReverseWindowFallbackReason.CANCELLED)
        actor.removeCallbacksAndMessages(requestMessageToken)
        actor.post { renderer.invalidateReverseWindow() }
        notifyStatus(token.fileGeneration, "cancelled")
        return token
    }

    fun trimMemory(level: Int) {
        reverseRefillEpochs.invalidateSemantic()
        reverseWindowEngine.invalidate(ReverseWindowFallbackReason.CACHE_ADMISSION_FAILED)
        actor.post { renderer.invalidateReverseWindow() }
        renderer.trimCache(level)
    }

    internal fun endHoldTraversal(gestureGeneration: Long) {
        if (activeReverseGestureGeneration.compareAndSet(gestureGeneration, NO_GESTURE)) {
            activeReverseStride.set(NO_REVERSE_STRIDE)
            activeCachedNavigationToken.getAndSet(null)?.let(publicationGate::tryInvalidateIfCurrent)
            reverseRefillEpochs.invalidateSemantic()
            reverseWindowEngine.invalidate(ReverseWindowFallbackReason.CANCELLED)
            actor.post { renderer.invalidateReverseWindow() }
        }
    }

    internal fun suspendPrefetch() {
        prefetchGate.suspend()
    }

    internal fun recordViewerRequestCoalesced() {
        requestCoalescedCount.incrementAndGet()
    }

    internal fun setBeforeDecodeHookForTest(hook: ((FrameRequest) -> Unit)?) {
        beforeDecodeHookForTest = hook
    }

    internal fun setBeforePrefetchCacheHookForTest(hook: ((FrameRequest, FrameKey) -> Unit)?) {
        beforePrefetchCacheHookForTest = hook
    }

    internal fun reverseWindowBuildEntryCountForTest(): Long =
        reverseWindowBuildEntryCountForTest.get()

    internal fun armReverseWindowBuildBarrierForTest(): Boolean =
        reverseWindowBuildBarrierForTest.compareAndSet(null, ReverseWindowBuildBarrierForTest())

    internal fun awaitReverseWindowBuildBarrierEntryForTest(timeoutMs: Long = 5_000): Boolean =
        reverseWindowBuildBarrierForTest.get()?.entered?.await(timeoutMs, TimeUnit.MILLISECONDS) == true

    internal fun releaseReverseWindowBuildBarrierForTest() {
        reverseWindowBuildBarrierForTest.getAndSet(null)?.release?.countDown()
    }

    private fun recordReverseWindowBuildEntryForTest() {
        reverseWindowBuildEntryCountForTest.incrementAndGet()
        reverseWindowBuildBarrierForTest.get()?.let { barrier ->
            barrier.entered.countDown()
            if (!barrier.release.await(REVERSE_BUILD_TEST_BARRIER_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                reverseWindowBuildBarrierForTest.compareAndSet(barrier, null)
                error("REVERSE_WINDOW_BUILD_TEST_BARRIER_TIMEOUT")
            }
            reverseWindowBuildBarrierForTest.compareAndSet(barrier, null)
        }
    }

    internal fun awaitActorIdleForTest(timeoutMs: Long = 5_000): Boolean {
        val latch = CountDownLatch(1)
        actor.post(latch::countDown)
        return latch.await(timeoutMs, TimeUnit.MILLISECONDS)
    }

    internal fun diagnosticsSnapshotForTest(timeoutMs: Long = 5_000): DecoderDiagnostics? {
        if (closed.get()) return null
        val latch = CountDownLatch(1)
        val snapshot = AtomicReference<DecoderDiagnostics?>()
        actor.post {
            snapshot.set(buildDiagnosticsSnapshot())
            latch.countDown()
        }
        return if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) snapshot.get() else null
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        releaseReverseWindowBuildBarrierForTest()
        suspendPrefetch()
        renderer.cancelImmediately()
        publicationGate.tryInvalidateRequest()
        activeCachedNavigationToken.set(null)
        forwardSequentialState.invalidate()
        activeReverseGestureGeneration.set(NO_GESTURE)
        activeReverseStride.set(NO_REVERSE_STRIDE)
        reverseRefillEpochs.invalidateSemantic()
        reverseWindowEngine.invalidate(ReverseWindowFallbackReason.CANCELLED)
        latestRequest.clear()
        actor.removeCallbacksAndMessages(requestMessageToken)
        actor.removeCallbacksAndMessages(reverseRefillMessageToken)
        actor.post {
            publicationGate.tryBeginFile()
            closeResources()
            renderer.close()
            actorThread.quitSafely()
        }
    }

    private fun openInternal(uri: Uri, token: GenerationToken, initialFrameIndex: Int) {
        closeResources()
        diagnostics = DecoderDiagnostics()
        activePrefetch = null
        prefetchCancellationWaste = 0
        adaptivePrefetchDepth.reset()
        requestCoalescedCount.set(0)
        var descriptor: ParcelFileDescriptor? = null
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        try {
            if (!renderer.beginFile(token.fileGeneration)) error("RENDER_FILE_REBIND_FAILED")
            descriptor = appContext.contentResolver.openFileDescriptor(uri, "r")
                ?: error("SOURCE_OPEN_FAILED")
            extractor = MediaExtractor().apply { setDataSource(descriptor.fileDescriptor) }
            val trackIndex = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: error("VIDEO_TRACK_NOT_FOUND")
            val format = extractor.getTrackFormat(trackIndex)
            val support = classifyAndroidFormat(format)
            if (support is VideoSupport.Unsupported) error(support.reason)

            extractor.selectTrack(trackIndex)
            val startedAt = SystemClock.elapsedRealtime()
            val samples = mutableListOf<IndexedSample>()
            var ordinal = 0
            while (extractor.sampleTrackIndex >= 0) {
                if (closed.get()) error("OPEN_STALE")
                if (!isCurrent(token)) error("OPEN_STALE")
                if (extractor.sampleTrackIndex == trackIndex) {
                    val ptsUs = extractor.sampleTime
                    if (ptsUs < 0) break
                    samples += IndexedSample(
                        sampleOrdinal = ordinal,
                        ptsUs = ptsUs,
                        sync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0,
                    )
                    ordinal += 1
                }
                if (!extractor.advance()) break
            }
            if (samples.isEmpty()) error("VIDEO_HAS_NO_FRAMES")
            val video = buildFrameIndex(token.fileGeneration, samples)
            val indexBuildMs = SystemClock.elapsedRealtime() - startedAt
            diagnostics = diagnostics.copy(indexBuildMs = indexBuildMs)
            if (!isCurrent(token)) error("OPEN_STALE")

            val codecInfo = selectHardwareDecoder(format) ?: error("HARDWARE_DECODER_REQUIRED")
            val outputSurface = renderer.awaitDecoderSurface(3_000) ?: error("RENDER_SURFACE_NOT_READY")
            val metadata = metadataFrom(format, token.fileGeneration, video.frameCount, codecInfo)
            val configuredOutputMetadata = decodedOutputMetadataFrom(format)
            diagnostics = diagnostics.copy(configuredOutputMetadata = configuredOutputMetadata)
            renderer.configureFrame(metadata, configuredOutputMetadata)
            format.setInteger(MediaFormat.KEY_ROTATION, 0)
            codec = createCodec(codecInfo, format, outputSurface)
            resources = DecoderResources(
                token.fileGeneration,
                descriptor,
                extractor,
                trackIndex,
                format,
                codecInfo,
                codec,
                ++nextCodecGeneration,
                outputSurface,
                video,
                metadata,
            )
            descriptor = null
            extractor = null
            codec = null
            currentVideo.set(video)
            surfaceChanged.set(false)
            notifyOpened(metadata, video)

            val targetIndex = initialFrameIndex.coerceIn(0, video.frames.lastIndex)
            val firstAcceptance = publicationGate.acceptInitialRequest(
                token,
                targetIndex,
                video.frames[targetIndex].key,
            ) ?: return
            val firstRequest = firstAcceptance.request
            val intentEpoch = reverseRefillEpochs.acceptForeground()
            decodeInternal(
                DecodeWork(
                    firstRequest,
                    prefetchPermit = null,
                    holdTraversalStride = null,
                    holdGestureGeneration = null,
                    navigationMode = NavigationMode.DISCRETE_TAP,
                    foregroundIntentEpoch = intentEpoch,
                    acceptedElapsedRealtimeNanos = firstAcceptance.elapsedRealtimeNanos,
                ),
            )
        } catch (error: Throwable) {
            codec?.let(::releaseCodec)
            extractor?.release()
            descriptor?.close()
            if (error.message != "OPEN_STALE" && isCurrent(token)) {
                val code = sanitizeError(error)
                notifyStatus(
                    token.fileGeneration,
                    if (code in UNSUPPORTED_CODES) "unsupported" else "error",
                    code,
                )
            }
        }
    }

    private fun decodeInternal(work: DecodeWork) = CcrTrace.section(
        CcrTrace.requestLabel(CcrTrace.ACTOR_START, work.request),
    ) {
        decodeInternalTraced(work)
    }

    private fun decodeInternalTraced(work: DecodeWork) {
        val request = work.request
        if (closed.get()) return
        if (!isCurrent(request.token)) {
            forwardSequentialState.invalidate()
            report(FrameResult.DiscardedStale(request, "before-decode"))
            return
        }
        beforeDecodeHookForTest?.invoke(request)
        if (!isCurrent(request.token)) {
            forwardSequentialState.invalidate()
            report(FrameResult.DiscardedStale(request, "after-test-hook"))
            return
        }
        val reverseWindowAtAcceptance = reverseWindowEngine.snapshot()
        val reverseRefillWasExpected = work.navigationMode == NavigationMode.HOLD_REVERSE &&
            (reverseRefillTrigger != null || reverseRefillWork != null ||
                reverseWindowAtAcceptance.state == ReverseWindowSlotState.READY ||
                reverseWindowAtAcceptance.refillNeeded)
        var current = resources
        if (current == null || current.fileGeneration != request.token.fileGeneration) {
            forwardSequentialState.invalidate()
            report(FrameResult.Error(request, "DECODER_NOT_READY"))
            return
        }
        if (surfaceChanged.getAndSet(false) || !current.outputSurface.isValid) {
            current = try {
                recreateCodec(current)
            } catch (_: Throwable) {
                report(
                    if (isCurrent(request.token)) {
                        FrameResult.Error(request, "DECODER_SURFACE_RECREATE_FAILED")
                    } else {
                        FrameResult.DiscardedStale(request, "surface-recreate")
                    },
                )
                return
            }
        }
        current.decodedOutputUnsupportedReason?.let { reason ->
            report(FrameResult.Unsupported(request, reason))
            return
        }

        val target = current.video.frames[request.requestedFrameIndex]
        val preBoundarySnapshot = renderer.prefetchSnapshot(listOf(request.expectedKey))
        var randomPlan = if (
            work.navigationMode == NavigationMode.DIRECT_FRAME_SEEK ||
            work.navigationMode == NavigationMode.TIMELINE_SEEK
        ) {
            planRandomSeek(current, request, target, preBoundarySnapshot)
        } else {
            null
        }
        val randomAttemptedPlanKind = randomPlan?.kind
        val preservedReverseKey = request.expectedKey.takeIf {
            randomPlan?.kind == RandomSeekPlanKind.REVERSE_WINDOW
        }
        val reverseIdentity = prepareReverseWindowBoundary(current, work, preservedReverseKey)
        val cacheSnapshot = if (preservedReverseKey != null) {
            preBoundarySnapshot
        } else {
            renderer.prefetchSnapshot(listOf(request.expectedKey))
        }
        var reverseWindowConsumed = false
        if (reverseIdentity != null) {
            val engineSnapshot = reverseWindowEngine.snapshot()
            if (request.expectedKey in cacheSnapshot.reverseWindowKeys) {
                when (
                    val consumed = consumeReverseWindowWithDepletionObservation(reverseIdentity) {
                        CcrTrace.section(
                            CcrTrace.requestLabel(CcrTrace.REVERSE_WINDOW_HIT, request),
                        ) {
                            reverseWindowEngine.consume(request.expectedKey, reverseIdentity)
                        }
                    }
                ) {
                    is ReverseWindowConsumeResult.Hit -> reverseWindowConsumed = true
                    is ReverseWindowConsumeResult.Fallback -> invalidateReverseWindow(consumed.reason)
                }
            } else if (
                engineSnapshot.state == ReverseWindowSlotState.READY &&
                engineSnapshot.nextTarget != null
            ) {
                invalidateReverseWindow(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)
            }
        }

        val cached = renderer.presentCached(request)
        if (cached != null) {
            when (cached.status) {
                EglFrameRenderer.AckStatus.PUBLISHED -> {
                    randomPlan?.let { plan ->
                        recordRandomSeekPlan(plan, randomAttemptedPlanKind ?: plan.kind)
                    }
                    diagnostics = diagnostics.copy(cacheHitCount = diagnostics.cacheHitCount + 1)
                    report(
                        FrameResult.Published(
                            request,
                            cached.textureTimestampNs,
                            cacheHit = true,
                            imageProbe = cached.imageProbe,
                        ),
                    )
                    if (reverseWindowConsumed && reverseIdentity != null) {
                        scheduleReverseWindowRefill(current, request, reverseIdentity)
                    }
                }
                EglFrameRenderer.AckStatus.CACHED -> {
                    if (reverseWindowConsumed) invalidateReverseWindow(ReverseWindowFallbackReason.WINDOW_BUILD_FAILED)
                    report(FrameResult.Error(request, "CACHE_ACK_INVALID"))
                }
                EglFrameRenderer.AckStatus.STALE -> {
                    if (reverseWindowConsumed) invalidateReverseWindow(ReverseWindowFallbackReason.CANCELLED)
                    report(FrameResult.DiscardedStale(request, cached.code ?: "cache"))
                }
                EglFrameRenderer.AckStatus.ERROR -> {
                    if (reverseWindowConsumed) invalidateReverseWindow(ReverseWindowFallbackReason.WINDOW_BUILD_FAILED)
                    report(FrameResult.Error(request, cached.code ?: "CACHE_RENDER_FAILED"))
                }
            }
            return
        }
        if (reverseWindowConsumed) {
            invalidateReverseWindow(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)
        }
        if (reverseIdentity != null && (reverseRefillTrigger != null || reverseRefillWork != null)) {
            // A cache miss makes the foreground path touch/seek the shared codec. A paused rolling
            // decode can no longer be resumed from its cursor, so only this fallback discards it.
            invalidateReverseWindow(ReverseWindowFallbackReason.WINDOW_BUILD_FAILED)
        }
        val reverseRefillStallStartedNanos = work.acceptedElapsedRealtimeNanos.takeIf {
            reverseIdentity != null && reverseRefillWasExpected
        }
        if (
            randomPlan?.kind in setOf(
                RandomSeekPlanKind.NO_OP,
                RandomSeekPlanKind.CACHE,
                RandomSeekPlanKind.HISTORY,
                RandomSeekPlanKind.REVERSE_WINDOW,
            )
        ) {
            randomPlan = planRandomSeek(
                current = current,
                request = request,
                target = target,
                snapshot = renderer.prefetchSnapshot(emptyList()),
                ignoreCache = true,
            )
        }
        diagnostics = diagnostics.copy(cacheMissCount = diagnostics.cacheMissCount + 1)
        renderer.recordForegroundRequest(
            frameIndex = request.requestedFrameIndex,
            direction = work.prefetchPermit?.direction,
        )

        var reversePlan = reverseIdentity?.let { identity ->
            prepareReverseWindowPlan(current, work, target, identity)
        }
        var reverseBuildValid = reversePlan != null
        var reverseWindowInstalled = false
        val targetStartSample = current.video.previousSyncSample(target)
        var exactSeekTarget = reversePlan?.decodeTargets?.first() ?: target
        var exactStartSample = reversePlan?.previousSyncSample ?: targetStartSample
        val prefetch = preparePrefetch(current, request, target, targetStartSample, work.prefetchPermit)
        val forwardTraversalStride = work.holdTraversalStride?.takeIf { it > 0 }
        val sequentialRequested = forwardTraversalStride != null
        val randomContinuation = randomPlan?.takeIf {
            it.kind == RandomSeekPlanKind.SEQUENTIAL_AHEAD ||
                it.kind == RandomSeekPlanKind.SAME_GOP_CURSOR
        }
        val randomPreviousSyncOutputCount = randomPlan?.previousSyncFrameIndex
            ?.let { previousSyncFrameIndex ->
                (target.key.displayFrameIndex - previousSyncFrameIndex + 1).coerceAtLeast(1)
            }
            ?: (target.key.displayFrameIndex + 1)
        val sequentialDecision = if (randomContinuation != null) {
            ForwardSequentialDecision(
                enter = true,
                fallbackReason = ForwardSequentialFallbackReason.NONE,
                duplicateCounts = requireNotNull(randomContinuation.sourceDecoderCursor).duplicateCounts,
            )
        } else {
            forwardSequentialState.decide(
                fileGeneration = current.fileGeneration,
                codecGeneration = current.codecGeneration,
                targetFrameIndex = target.key.displayFrameIndex,
                stride = forwardTraversalStride,
            )
        }
        var sequentialActive = sequentialDecision.enter && work.prefetchPermit == null
        if (sequentialDecision.enter && !sequentialActive) forwardSequentialState.invalidate()
        diagnostics = diagnostics.copy(
            sequentialEntryCount = diagnostics.sequentialEntryCount + if (sequentialActive) 1 else 0,
            sequentialFallbackCount = diagnostics.sequentialFallbackCount +
                if (sequentialRequested && !sequentialActive) 1 else 0,
        )
        var duplicateCounts = sequentialDecision.duplicateCounts.toMutableMap()
        var inputEos = randomContinuation?.sourceDecoderCursor?.inputEos ?: false
        var inputFirstTraced = false
        var outputFirstTraced = false
        var publishedCursorRecorded = false

        try {
            fun abandonReverseWindow(reason: ReverseWindowFallbackReason) {
                if (!reverseBuildValid) return
                reverseBuildValid = false
                reversePlan = null
                exactSeekTarget = target
                exactStartSample = targetStartSample
                diagnostics = diagnostics.copy(
                    reverseWindowFallbackCount = diagnostics.reverseWindowFallbackCount + 1,
                )
                invalidateReverseWindow(reason)
            }

            fun restartWithExactSeek(
                fromSequential: Boolean,
                randomFallbackReason: RandomSeekFallbackReason? = null,
            ) {
                if (fromSequential) {
                    forwardSequentialState.invalidate()
                    diagnostics = diagnostics.copy(
                        sequentialFallbackCount = diagnostics.sequentialFallbackCount + 1,
                    )
                    if (
                        randomPlan?.kind == RandomSeekPlanKind.SEQUENTIAL_AHEAD ||
                        randomPlan?.kind == RandomSeekPlanKind.SAME_GOP_CURSOR
                    ) {
                        randomPlan = requireNotNull(randomPlan).fallbackToPreviousSync(
                            reason = requireNotNull(randomFallbackReason),
                            estimatedOutputCount = randomPreviousSyncOutputCount,
                        )
                    }
                }
                if (reverseBuildValid) {
                    diagnostics = diagnostics.copy(
                        reverseWindowSeekCount = diagnostics.reverseWindowSeekCount + 1,
                    )
                }
                duplicateCounts = prepareExactSeek(current, request, exactSeekTarget, exactStartSample)
                inputEos = false
                sequentialActive = false
            }

            if (!sequentialActive) restartWithExactSeek(fromSequential = false)
            var decodeOrdinal = 0L
            val info = MediaCodec.BufferInfo()
            val deadline = SystemClock.elapsedRealtime() + 15_000
            decodeLoop@ while (SystemClock.elapsedRealtime() < deadline) {
                if (closed.get()) {
                    cancelPrefetch(prefetch)
                    return
                }
                if (!isCurrent(request.token)) {
                    forwardSequentialState.invalidate()
                    cancelPrefetch(prefetch)
                    diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                    report(FrameResult.DiscardedStale(request, "decode-loop"))
                    return
                }

                var inputBatchCount = 0
                while (
                    !inputEos &&
                    inputBatchCount < FOREGROUND_INPUT_BATCH_SIZE &&
                    isCurrent(request.token)
                ) {
                    val inputIndex = current.codec.dequeueInputBuffer(0)
                    if (inputIndex < 0) break
                    val queueInput = {
                        val inputBuffer = current.codec.getInputBuffer(inputIndex)
                            ?: error("INPUT_BUFFER_MISSING")
                        val sampleTrack = current.extractor.sampleTrackIndex
                        if (sampleTrack < 0) {
                            current.codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            current.codecInputState.onInputQueued()
                            inputEos = true
                        } else {
                            val size = current.extractor.readSampleData(inputBuffer, 0)
                            if (size < 0) {
                                current.codec.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    0,
                                    0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                current.codecInputState.onInputQueued()
                                inputEos = true
                            } else {
                                current.codec.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    size,
                                    current.extractor.sampleTime,
                                    0,
                                )
                                current.codecInputState.onInputQueued()
                                current.extractor.advance()
                            }
                        }
                    }
                    CcrTrace.section(CcrTrace.requestLabel(CcrTrace.CODEC_FEED, request)) {
                        if (inputFirstTraced) {
                            queueInput()
                        } else {
                            CcrTrace.section(CcrTrace.requestLabel(CcrTrace.INPUT_FIRST, request), queueInput)
                            inputFirstTraced = true
                        }
                    }
                    inputBatchCount += 1
                }
                if (!isCurrent(request.token)) {
                    forwardSequentialState.invalidate()
                    cancelPrefetch(prefetch)
                    diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                    report(FrameResult.DiscardedStale(request, "input-batch"))
                    return
                }

                var outputBatchCount = 0
                outputDrain@ while (outputBatchCount < FOREGROUND_OUTPUT_BATCH_SIZE) {
                    if (!isCurrent(request.token)) {
                        forwardSequentialState.invalidate()
                        cancelPrefetch(prefetch)
                        diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                        report(FrameResult.DiscardedStale(request, "output-batch"))
                        return
                    }
                    val outputTimeoutUs = if (outputBatchCount == 0) 10_000L else 0L
                    when (val outputIndex = current.codec.dequeueOutputBuffer(info, outputTimeoutUs)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> break@outputDrain
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        when (val support = applyDecodedOutputFormat(current, prefetch)) {
                            VideoSupport.Supported -> {
                                if (reverseBuildValid) {
                                    abandonReverseWindow(ReverseWindowFallbackReason.OUTPUT_FORMAT_CHANGED)
                                }
                                if (sequentialActive) {
                                    restartWithExactSeek(
                                        fromSequential = true,
                                        randomFallbackReason = RandomSeekFallbackReason.OUTPUT_FORMAT_CHANGED,
                                    )
                                    continue@decodeLoop
                                }
                            }
                            is VideoSupport.Unsupported -> {
                                report(FrameResult.Unsupported(request, support.reason))
                                return
                            }
                        }
                    }
                    else -> if (outputIndex >= 0) {
                        outputBatchCount += 1
                        if (!outputFirstTraced) {
                            CcrTrace.section(CcrTrace.requestLabel(CcrTrace.CODEC_FIRST_OUTPUT, request)) {
                                CcrTrace.section(CcrTrace.requestLabel(CcrTrace.OUTPUT_FIRST, request)) { Unit }
                            }
                            outputFirstTraced = true
                        }
                        decodeOrdinal += 1
                        diagnostics = diagnostics.copy(
                            decodeOrdinal = diagnostics.decodeOrdinal + 1,
                            sequentialOutputCount = diagnostics.sequentialOutputCount +
                                if (sequentialActive) 1 else 0,
                        )
                        val ptsUs = info.presentationTimeUs
                        val duplicateOrdinal = duplicateCounts.getOrDefault(ptsUs, 0)
                        duplicateCounts[ptsUs] = duplicateOrdinal + 1
                        val outputFrame = current.video.frameForOutput(ptsUs, duplicateOrdinal)
                        if (outputFrame == null) {
                            current.codec.releaseOutputBuffer(outputIndex, false)
                            if (sequentialActive) {
                                restartWithExactSeek(
                                    fromSequential = true,
                                    randomFallbackReason = RandomSeekFallbackReason.OUTPUT_FRAME_UNMAPPED,
                                )
                                continue@decodeLoop
                            }
                        } else if (outputFrame.key.displayFrameIndex < target.key.displayFrameIndex) {
                            val reverseCacheTarget = reverseBuildValid && reversePlan
                                ?.publicationTargets
                                ?.any { it.key == outputFrame.key } == true
                            if (reverseCacheTarget) {
                                val identity = requireNotNull(reverseIdentity)
                                when (
                                    CcrTrace.section(
                                        CcrTrace.requestLabel(CcrTrace.REVERSE_WINDOW_BUILD, request),
                                    ) {
                                        recordReverseWindowBuildEntryForTest()
                                        cacheReverseWindowOutput(
                                            current = current,
                                            request = request,
                                            frame = outputFrame,
                                            outputIndex = outputIndex,
                                            identity = identity,
                                        )
                                    }.status
                                ) {
                                    EglFrameRenderer.AckStatus.CACHED -> diagnostics = diagnostics.copy(
                                        reverseWindowCachedFrameCount = diagnostics.reverseWindowCachedFrameCount + 1,
                                    )
                                    EglFrameRenderer.AckStatus.STALE -> {
                                        if (!isCurrent(request.token)) {
                                            diagnostics = diagnostics.copy(
                                                staleDiscardCount = diagnostics.staleDiscardCount + 1,
                                            )
                                            report(FrameResult.DiscardedStale(request, "reverse-window-build"))
                                            return
                                        }
                                        abandonReverseWindow(ReverseWindowFallbackReason.CANCELLED)
                                    }
                                    EglFrameRenderer.AckStatus.PUBLISHED,
                                    EglFrameRenderer.AckStatus.ERROR -> abandonReverseWindow(
                                        ReverseWindowFallbackReason.CACHE_ADMISSION_FAILED,
                                    )
                                }
                            } else if (prefetch?.direction == DirectionalPrefetchDirection.REVERSE && prefetch.contains(outputFrame.key.displayFrameIndex)) {
                                if (!isCurrent(request.token)) {
                                    current.codec.releaseOutputBuffer(outputIndex, false)
                                    cancelPrefetch(prefetch)
                                    diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                                    report(FrameResult.DiscardedStale(request, "reverse-prefetch-preempted"))
                                    return
                                }
                                if (!markPrefetchStarted(prefetch, outputFrame.key.displayFrameIndex)) {
                                    current.codec.releaseOutputBuffer(outputIndex, false)
                                    continue@decodeLoop
                                }
                                when (cacheDecodedOutput(current, request, outputFrame, outputIndex, prefetch).status) {
                                    EglFrameRenderer.AckStatus.CACHED -> if (
                                        !markPrefetchCompleted(prefetch, outputFrame.key.displayFrameIndex)
                                    ) {
                                        renderer.discardPrefetched(outputFrame.key)
                                    }
                                    EglFrameRenderer.AckStatus.STALE -> {
                                        cancelPrefetch(prefetch)
                                        diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                                        report(FrameResult.DiscardedStale(request, "reverse-prefetch"))
                                        return
                                    }
                                    EglFrameRenderer.AckStatus.PUBLISHED,
                                    EglFrameRenderer.AckStatus.ERROR -> cancelPrefetch(prefetch)
                                }
                            } else {
                                current.codec.releaseOutputBuffer(outputIndex, false)
                            }
                        } else if (outputFrame.key != target.key) {
                            current.codec.releaseOutputBuffer(outputIndex, false)
                            if (sequentialActive) {
                                restartWithExactSeek(
                                    fromSequential = true,
                                    randomFallbackReason = RandomSeekFallbackReason.OUTPUT_PASSED_TARGET,
                                )
                                continue@decodeLoop
                            }
                            report(FrameResult.Error(request, "OUTPUT_PASSED_TARGET"))
                            return
                        } else {
                            diagnostics = diagnostics.copy(
                                foregroundDecodedFrameCount = diagnostics.foregroundDecodedFrameCount + 1,
                            )
                            val ack = if (reverseBuildValid) {
                                val plan = requireNotNull(reversePlan)
                                val identity = requireNotNull(reverseIdentity)
                                val cacheAck = CcrTrace.section(
                                    CcrTrace.requestLabel(CcrTrace.REVERSE_WINDOW_BUILD, request),
                                ) {
                                    recordReverseWindowBuildEntryForTest()
                                    cacheReverseWindowOutput(
                                        current = current,
                                        request = request,
                                        frame = outputFrame,
                                        outputIndex = outputIndex,
                                        identity = identity,
                                    )
                                }
                                if (cacheAck.status != EglFrameRenderer.AckStatus.CACHED) {
                                    abandonReverseWindow(
                                        if (cacheAck.status == EglFrameRenderer.AckStatus.STALE) {
                                            ReverseWindowFallbackReason.CANCELLED
                                        } else {
                                            ReverseWindowFallbackReason.CACHE_ADMISSION_FAILED
                                        },
                                    )
                                    restartWithExactSeek(fromSequential = false)
                                    continue@decodeLoop
                                }
                                diagnostics = diagnostics.copy(
                                    reverseWindowCachedFrameCount = diagnostics.reverseWindowCachedFrameCount + 1,
                                )
                                if (!isReverseWindowBuildCurrent(current, work, identity)) {
                                    abandonReverseWindow(ReverseWindowFallbackReason.CANCELLED)
                                    restartWithExactSeek(fromSequential = false)
                                    continue@decodeLoop
                                }
                                val expectedKeys = plan.publicationTargets.map { it.key }
                                val readyKeys = renderer.prefetchSnapshot(expectedKeys).cachedFrameKeys
                                val refill = CcrTrace.section(
                                    CcrTrace.requestLabel(CcrTrace.REVERSE_WINDOW_REFILL, request),
                                ) {
                                    reverseWindowEngine.refill(plan, readyKeys, identity)
                                }
                                val consumed = if (refill is ReverseWindowRefillResult.Ready) {
                                    reverseWindowEngine.consume(request.expectedKey, identity)
                                } else {
                                    null
                                }
                                if (
                                    refill !is ReverseWindowRefillResult.Ready ||
                                    consumed !is ReverseWindowConsumeResult.Hit
                                ) {
                                    abandonReverseWindow(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)
                                    restartWithExactSeek(fromSequential = false)
                                    continue@decodeLoop
                                }
                                reverseWindowInstalled = true
                                val presented = CcrTrace.section(
                                    CcrTrace.requestLabel(CcrTrace.CODEC_TARGET_OUTPUT, request),
                                ) {
                                    CcrTrace.section(CcrTrace.requestLabel(CcrTrace.OUTPUT_TARGET, request)) {
                                        renderer.presentCached(request)
                                    }
                                }
                                if (presented == null) {
                                    reverseWindowInstalled = false
                                    abandonReverseWindow(ReverseWindowFallbackReason.READY_KEYS_MISMATCH)
                                    restartWithExactSeek(fromSequential = false)
                                    continue@decodeLoop
                                }
                                presented
                            } else {
                                val handle = renderer.queueTarget(request)
                                if (handle == null) {
                                    current.codec.releaseOutputBuffer(outputIndex, false)
                                    report(FrameResult.Error(request, "RENDER_TARGET_BUSY"))
                                    return
                                }
                                CcrTrace.section(CcrTrace.requestLabel(CcrTrace.CODEC_TARGET_OUTPUT, request)) {
                                    CcrTrace.section(CcrTrace.requestLabel(CcrTrace.OUTPUT_TARGET, request)) {
                                        CcrTrace.section(CcrTrace.requestLabel(CcrTrace.SURFACE_WAIT, request)) {
                                            current.codec.releaseOutputBuffer(outputIndex, true)
                                            renderer.awaitTarget(handle, 3_000)
                                        }
                                    }
                                }
                            }
                            when (ack.status) {
                                EglFrameRenderer.AckStatus.PUBLISHED -> {
                                    reverseRefillStallStartedNanos?.let(::recordReverseWindowRefillStall)
                                    randomPlan = randomPlan?.withActualDecodeOutputCount(
                                        decodeOrdinal.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                                    )
                                    randomPlan?.let { plan ->
                                        recordRandomSeekPlan(plan, randomAttemptedPlanKind ?: plan.kind)
                                    }
                                    if (prefetch?.direction == DirectionalPrefetchDirection.REVERSE) {
                                        cancelPrefetch(prefetch)
                                    }
                                    if (prefetch?.direction == DirectionalPrefetchDirection.FORWARD) {
                                        forwardSequentialState.invalidate()
                                    } else {
                                        forwardSequentialState.recordPublished(
                                            fileGeneration = current.fileGeneration,
                                            codecGeneration = current.codecGeneration,
                                            outputFrameIndex = target.key.displayFrameIndex,
                                            duplicateCounts = duplicateCounts,
                                            inputEos = inputEos,
                                        )
                                        publishedCursorRecorded = true
                                    }
                                    report(
                                        FrameResult.Published(
                                            request,
                                            ack.textureTimestampNs,
                                            cacheHit = false,
                                            imageProbe = ack.imageProbe,
                                        ),
                                    )
                                    if (reverseWindowInstalled && reverseIdentity != null) {
                                        scheduleReverseWindowRefill(current, request, reverseIdentity)
                                    }
                                    if (prefetch?.direction == DirectionalPrefetchDirection.FORWARD) {
                                        prefetchForward(
                                            current = current,
                                            request = request,
                                            target = target,
                                            prefetch = prefetch,
                                            duplicateCounts = duplicateCounts,
                                            inputEosAtTarget = inputEos,
                                        )
                                    }
                                }
                                EglFrameRenderer.AckStatus.CACHED -> report(
                                    FrameResult.Error(request, "PUBLISH_ACK_INVALID"),
                                )
                                EglFrameRenderer.AckStatus.STALE -> {
                                    if (reverseWindowInstalled) {
                                        invalidateReverseWindow(ReverseWindowFallbackReason.CANCELLED)
                                    }
                                    diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                                    report(FrameResult.DiscardedStale(request, ack.code ?: "render"))
                                }
                                EglFrameRenderer.AckStatus.ERROR -> {
                                    if (reverseWindowInstalled) {
                                        invalidateReverseWindow(ReverseWindowFallbackReason.WINDOW_BUILD_FAILED)
                                    }
                                    report(FrameResult.Error(request, ack.code ?: "RENDER_FAILED"))
                                }
                            }
                            return
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            if (sequentialActive) {
                                restartWithExactSeek(
                                    fromSequential = true,
                                    randomFallbackReason = RandomSeekFallbackReason.END_OF_STREAM,
                                )
                                continue@decodeLoop
                            }
                            report(FrameResult.Error(request, "EOS_BEFORE_TARGET"))
                            return
                        }
                    }
                    }
                }
            }
            report(FrameResult.Error(request, "DECODE_TIMEOUT"))
        } catch (_: Throwable) {
            report(
                if (isCurrent(request.token)) {
                    FrameResult.Error(request, "DECODE_FAILED")
                } else {
                    FrameResult.DiscardedStale(request, "decode-exception")
                },
            )
        } finally {
            if (reverseBuildValid && !reverseWindowInstalled) {
                diagnostics = diagnostics.copy(
                    reverseWindowFallbackCount = diagnostics.reverseWindowFallbackCount + 1,
                )
                invalidateReverseWindow(ReverseWindowFallbackReason.WINDOW_BUILD_FAILED)
            }
            if (!publishedCursorRecorded) forwardSequentialState.invalidate()
            cancelPrefetch(prefetch)
        }
    }

    private fun prepareExactSeek(
        current: DecoderResources,
        request: FrameRequest,
        target: IndexedFrame,
        startSample: IndexedSample,
    ): MutableMap<Long, Int> {
        forwardSequentialState.invalidate()
        if (current.codecInputState.flushRequiredBeforeDecode) {
            CcrTrace.section(CcrTrace.requestLabel(CcrTrace.CODEC_FLUSH, request)) {
                CcrTrace.section(CcrTrace.requestLabel(CcrTrace.FLUSH, request)) {
                    current.codec.flush()
                }
            }
            current.codecInputState.onFlushCompleted()
            diagnostics = diagnostics.copy(flushCount = diagnostics.flushCount + 1)
        }
        CcrTrace.section(CcrTrace.requestLabel(CcrTrace.SEEK_EXTRACTOR, request)) {
            CcrTrace.section(CcrTrace.requestLabel(CcrTrace.SEEK, request)) {
                current.extractor.seekTo(target.key.ptsUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }
        }
        diagnostics = diagnostics.copy(seekCount = diagnostics.seekCount + 1)
        return mutableMapOf<Long, Int>().also { counts ->
            current.video.frames.asSequence()
                .filter { it.sampleOrdinal < startSample.sampleOrdinal }
                .forEach { frame ->
                    counts[frame.key.ptsUs] = counts.getOrDefault(frame.key.ptsUs, 0) + 1
                }
        }
    }

    private fun prepareReverseWindowBoundary(
        current: DecoderResources,
        work: DecodeWork,
        preserveCachedKey: FrameKey?,
    ): ReverseWindowIdentity? {
        val stride = work.holdTraversalStride
        val gesture = work.holdGestureGeneration
        if (
            work.navigationMode != NavigationMode.HOLD_REVERSE ||
            stride !in setOf(-1, -5) ||
            gesture == null
        ) {
            val reason = when (work.navigationMode) {
                NavigationMode.DIRECT_FRAME_SEEK,
                NavigationMode.TIMELINE_SEEK -> ReverseWindowFallbackReason.DIRECT_SEEK
                else -> ReverseWindowFallbackReason.DIRECTION_CHANGED
            }
            cancelReverseRefillState(reason)
            reverseWindowEngine.invalidate(reason)
            renderer.invalidateReverseWindow(preserveCachedKey)
            return null
        }
        val reverseStride = requireNotNull(stride)
        if (
            activeReverseGestureGeneration.get() != gesture ||
            activeReverseStride.get() != reverseStride.toLong()
        ) {
            invalidateReverseWindow(ReverseWindowFallbackReason.GESTURE_EPOCH_CHANGED)
            return null
        }
        val identity = ReverseWindowIdentity(
            fileGeneration = current.fileGeneration,
            codecGeneration = current.codecGeneration,
            surfaceGeneration = surfaceGeneration.get(),
            gestureEpoch = gesture,
        )
        val engineSnapshot = reverseWindowEngine.snapshot()
        val rendererSnapshot = renderer.prefetchSnapshot()
        if (
            engineSnapshot.state == ReverseWindowSlotState.EMPTY &&
            rendererSnapshot.reverseWindowKeys.isNotEmpty()
        ) {
            renderer.invalidateReverseWindow()
        }
        return identity
    }

    private fun applyDecodedOutputFormat(
        current: DecoderResources,
        prefetch: PrefetchRunState?,
    ): VideoSupport {
        val decoded = runCatching {
            decodedOutputMetadataFrom(current.codec.outputFormat)
        }.getOrElse {
            return VideoSupport.Unsupported("OUTPUT_FORMAT_UNSUPPORTED").also {
                current.decodedOutputUnsupportedReason = it.reason
            }
        }
        diagnostics = diagnostics.copy(
            outputFormatChangeCount = diagnostics.outputFormatChangeCount + 1,
            decodedOutputFormatHistory = diagnostics.decodedOutputFormatHistory
                .let { history -> if (history.lastOrNull() == decoded) history else history + decoded },
        )
        return classifyDecodedOutput(current.metadata, decoded).also { support ->
            when (support) {
                VideoSupport.Supported -> {
                    current.decodedOutputUnsupportedReason = null
                    renderer.configureFrame(current.metadata, decoded)
                    refreshPrefetchLimit(prefetch)
                }
                is VideoSupport.Unsupported -> current.decodedOutputUnsupportedReason = support.reason
            }
        }
    }

    private fun planRandomSeek(
        current: DecoderResources,
        request: FrameRequest,
        target: IndexedFrame,
        snapshot: EglFrameRenderer.PrefetchSnapshot,
        ignoreCache: Boolean = false,
    ): RandomSeekPlan = CcrTrace.section(
        CcrTrace.requestLabel(CcrTrace.SEEK_PLAN, request),
    ) {
        val historyKeys = if (ignoreCache) emptySet() else snapshot.backwardHistoryKeys
        val reverseKeys = if (ignoreCache) emptySet() else snapshot.reverseWindowKeys
        val cachedKeys = if (ignoreCache) {
            emptySet()
        } else {
            snapshot.cachedFrameKeys - historyKeys - reverseKeys
        }
        randomSeekPlanner.plan(
            RandomSeekInput(
                video = current.video,
                generation = request.token,
                codecGeneration = current.codecGeneration,
                displayedKey = snapshot.lastPublishedKey.takeUnless { ignoreCache },
                targetKey = target.key,
                decoderCursor = forwardSequentialState.randomSeekCursor(
                    video = current.video,
                    fileGeneration = current.fileGeneration,
                    codecGeneration = current.codecGeneration,
                ),
                textureCacheKeys = cachedKeys,
                backwardHistoryKeys = historyKeys,
                reverseWindowKeys = reverseKeys,
            ),
        )
    }

    private fun recordRandomSeekPlan(
        plan: RandomSeekPlan,
        attemptedPlanKind: RandomSeekPlanKind,
    ) {
        diagnostics = diagnostics.copy(
            randomSeekNoOpPlanCount = diagnostics.randomSeekNoOpPlanCount +
                if (plan.kind == RandomSeekPlanKind.NO_OP) 1 else 0,
            randomSeekCachePlanCount = diagnostics.randomSeekCachePlanCount +
                if (plan.kind == RandomSeekPlanKind.CACHE) 1 else 0,
            randomSeekHistoryPlanCount = diagnostics.randomSeekHistoryPlanCount +
                if (plan.kind == RandomSeekPlanKind.HISTORY) 1 else 0,
            randomSeekReverseWindowPlanCount = diagnostics.randomSeekReverseWindowPlanCount +
                if (plan.kind == RandomSeekPlanKind.REVERSE_WINDOW) 1 else 0,
            randomSeekSequentialPlanCount = diagnostics.randomSeekSequentialPlanCount +
                if (plan.kind == RandomSeekPlanKind.SEQUENTIAL_AHEAD) 1 else 0,
            randomSeekSameGopPlanCount = diagnostics.randomSeekSameGopPlanCount +
                if (plan.kind == RandomSeekPlanKind.SAME_GOP_CURSOR) 1 else 0,
            randomSeekPreviousSyncPlanCount = diagnostics.randomSeekPreviousSyncPlanCount +
                if (plan.kind == RandomSeekPlanKind.PREVIOUS_SYNC) 1 else 0,
            lastRandomSeekAttemptedPlanKind = attemptedPlanKind.name,
            lastRandomSeekPlanKind = plan.kind.name,
            lastRandomSeekFallbackReason = plan.fallbackReason.name,
            lastRandomSeekDecoderCursorFrameIndex = plan.observedDecoderCursorFrameIndex,
            lastRandomSeekPreviousSyncFrameIndex = plan.previousSyncFrameIndex,
            lastRandomSeekAuxiliaryUsed = plan.auxiliaryUsed,
            lastRandomSeekCacheSource = plan.expectedCacheResult.name,
            lastRandomSeekEstimatedOutputCount = plan.estimatedDecodeOutputCount,
            lastRandomSeekActualOutputCount = plan.actualDecodeOutputCount,
        )
    }

    private fun prepareReverseWindowPlan(
        current: DecoderResources,
        work: DecodeWork,
        target: IndexedFrame,
        identity: ReverseWindowIdentity,
    ): ReverseWindowPlan? = CcrTrace.section(
        CcrTrace.requestLabel(CcrTrace.REVERSE_WINDOW_PLAN, work.request),
    ) {
        val stride = requireNotNull(work.holdTraversalStride)
        val anchorIndex = target.key.displayFrameIndex - stride
        val anchor = current.video.frames.getOrNull(anchorIndex)
        val snapshot = renderer.prefetchSnapshot()
        val frameBytes = snapshot.budget.canonicalFrameBytes
        val budgetBytes = snapshot.budget.cacheBudgetBytes
        diagnostics = diagnostics.copy(
            canonicalFrameBytes = frameBytes,
            cacheBudgetBytes = budgetBytes,
        )
        if (
            anchor == null ||
            snapshot.lastPublishedKey != anchor.key ||
            frameBytes <= 0 ||
            frameBytes > budgetBytes / 2
        ) {
            diagnostics = diagnostics.copy(
                reverseWindowFallbackCount = diagnostics.reverseWindowFallbackCount + 1,
            )
            return@section null
        }
        val capacity = ReverseWindowCapacity.fromBytes(
            availableBytes = budgetBytes - frameBytes * 2,
            canonicalFrameBytes = frameBytes,
        )
        when (
            val decision = buildReverseWindowPlan(
                video = current.video,
                identity = identity,
                anchorKey = anchor.key,
                signedStride = stride,
                capacity = capacity,
            )
        ) {
            is ReverseWindowPlanDecision.Planned -> {
                reverseWindowBuildGenerationForPublication.incrementAndGet()
                diagnostics = diagnostics.copy(
                    reverseWindowBuildCount = diagnostics.reverseWindowBuildCount + 1,
                )
                decision.plan
            }
            is ReverseWindowPlanDecision.Fallback -> {
                diagnostics = diagnostics.copy(
                    reverseWindowFallbackCount = diagnostics.reverseWindowFallbackCount + 1,
                )
                null
            }
        }
    }

    private fun cacheReverseWindowOutput(
        current: DecoderResources,
        request: FrameRequest,
        frame: IndexedFrame,
        outputIndex: Int,
        identity: ReverseWindowIdentity,
        requireCurrentRequest: Boolean = true,
        semanticEpoch: Long? = null,
        commitReverseWindowKeys: (() -> Set<FrameKey>?)? = null,
    ): EglFrameRenderer.RenderAck {
        val currentEnough = if (requireCurrentRequest) {
            isReverseWindowBuildCurrent(current, request, identity)
        } else {
            isReverseWindowIdentityCurrent(current, identity) &&
                semanticEpoch?.let(reverseRefillEpochs::isSemanticCurrent) == true
        }
        if (!currentEnough) {
            current.codec.releaseOutputBuffer(outputIndex, false)
            return EglFrameRenderer.RenderAck(EglFrameRenderer.AckStatus.STALE, 0, "REVERSE_WINDOW_STALE")
        }
        val handle = renderer.queueCacheOnly(
            token = request.token,
            expectedKey = frame.key,
            cacheRetentionAllowed = {
                if (requireCurrentRequest) {
                    isReverseWindowBuildCurrent(current, request, identity)
                } else {
                    isReverseWindowIdentityCurrent(current, identity) &&
                        semanticEpoch?.let(reverseRefillEpochs::isSemanticCurrent) == true
                }
            },
            kind = EglFrameRenderer.CacheTargetKind.REVERSE_WINDOW,
            maximumByteSize = renderer.prefetchSnapshot().budget.cacheBudgetBytes,
            commitReverseWindowKeys = commitReverseWindowKeys,
            requireCurrentRequest = requireCurrentRequest,
        )
        if (handle == null) {
            current.codec.releaseOutputBuffer(outputIndex, false)
            return EglFrameRenderer.RenderAck(
                EglFrameRenderer.AckStatus.ERROR,
                0,
                "REVERSE_WINDOW_TARGET_BUSY",
            )
        }
        current.codec.releaseOutputBuffer(outputIndex, true)
        return renderer.awaitCacheTarget(
            handle = handle,
            timeoutMs = 3_000,
            invalidateRequestOnTimeout = false,
        )
    }

    private fun isReverseWindowBuildCurrent(
        current: DecoderResources,
        work: DecodeWork,
        identity: ReverseWindowIdentity,
    ): Boolean = isReverseWindowBuildCurrent(current, work.request, identity) &&
        work.holdGestureGeneration == identity.gestureEpoch &&
        work.holdTraversalStride?.toLong() == activeReverseStride.get()

    private fun isReverseWindowBuildCurrent(
        current: DecoderResources,
        request: FrameRequest,
        identity: ReverseWindowIdentity,
    ): Boolean = isCurrent(request.token) &&
        current.fileGeneration == identity.fileGeneration &&
        current.codecGeneration == identity.codecGeneration &&
        surfaceGeneration.get() == identity.surfaceGeneration &&
        activeReverseGestureGeneration.get() == identity.gestureEpoch

    private fun isReverseWindowIdentityCurrent(
        current: DecoderResources,
        identity: ReverseWindowIdentity,
    ): Boolean = !closed.get() &&
        current.fileGeneration == identity.fileGeneration &&
        current.codecGeneration == identity.codecGeneration &&
        surfaceGeneration.get() == identity.surfaceGeneration &&
        activeReverseGestureGeneration.get() == identity.gestureEpoch

    private fun invalidateReverseWindow(reason: ReverseWindowFallbackReason) {
        reverseRefillEpochs.invalidateSemantic()
        cancelReverseRefillState(reason)
        reverseWindowEngine.invalidate(reason)
        renderer.invalidateReverseWindow()
    }

    private fun scheduleReverseWindowRefill(
        current: DecoderResources,
        request: FrameRequest,
        identity: ReverseWindowIdentity,
    ) {
        if (!isReverseWindowIdentityCurrent(current, identity)) return
        CcrTrace.section(CcrTrace.requestLabel(CcrTrace.REVERSE_REFILL_TRIGGER, request)) { Unit }
        val trigger = ReverseRefillTrigger(request, identity, reverseRefillEpochs.semanticEpoch())
        val activeWork = reverseRefillWork
        if (activeWork != null) {
            if (activeWork.trigger.identity != identity ||
                activeWork.trigger.semanticEpoch != trigger.semanticEpoch
            ) {
                cancelReverseRefillState(ReverseWindowFallbackReason.GESTURE_EPOCH_CHANGED)
            } else {
                activeWork.trigger = trigger
            }
        }
        reverseRefillTrigger = trigger
        postReverseRefillSlice()
    }

    private fun postReverseRefillSlice(delayMs: Long = 0) {
        if (reverseRefillScheduled || closed.get()) return
        reverseRefillScheduled = true
        actor.postAtTime(
            {
                reverseRefillScheduled = false
                runReverseRefillSlice()
            },
            reverseRefillMessageToken,
            SystemClock.uptimeMillis() + delayMs,
        )
    }

    private fun runReverseRefillSlice() {
        try {
            runReverseRefillSliceInternal()
        } catch (_: Throwable) {
            surfaceChanged.set(true)
            forwardSequentialState.invalidate()
            invalidateReverseWindow(ReverseWindowFallbackReason.CODEC_ERROR)
        }
    }

    private fun consumeReverseWindowWithDepletionObservation(
        identity: ReverseWindowIdentity,
        consume: () -> ReverseWindowConsumeResult,
    ): ReverseWindowConsumeResult = reverseRefillDepletionTracker.consumeAndObserve(identity, consume)

    private fun runReverseRefillSliceInternal() {
        val current = resources ?: run {
            cancelReverseRefillState(ReverseWindowFallbackReason.CANCELLED)
            return
        }
        val trigger = reverseRefillTrigger ?: return
        if (!isReverseRefillSemanticCurrent(current, trigger)) {
            cancelReverseRefillState(ReverseWindowFallbackReason.CANCELLED)
            renderer.invalidateReverseWindow()
            return
        }
        if (!isReverseRefillForegroundIdle(trigger)) {
            postReverseRefillSlice(REFILL_YIELD_DELAY_MS)
            return
        }

        var refill = reverseRefillWork
        if (refill == null) {
            val window = reverseWindowEngine.snapshot()
            val freeSlots = window.targetCapacity - window.remainingTargetCount
            val anchorKey = window.oldestTarget
            val signedStride = window.signedStride
            val lowWater = signedStride?.let { stride ->
                reverseRefillLowWaterDecision(
                    targetCapacity = window.targetCapacity,
                    measuredRefillLatencyUs = recentReverseRefillP95Us(),
                    cadenceUs = reverseCadenceUs(stride),
                )
            }
            if (
                window.state !in setOf(ReverseWindowSlotState.READY, ReverseWindowSlotState.EXHAUSTED) ||
                anchorKey == null ||
                signedStride !in setOf(-1, -5) ||
                lowWater?.shouldStart(window.remainingTargetCount) != true ||
                freeSlots <= 0
            ) {
                reverseRefillTrigger = null
                return
            }
            val rendererSnapshot = renderer.prefetchSnapshot()
            val frameBytes = rendererSnapshot.budget.canonicalFrameBytes
            if (frameBytes <= 0) {
                reverseRefillTrigger = null
                return
            }
            val refillTargetCount = minOf(freeSlots, REFILL_BATCH_TARGETS)
            val capacity = ReverseWindowCapacity.fromBytes(
                availableBytes = frameBytes * refillTargetCount,
                canonicalFrameBytes = frameBytes,
            )
            val decision = CcrTrace.section(
                CcrTrace.requestLabel(CcrTrace.REVERSE_WINDOW_PLAN, trigger.request),
            ) {
                buildReverseWindowPlan(
                    video = current.video,
                    identity = trigger.identity,
                    anchorKey = anchorKey,
                    signedStride = requireNotNull(signedStride),
                    capacity = capacity,
                )
            }
            val plan = (decision as? ReverseWindowPlanDecision.Planned)?.plan ?: run {
                reverseRefillTrigger = null
                return
            }
            val generation = ReverseRefillGenerationState(++nextReverseRefillGeneration)
            reverseRefillGenerationForPublication.set(generation.generationId)
            val depletionObservation = ReverseRefillDepletionObservation(
                identity = trigger.identity,
                generationId = generation.generationId,
                latch = ReverseRefillDepletionLatch(window.remainingTargetCount),
            )
            val startedRefill = ReverseRefillWork(
                trigger = trigger,
                plan = plan,
                duplicateCounts = mutableMapOf(),
                generation = generation,
                depletionObservation = depletionObservation,
            )
            reverseRefillWork = startedRefill
            reverseRefillDepletionTracker.activate(depletionObservation)
            reverseRefillActive.set(true)
            val flushBefore = diagnostics.flushCount
            val seekBefore = diagnostics.seekCount
            try {
                startedRefill.duplicateCounts.putAll(
                    CcrTrace.section(
                        CcrTrace.requestLabel(CcrTrace.REVERSE_REFILL_START, trigger.request),
                    ) {
                        prepareExactSeek(
                            current = current,
                            request = trigger.request,
                            target = plan.decodeTargets.first(),
                            startSample = plan.previousSyncSample,
                        )
                    },
                )
            } finally {
                if (diagnostics.seekCount > seekBefore) generation.recordSeek()
                if (diagnostics.flushCount > flushBefore) generation.recordFlush()
                val generationSnapshot = generation.snapshot()
                diagnostics = diagnostics.copy(
                    reverseWindowSeekCount = diagnostics.reverseWindowSeekCount + generationSnapshot.seekCount,
                    reverseRefillGenerationCount = diagnostics.reverseRefillGenerationCount + 1,
                    reverseRefillInitialSeekCount =
                        diagnostics.reverseRefillInitialSeekCount + generationSnapshot.seekCount,
                    reverseRefillInitialFlushCount =
                        diagnostics.reverseRefillInitialFlushCount + generationSnapshot.flushCount,
                    reverseRefillMaxSeekPerGeneration = maxOf(
                        diagnostics.reverseRefillMaxSeekPerGeneration,
                        generationSnapshot.seekCount,
                    ),
                    reverseRefillMaxFlushPerGeneration = maxOf(
                        diagnostics.reverseRefillMaxFlushPerGeneration,
                        generationSnapshot.flushCount,
                    ),
                    reverseLowWaterTriggerCount = diagnostics.reverseLowWaterTriggerCount + 1,
                    reverseRefillStartedRemainingTargets = window.remainingTargetCount,
                )
            }
            refill = startedRefill
        }

        if (SystemClock.elapsedRealtime() - refill.wallStartedAtMs > REFILL_TIMEOUT_MS) {
            invalidateReverseWindow(ReverseWindowFallbackReason.WINDOW_BUILD_FAILED)
            return
        }
        if (!isReverseRefillForegroundIdle(refill.trigger)) {
            postReverseRefillSlice(REFILL_YIELD_DELAY_MS)
            return
        }
        if (refill.sliceCount > 0) {
            CcrTrace.section(
                CcrTrace.requestLabel(CcrTrace.REVERSE_REFILL_RESUME, refill.trigger.request),
            ) { Unit }
            refill.generation.recordResumedSlice()
            diagnostics = diagnostics.copy(
                reverseRefillResumedSliceCount = diagnostics.reverseRefillResumedSliceCount + 1,
            )
        }
        refill.sliceCount += 1
        refill.depletionObservation.latch.observeRemainingTargetCount(
            reverseWindowEngine.snapshot().remainingTargetCount,
        )
        reverseRefillActivityForPublication.incrementAndGet()

        CcrTrace.section(CcrTrace.requestLabel(CcrTrace.REVERSE_WINDOW_REFILL, refill.trigger.request)) {
            if (!refill.inputEos) {
                val inputIndex = current.codec.dequeueInputBuffer(0)
                if (inputIndex >= 0) {
                    val inputBuffer = current.codec.getInputBuffer(inputIndex)
                    if (inputBuffer == null) {
                        invalidateReverseWindow(ReverseWindowFallbackReason.CODEC_ERROR)
                        return@section
                    }
                    val sampleTrack = current.extractor.sampleTrackIndex
                    if (sampleTrack < 0) {
                        current.codec.queueInputBuffer(
                            inputIndex,
                            0,
                            0,
                            0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                        )
                        current.codecInputState.onInputQueued()
                        refill.inputEos = true
                    } else {
                        val size = current.extractor.readSampleData(inputBuffer, 0)
                        if (size < 0) {
                            current.codec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            current.codecInputState.onInputQueued()
                            refill.inputEos = true
                        } else {
                            current.codec.queueInputBuffer(
                                inputIndex,
                                0,
                                size,
                                current.extractor.sampleTime,
                                0,
                            )
                            current.codecInputState.onInputQueued()
                            current.extractor.advance()
                        }
                    }
                    refill.lastProgressAtMs = SystemClock.elapsedRealtime()
                }
            }

            val info = MediaCodec.BufferInfo()
            when (val outputIndex = current.codec.dequeueOutputBuffer(info, 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    applyDecodedOutputFormat(current, prefetch = null)
                    invalidateReverseWindow(ReverseWindowFallbackReason.OUTPUT_FORMAT_CHANGED)
                    return@section
                }
                else -> if (outputIndex >= 0) {
                    diagnostics = diagnostics.copy(decodeOrdinal = diagnostics.decodeOrdinal + 1)
                    val ptsUs = info.presentationTimeUs
                    val duplicateOrdinal = refill.duplicateCounts.getOrDefault(ptsUs, 0)
                    refill.duplicateCounts[ptsUs] = duplicateOrdinal + 1
                    val outputFrame = current.video.frameForOutput(ptsUs, duplicateOrdinal)
                    val newestTargetIndex = refill.plan.decodeTargets.last().key.displayFrameIndex
                    when {
                        outputFrame == null -> current.codec.releaseOutputBuffer(outputIndex, false)
                        outputFrame.key in refill.cachedKeys ->
                            current.codec.releaseOutputBuffer(outputIndex, false)
                        outputFrame.key in refill.plan.publicationTargets.map { it.key } -> {
                            val partialResult = AtomicReference<ReverseWindowPartialAppendResult?>()
                            val ack = cacheReverseWindowOutput(
                                current = current,
                                request = refill.trigger.request,
                                frame = outputFrame,
                                outputIndex = outputIndex,
                                identity = refill.trigger.identity,
                                requireCurrentRequest = false,
                                semanticEpoch = refill.trigger.semanticEpoch,
                                commitReverseWindowKeys = {
                                    CcrTrace.section(
                                        CcrTrace.requestLabel(
                                            CcrTrace.REVERSE_REFILL_APPEND,
                                            refill.trigger.request,
                                        ),
                                    ) {
                                        reverseWindowEngine.stageRefillTarget(
                                            plan = refill.plan,
                                            readyKey = outputFrame.key,
                                            currentIdentity = refill.trigger.identity,
                                        )
                                    }.also(partialResult::set).let { result ->
                                        (result as? ReverseWindowPartialAppendResult.Accepted)
                                            ?.appendedTargets
                                            ?.mapTo(linkedSetOf()) { it.key }
                                    }
                                },
                            )
                            if (ack.status != EglFrameRenderer.AckStatus.CACHED) {
                                val partialFallback = partialResult.get() as? ReverseWindowPartialAppendResult.Fallback
                                cancelReverseRefillPreservingReady(
                                    refill,
                                    partialFallback?.reason ?: if (
                                        ack.status == EglFrameRenderer.AckStatus.STALE
                                    ) ReverseWindowFallbackReason.CANCELLED
                                    else ReverseWindowFallbackReason.CACHE_ADMISSION_FAILED,
                                )
                                return@section
                            }
                            refill.cachedKeys += outputFrame.key
                            refill.generation.recordCachedTarget()
                            refill.lastProgressAtMs = SystemClock.elapsedRealtime()
                            diagnostics = diagnostics.copy(
                                reverseWindowCachedFrameCount = diagnostics.reverseWindowCachedFrameCount + 1,
                                reverseRefillCachedTargetCount = diagnostics.reverseRefillCachedTargetCount + 1,
                            )
                            when (val partial = partialResult.get()) {
                                is ReverseWindowPartialAppendResult.Accepted -> {
                                    diagnostics = diagnostics.copy(
                                        reversePartialAppendCount = reverseWindowEngine.snapshot().partialAppendCount,
                                    )
                                    if (partial.completed) {
                                        completeReverseRefillGeneration(refill)
                                        return@section
                                    }
                                }
                                is ReverseWindowPartialAppendResult.Fallback -> {
                                    cancelReverseRefillPreservingReady(refill, partial.reason)
                                    return@section
                                }
                                null -> {
                                    cancelReverseRefillPreservingReady(
                                        refill,
                                        ReverseWindowFallbackReason.CACHE_ADMISSION_FAILED,
                                    )
                                    return@section
                                }
                            }
                        }
                        outputFrame.key.displayFrameIndex > newestTargetIndex -> {
                            current.codec.releaseOutputBuffer(outputIndex, false)
                            invalidateReverseWindow(ReverseWindowFallbackReason.FRAME_KEY_MISMATCH)
                            return@section
                        }
                        else -> current.codec.releaseOutputBuffer(outputIndex, false)
                    }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0 &&
                        refill.cachedKeys.size != refill.plan.publicationTargets.size
                    ) {
                        cancelReverseRefillPreservingReady(refill, ReverseWindowFallbackReason.WINDOW_BUILD_FAILED)
                        return@section
                    }
                }
            }
        }

        if (reverseRefillWork !== refill) return
        postReverseRefillSlice(REFILL_YIELD_DELAY_MS)
    }

    private fun completeReverseRefillGeneration(refill: ReverseRefillWork) {
        if (reverseRefillWork !== refill || !refill.generation.complete()) return
        val depletedDuringBuild = reverseRefillDepletionTracker.finish(refill.depletionObservation)
        CcrTrace.section(
            CcrTrace.requestLabel(CcrTrace.REVERSE_REFILL_COMPLETE, refill.trigger.request),
        ) { Unit }
        val elapsedUs = (SystemClock.elapsedRealtime() - refill.wallStartedAtMs).coerceAtLeast(0) * 1_000L
        reverseRefillLatencyUs.addLast(elapsedUs)
        while (reverseRefillLatencyUs.size > REFILL_LATENCY_SAMPLE_LIMIT) reverseRefillLatencyUs.removeFirst()
        diagnostics = diagnostics.copy(
            reversePartialAppendCount = reverseWindowEngine.snapshot().partialAppendCount,
            reverseRefillCompletedBeforeDepletionCount =
                diagnostics.reverseRefillCompletedBeforeDepletionCount +
                    if (!depletedDuringBuild) 1 else 0,
            reverseDepletionBeforeRefillCount =
                diagnostics.reverseDepletionBeforeRefillCount +
                    if (depletedDuringBuild) 1 else 0,
        )
        reverseRefillWork = null
        reverseRefillTrigger = null
        reverseRefillActive.set(false)
    }

    private fun cancelReverseRefillPreservingReady(
        refill: ReverseRefillWork,
        reason: ReverseWindowFallbackReason,
    ) {
        if (reverseRefillWork !== refill) return
        reverseRefillDepletionTracker.cancel(refill.depletionObservation)
        CcrTrace.section(
            CcrTrace.requestLabel(CcrTrace.REVERSE_REFILL_CANCEL, refill.trigger.request),
        ) { Unit }
        val committed = reverseWindowEngine.snapshot().remainingTargetKeys.toSet()
        reverseWindowEngine.discardStagedRefill(reason)
        val discard = refill.cachedKeys.filterNot(committed::contains)
        if (discard.isNotEmpty()) renderer.discardReverseWindowKeys(discard)
        if (refill.generation.cancel(reason)) {
            diagnostics = diagnostics.copy(reverseRefillLastCancelledReason = reason.name)
        }
        reverseRefillWork = null
        reverseRefillTrigger = null
        reverseRefillActive.set(false)
    }

    private fun cancelReverseRefillState(
        reason: ReverseWindowFallbackReason = ReverseWindowFallbackReason.CANCELLED,
    ) {
        actor.removeCallbacksAndMessages(reverseRefillMessageToken)
        reverseRefillScheduled = false
        reverseRefillWork?.let { refill ->
            reverseRefillDepletionTracker.cancel(refill.depletionObservation)
            CcrTrace.section(
                CcrTrace.requestLabel(CcrTrace.REVERSE_REFILL_CANCEL, refill.trigger.request),
            ) { Unit }
            reverseWindowEngine.discardStagedRefill(reason)
            refill.cachedKeys.takeIf { it.isNotEmpty() }?.let(renderer::discardReverseWindowKeys)
            if (refill.generation.cancel(reason)) {
                diagnostics = diagnostics.copy(reverseRefillLastCancelledReason = reason.name)
            }
        }
        reverseRefillWork = null
        reverseRefillTrigger = null
        reverseRefillActive.set(false)
    }

    private fun recentReverseRefillP95Us(): Long? {
        if (reverseRefillLatencyUs.isEmpty()) return null
        val sorted = reverseRefillLatencyUs.sorted()
        val rank = kotlin.math.ceil(sorted.size * 0.95).toInt().coerceIn(1, sorted.size)
        return sorted[rank - 1]
    }

    private fun reverseCadenceUs(signedStride: Int): Long = when (signedStride) {
        -1 -> REVERSE_ONE_CADENCE_US
        -5 -> REVERSE_FIVE_CADENCE_US
        else -> error("unsupported reverse stride")
    }

    private fun isReverseRefillSemanticCurrent(
        current: DecoderResources,
        trigger: ReverseRefillTrigger,
    ): Boolean = isReverseWindowIdentityCurrent(current, trigger.identity) &&
        reverseRefillEpochs.isSemanticCurrent(trigger.semanticEpoch)

    private fun isReverseRefillForegroundIdle(trigger: ReverseRefillTrigger): Boolean {
        val current = resources ?: return false
        return isReverseRefillSemanticCurrent(current, trigger) && !latestRequest.hasPending()
    }

    private fun recordReverseWindowRefillStall(startedNanos: Long) {
        val elapsedUs = ((SystemClock.elapsedRealtimeNanos() - startedNanos) / 1_000L).coerceAtLeast(0)
        diagnostics = diagnostics.copy(
            reverseWindowRefillStallCount = diagnostics.reverseWindowRefillStallCount + 1,
            reverseWindowRefillStallMaxUs = maxOf(diagnostics.reverseWindowRefillStallMaxUs, elapsedUs),
            reverseWindowRefillStallOver250MsCount = diagnostics.reverseWindowRefillStallOver250MsCount +
                if (elapsedUs > REFILL_STALL_LIMIT_US) 1 else 0,
            reverseRefillAssociatedGapCount = diagnostics.reverseRefillAssociatedGapCount +
                if (elapsedUs > reverseRefillGapThresholdUs(activeReverseStride.get().toInt())) 1 else 0,
        )
    }

    private fun reverseRefillGapThresholdUs(signedStride: Int): Long = when (signedStride) {
        -1 -> REVERSE_ONE_REFILL_GAP_US
        -5 -> REVERSE_FIVE_REFILL_GAP_US
        else -> Long.MAX_VALUE
    }

    private fun preparePrefetch(
        current: DecoderResources,
        request: FrameRequest,
        target: IndexedFrame,
        startSample: IndexedSample,
        permit: PrefetchPermit?,
    ): PrefetchRunState? {
        cancelPrefetch(activePrefetch)
        if (permit == null || !prefetchGate.isActive(permit) || !isCurrent(request.token)) return null
        val snapshot = renderer.prefetchSnapshot()
        val budget = snapshot.budget
        val adaptiveLimit = adaptivePrefetchDepth.observe(
            PrefetchEfficiencySample(
                completed = diagnostics.prefetchCompleted,
                evictedBeforeUse = snapshot.evictedBeforeUseCount,
                usefulHits = snapshot.cacheHitCount,
            ),
        )
        val effectiveLimit = effectiveDiscretePrefetchLimit(budget.effectivePrefetchLimit, adaptiveLimit)
        updatePrefetchBudget(budget, effectiveLimit)
        val plan = directionalPrefetchPlan(
            direction = permit.direction,
            targetFrameIndex = target.key.displayFrameIndex,
            frameCount = current.video.frameCount,
            frameLimit = effectiveLimit,
        )
        val candidates = plan.frameIndexes
            .filter { frameIndex ->
                plan.direction != DirectionalPrefetchDirection.REVERSE ||
                    current.video.frames[frameIndex].sampleOrdinal >= startSample.sampleOrdinal
            }
        if (candidates.isEmpty()) return null
        val keys = candidates.map { current.video.frames[it].key }
        val cachedKeys = renderer.prefetchSnapshot(keys).cachedFrameKeys
        val missing = candidates.filter { current.video.frames[it].key !in cachedKeys }
        if (missing.isEmpty()) return null
        diagnostics = diagnostics.copy(prefetchRequested = diagnostics.prefetchRequested + missing.size)
        return PrefetchRunState(
            token = request.token,
            permit = permit,
            direction = plan.direction,
            targetFrameIndex = target.key.displayFrameIndex,
            candidates = missing,
        ).also { activePrefetch = it }
    }

    private fun refreshPrefetchLimit(prefetch: PrefetchRunState?) {
        val snapshot = renderer.prefetchSnapshot()
        val budget = snapshot.budget
        val adaptiveLimit = adaptivePrefetchDepth.observe(
            PrefetchEfficiencySample(
                completed = diagnostics.prefetchCompleted,
                evictedBeforeUse = snapshot.evictedBeforeUseCount,
                usefulHits = snapshot.cacheHitCount,
            ),
        )
        val effectiveLimit = effectiveDiscretePrefetchLimit(budget.effectivePrefetchLimit, adaptiveLimit)
        updatePrefetchBudget(budget, effectiveLimit)
        if (prefetch == null) return
        if (!isPrefetchActive(prefetch)) {
            cancelPrefetch(prefetch)
            return
        }
        val cancellation = prefetch.limitTo(effectiveLimit)
        recordPrefetchCancellation(cancellation)
        if (prefetch.isComplete && activePrefetch === prefetch) activePrefetch = null
    }

    private fun updatePrefetchBudget(
        budget: PrefetchBudgetDecision,
        effectiveLimit: Int = budget.effectivePrefetchLimit,
    ) {
        diagnostics = diagnostics.copy(
            effectivePrefetchLimit = effectiveLimit,
            canonicalFrameBytes = budget.canonicalFrameBytes,
            cacheBudgetBytes = budget.cacheBudgetBytes,
        )
    }

    private fun markPrefetchStarted(prefetch: PrefetchRunState, frameIndex: Int): Boolean {
        if (!isPrefetchActive(prefetch)) {
            cancelPrefetch(prefetch)
            return false
        }
        if (prefetch.markStarted(frameIndex)) {
            diagnostics = diagnostics.copy(prefetchStarted = diagnostics.prefetchStarted + 1)
            return true
        }
        return false
    }

    private fun markPrefetchCompleted(prefetch: PrefetchRunState, frameIndex: Int): Boolean {
        if (!isPrefetchActive(prefetch)) {
            cancelPrefetch(prefetch)
            return false
        }
        var completed = false
        if (prefetch.markCompleted(frameIndex)) {
            completed = true
            diagnostics = diagnostics.copy(
                prefetchedFrameCount = diagnostics.prefetchedFrameCount + 1,
                prefetchCompleted = diagnostics.prefetchCompleted + 1,
            )
        }
        if (prefetch.isComplete && activePrefetch === prefetch) activePrefetch = null
        return completed
    }

    private fun cancelPrefetch(prefetch: PrefetchRunState?) {
        if (prefetch == null) return
        recordPrefetchCancellation(prefetch.cancel())
        if (activePrefetch === prefetch) activePrefetch = null
    }

    private fun recordPrefetchCancellation(cancellation: PrefetchCancellation) {
        if (cancellation.cancelled == 0 && cancellation.wasted == 0) return
        prefetchCancellationWaste += cancellation.wasted
        diagnostics = diagnostics.copy(
            prefetchCancelled = diagnostics.prefetchCancelled + cancellation.cancelled,
        )
    }

    private fun cacheDecodedOutput(
        current: DecoderResources,
        request: FrameRequest,
        frame: IndexedFrame,
        outputIndex: Int,
        prefetch: PrefetchRunState,
    ): EglFrameRenderer.RenderAck {
        try {
            beforePrefetchCacheHookForTest?.invoke(request, frame.key)
        } catch (_: Throwable) {
            current.codec.releaseOutputBuffer(outputIndex, false)
            return EglFrameRenderer.RenderAck(EglFrameRenderer.AckStatus.ERROR, 0, "PREFETCH_TEST_HOOK_FAILED")
        }
        if (!isPrefetchActive(prefetch)) {
            current.codec.releaseOutputBuffer(outputIndex, false)
            return EglFrameRenderer.RenderAck(EglFrameRenderer.AckStatus.ERROR, 0, "PREFETCH_NOT_ACTIVE")
        }
        val handle = renderer.queueCacheOnly(
            token = request.token,
            expectedKey = frame.key,
            cacheRetentionAllowed = { prefetchGate.isActive(prefetch.permit) },
        )
        if (handle == null) {
            current.codec.releaseOutputBuffer(outputIndex, false)
            return EglFrameRenderer.RenderAck(EglFrameRenderer.AckStatus.ERROR, 0, "PREFETCH_TARGET_BUSY")
        }
        current.codec.releaseOutputBuffer(outputIndex, true)
        return renderer.awaitCacheTarget(handle, 3_000)
    }

    private fun isPrefetchActive(prefetch: PrefetchRunState): Boolean =
        prefetchGate.isActive(prefetch.permit) && isCurrent(prefetch.token)

    private fun prefetchForward(
        current: DecoderResources,
        request: FrameRequest,
        target: IndexedFrame,
        prefetch: PrefetchRunState,
        duplicateCounts: MutableMap<Long, Int>,
        inputEosAtTarget: Boolean,
    ) {
        if (prefetch.isComplete) return
        var inputEos = inputEosAtTarget
        val info = MediaCodec.BufferInfo()
        val deadline = SystemClock.elapsedRealtime() + 5_000
        while (
            !closed.get() &&
            !prefetch.isComplete &&
            SystemClock.elapsedRealtime() < deadline &&
            isPrefetchActive(prefetch)
        ) {
            if (!inputEos) {
                val inputIndex = current.codec.dequeueInputBuffer(0)
                if (inputIndex >= 0) {
                    val inputBuffer = current.codec.getInputBuffer(inputIndex) ?: run {
                        cancelPrefetch(prefetch)
                        return
                    }
                    val sampleTrack = current.extractor.sampleTrackIndex
                    if (sampleTrack < 0) {
                        current.codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        current.codecInputState.onInputQueued()
                        inputEos = true
                    } else {
                        val size = current.extractor.readSampleData(inputBuffer, 0)
                        if (size < 0) {
                            current.codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            current.codecInputState.onInputQueued()
                            inputEos = true
                        } else {
                            current.codec.queueInputBuffer(inputIndex, 0, size, current.extractor.sampleTime, 0)
                            current.codecInputState.onInputQueued()
                            current.extractor.advance()
                        }
                    }
                }
            }

            when (val outputIndex = current.codec.dequeueOutputBuffer(info, 10_000)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val decoded = runCatching { decodedOutputMetadataFrom(current.codec.outputFormat) }.getOrNull()
                        ?: run {
                            cancelPrefetch(prefetch)
                            return
                        }
                    diagnostics = diagnostics.copy(
                        outputFormatChangeCount = diagnostics.outputFormatChangeCount + 1,
                        decodedOutputFormatHistory = diagnostics.decodedOutputFormatHistory
                            .let { history -> if (history.lastOrNull() == decoded) history else history + decoded },
                    )
                    when (classifyDecodedOutput(current.metadata, decoded)) {
                        VideoSupport.Supported -> {
                            renderer.configureFrame(current.metadata, decoded)
                            refreshPrefetchLimit(prefetch)
                        }
                        is VideoSupport.Unsupported -> {
                            cancelPrefetch(prefetch)
                            return
                        }
                    }
                }
                else -> if (outputIndex >= 0) {
                    diagnostics = diagnostics.copy(decodeOrdinal = diagnostics.decodeOrdinal + 1)
                    val ptsUs = info.presentationTimeUs
                    val duplicateOrdinal = duplicateCounts.getOrDefault(ptsUs, 0)
                    duplicateCounts[ptsUs] = duplicateOrdinal + 1
                    val outputFrame = current.video.frameForOutput(ptsUs, duplicateOrdinal)
                    when {
                        outputFrame == null || outputFrame.key.displayFrameIndex <= target.key.displayFrameIndex -> {
                            current.codec.releaseOutputBuffer(outputIndex, false)
                        }
                        outputFrame.key.displayFrameIndex > (prefetch.furthestFrameIndex ?: target.key.displayFrameIndex) -> {
                            current.codec.releaseOutputBuffer(outputIndex, false)
                            cancelPrefetch(prefetch)
                            return
                        }
                        prefetch.contains(outputFrame.key.displayFrameIndex) -> {
                            if (!markPrefetchStarted(prefetch, outputFrame.key.displayFrameIndex)) {
                                current.codec.releaseOutputBuffer(outputIndex, false)
                                continue
                            }
                            when (cacheDecodedOutput(current, request, outputFrame, outputIndex, prefetch).status) {
                                EglFrameRenderer.AckStatus.CACHED -> {
                                    if (!markPrefetchCompleted(prefetch, outputFrame.key.displayFrameIndex)) {
                                        renderer.discardPrefetched(outputFrame.key)
                                    }
                                }
                                EglFrameRenderer.AckStatus.PUBLISHED,
                                EglFrameRenderer.AckStatus.STALE,
                                EglFrameRenderer.AckStatus.ERROR -> {
                                    cancelPrefetch(prefetch)
                                    return
                                }
                            }
                        }
                        else -> current.codec.releaseOutputBuffer(outputIndex, false)
                    }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        cancelPrefetch(prefetch)
                        return
                    }
                }
            }
        }
        if (!isPrefetchActive(prefetch) || !prefetch.isComplete) {
            cancelPrefetch(prefetch)
        }
    }

    private fun recreateCodec(current: DecoderResources): DecoderResources {
        forwardSequentialState.invalidate()
        invalidateReverseWindow(ReverseWindowFallbackReason.CODEC_ERROR)
        releaseCodec(current.codec)
        val surface = renderer.awaitDecoderSurface(3_000) ?: error("RENDER_SURFACE_NOT_READY")
        current.codec = createCodec(current.codecInfo, current.format, surface)
        current.codecGeneration = ++nextCodecGeneration
        current.outputSurface = surface
        current.codecInputState.onCodecCreated()
        diagnostics = diagnostics.copy(decoderRecreateCount = diagnostics.decoderRecreateCount + 1)
        return current
    }

    private fun createCodec(info: MediaCodecInfo, format: MediaFormat, surface: Surface): MediaCodec =
        MediaCodec.createByCodecName(info.name).apply {
            configure(format, surface, null, 0)
            setOnFrameRenderedListener(
                { _, _, _ ->
                    diagnostics = diagnostics.copy(renderedCallbackCount = diagnostics.renderedCallbackCount + 1)
                },
                actor,
            )
            start()
        }

    private fun selectHardwareDecoder(format: MediaFormat): MediaCodecInfo? {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
        return MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.asSequence()
            .filter { !it.isEncoder && it.isHardwareAccelerated && !it.isSoftwareOnly }
            .filter { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
            .firstOrNull { info ->
                runCatching { info.getCapabilitiesForType(mime).isFormatSupported(format) }.getOrDefault(false)
            }
    }

    private fun classifyAndroidFormat(format: MediaFormat): VideoSupport {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return VideoSupport.Unsupported("MIME_MISSING")
        val profile = format.intOrNull(MediaFormat.KEY_PROFILE)
        val bitDepth = androidVideoBitDepth(mime, profile)
        val transfer = format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER)
        val hdr = transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
            transfer == MediaFormat.COLOR_TRANSFER_HLG ||
            format.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)
        val rotation = ((format.intOrNull(MediaFormat.KEY_ROTATION) ?: 0) % 360 + 360) % 360
        if (rotation !in setOf(0, 90, 180, 270)) return VideoSupport.Unsupported("ROTATION_UNSUPPORTED")
        val parWidth = format.intOrNull("sar-width") ?: 1
        val parHeight = format.intOrNull("sar-height") ?: 1
        if (parWidth <= 0 || parHeight <= 0) return VideoSupport.Unsupported("PIXEL_ASPECT_RATIO_UNSUPPORTED")
        return classifyVideoFormat(
            VideoFormatDescriptor(
                mime = mime,
                profileSupported = isProfileSupported(mime, profile),
                bitDepth = bitDepth,
                hdr = hdr,
                dolbyVision = mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION,
            ),
        )
    }

    private fun isProfileSupported(mime: String, profile: Int?): Boolean = when (mime) {
        MediaFormat.MIMETYPE_VIDEO_AVC -> profile in setOf(
            MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline,
            MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedBaseline,
            MediaCodecInfo.CodecProfileLevel.AVCProfileMain,
            MediaCodecInfo.CodecProfileLevel.AVCProfileExtended,
            MediaCodecInfo.CodecProfileLevel.AVCProfileHigh,
            MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedHigh,
        )
        MediaFormat.MIMETYPE_VIDEO_HEVC -> profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
        else -> false
    }

    private fun metadataFrom(
        format: MediaFormat,
        fileGeneration: Long,
        frameCount: Int,
        codecInfo: MediaCodecInfo,
    ): ContainerMetadata = ContainerMetadata(
        fileGeneration = fileGeneration,
        mime = format.getString(MediaFormat.KEY_MIME) ?: "video/unknown",
        profile = format.intOrNull(MediaFormat.KEY_PROFILE),
        codedWidth = format.getInteger(MediaFormat.KEY_WIDTH),
        codedHeight = format.getInteger(MediaFormat.KEY_HEIGHT),
        cropLeft = cropLeft(format),
        cropTop = cropTop(format),
        cropRight = cropRight(format),
        cropBottom = cropBottom(format),
        rotationDegrees = ((format.intOrNull(MediaFormat.KEY_ROTATION) ?: 0) % 360 + 360) % 360,
        pixelAspectRatioWidth = format.intOrNull("sar-width") ?: 1,
        pixelAspectRatioHeight = format.intOrNull("sar-height") ?: 1,
        durationUs = format.longOrNull(MediaFormat.KEY_DURATION),
        frameCount = frameCount,
        codecComponent = codecInfo.name,
        hardwareAccelerated = codecInfo.isHardwareAccelerated,
    )

    private fun decodedOutputMetadataFrom(format: MediaFormat): DecodedOutputMetadata {
        val width = format.intOrNull(MediaFormat.KEY_WIDTH) ?: error("OUTPUT_FORMAT_UNSUPPORTED")
        val height = format.intOrNull(MediaFormat.KEY_HEIGHT) ?: error("OUTPUT_FORMAT_UNSUPPORTED")
        return DecodedOutputMetadata(
            width = width,
            height = height,
            cropLeft = cropLeft(format),
            cropTop = cropTop(format),
            cropRight = cropRight(format),
            cropBottom = cropBottom(format),
            colorStandard = format.intOrNull(MediaFormat.KEY_COLOR_STANDARD),
            colorRange = format.intOrNull(MediaFormat.KEY_COLOR_RANGE),
            colorTransfer = format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER),
            mime = format.getString(MediaFormat.KEY_MIME),
            profile = format.intOrNull(MediaFormat.KEY_PROFILE),
            colorFormat = format.intOrNull(MediaFormat.KEY_COLOR_FORMAT),
            hdrStaticInfoPresent = runCatching {
                format.getByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO)?.hasRemaining() == true
            }.getOrDefault(false),
        )
    }

    private fun classifyDecodedOutput(
        container: ContainerMetadata,
        output: DecodedOutputMetadata,
    ): VideoSupport {
        val mime = container.mime
        val profile = if (output.mime == container.mime) output.profile ?: container.profile else container.profile
        val bitDepth = androidDecodedVideoBitDepth(mime, profile, output.colorFormat)
        val hdr = androidDecodedOutputIsHdr(output.colorTransfer, output.hdrStaticInfoPresent)
        return classifyDecodedOutputFormat(
            output,
            VideoFormatDescriptor(
                mime = mime,
                profileSupported = isProfileSupported(mime, profile),
                bitDepth = bitDepth,
                hdr = hdr,
                dolbyVision = mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION,
            ),
        )
    }

    private fun closeResources() {
        forwardSequentialState.invalidate()
        activeReverseGestureGeneration.set(NO_GESTURE)
        activeReverseStride.set(NO_REVERSE_STRIDE)
        reverseRefillEpochs.invalidateSemantic()
        cancelReverseRefillState(ReverseWindowFallbackReason.FILE_GENERATION_CHANGED)
        reverseWindowEngine.invalidate(ReverseWindowFallbackReason.FILE_GENERATION_CHANGED)
        currentVideo.set(null)
        resources?.let {
            releaseCodec(it.codec)
            it.extractor.release()
            it.descriptor.close()
        }
        resources = null
    }

    private fun invalidateForSurfaceLoss() {
        if (closed.get()) return
        suspendPrefetch()
        forwardSequentialState.invalidate()
        activeReverseGestureGeneration.set(NO_GESTURE)
        activeReverseStride.set(NO_REVERSE_STRIDE)
        reverseRefillEpochs.invalidateSemantic()
        cancelReverseRefillState(ReverseWindowFallbackReason.SURFACE_GENERATION_CHANGED)
        reverseWindowEngine.invalidate(ReverseWindowFallbackReason.SURFACE_GENERATION_CHANGED)
        publicationGate.invalidateRequest()
        activeCachedNavigationToken.set(null)
        latestRequest.clear()
        actor.removeCallbacksAndMessages(requestMessageToken)
    }

    private fun releaseCodec(codec: MediaCodec) {
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    private fun report(result: FrameResult) {
        val nextDiagnostics = buildDiagnosticsSnapshot()
        diagnostics = nextDiagnostics
        mainHandler.post { listener.onFrameResult(result, nextDiagnostics) }
    }

    private fun reportCachedNavigation(
        result: FrameResult,
        prefetch: EglFrameRenderer.PrefetchSnapshot? = null,
    ) {
        val nextDiagnostics = if (prefetch == null) {
            diagnosticsWithConcurrentCounters(diagnostics)
        } else {
            buildDiagnosticsSnapshot(prefetch)
        }
        mainHandler.post { listener.onFrameResult(result, nextDiagnostics) }
    }

    private fun buildDiagnosticsSnapshot(
        prefetchOverride: EglFrameRenderer.PrefetchSnapshot? = null,
    ): DecoderDiagnostics {
        publicationGate.trySnapshotStats()?.let { lastPublicationStats = it }
        publicationGate.tryRecentEvents()?.let { lastPublicationEvents = it }
        val prefetch = prefetchOverride ?: renderer.prefetchSnapshot()
        val reverseWindow = reverseWindowEngine.snapshot()
        return diagnosticsWithConcurrentCounters(diagnostics).copy(
            cacheBytes = prefetch.cacheBytes,
            peakCacheBytes = prefetch.peakCacheBytes,
            cacheHitCount = prefetch.cacheRequestHitCount,
            cacheMissCount = prefetch.cacheRequestMissCount,
            publishedSwapCount = lastPublicationStats.publishedSwapCount,
            staleBeforeSwapCount = lastPublicationStats.staleBeforeSwapCount,
            swapFailureCount = lastPublicationStats.swapFailureCount,
            surfaceInvalidCount = lastPublicationStats.surfaceInvalidCount,
            publicationInvariantViolationCount = lastPublicationStats.publicationInvariantViolationCount,
            fullFrameReadbackCount = prefetch.fullFrameReadbackCount,
            publicationEventHistory = lastPublicationEvents,
            prefetchCacheHit = prefetch.cacheHitCount,
            prefetchEvictedBeforeUse = prefetch.evictedBeforeUseCount,
            prefetchWasted = prefetchCancellationWaste + prefetch.wastedCount,
            currentPrefetchDepth = prefetch.currentDepth,
            canonicalFrameBytes = prefetch.budget.canonicalFrameBytes,
            cacheBudgetBytes = prefetch.budget.cacheBudgetBytes,
            cacheEntryCount = prefetch.cacheEntryCount,
            peakCacheEntryCount = prefetch.peakCacheEntryCount,
            cacheEvictionCount = prefetch.cacheEvictionCount,
            cacheRejectionCount = prefetch.cacheRejectionCount,
            cacheThrashCount = prefetch.cacheThrashCount,
            textureCreatedCount = prefetch.textureCreatedCount,
            textureReleasedCount = prefetch.textureReleasedCount,
            liveTextureCount = prefetch.liveTextureCount,
            peakLiveTextureCount = prefetch.peakLiveTextureCount,
            textureDoubleReleaseCount = prefetch.textureDoubleReleaseCount,
            protectedTextureCount = prefetch.protectedTextureCount,
            backwardHistoryCapacity = prefetch.backwardHistoryCapacity,
            backwardHistoryDepth = prefetch.backwardHistoryDepth,
            backwardHistoryHitCount = prefetch.backwardHistoryHitCount,
            reverseWindowReadyCount = reverseWindow.readyWindowCount,
            reverseWindowRemainingTargetCount = reverseWindow.remainingTargetCount,
            reverseWindowStagedTargetCount = reverseWindow.stagedTargetCount,
            reverseWindowStagedReadyCount = reverseWindow.stagedReadyCount,
            reverseWindowHitCount = prefetch.reverseWindowHitCount,
            reverseWindowRefillCount = reverseWindow.refillCount,
            reverseWindowInitialReadyCount = reverseWindow.initialWindowReadyCount,
            reverseWindowRollingAppendRefillCount = reverseWindow.rollingAppendRefillCount,
            reverseWindowRefillNeeded = reverseWindow.refillNeeded,
            reverseWindowConsumedCount = reverseWindow.consumedCount,
            reverseWindowInvalidationCount = reverseWindow.invalidationCount,
            reversePartialAppendCount = reverseWindow.partialAppendCount,
            requestCoalescedCount = requestCoalescedCount.get(),
            actorQueueDepth = if (latestRequest.hasPending()) 1 else 0,
        )
    }

    private fun diagnosticsWithConcurrentCounters(base: DecoderDiagnostics): DecoderDiagnostics = base.copy(
        cachedNavigationAttemptCount = cachedNavigationAttemptCount.get(),
        cachedNavigationActorBypassCount = cachedNavigationActorBypassCount.get(),
        cachedNavigationMissFallbackCount = cachedNavigationMissFallbackCount.get(),
        cachedNavigationStaleCount = cachedNavigationStaleCount.get(),
        cachedNavigationErrorCount = cachedNavigationErrorCount.get(),
        cachedNavigationQueueWaitMaxUs = cachedNavigationQueueWaitMaxUs.get(),
        reverseRefillInProgress = reverseRefillActive.get(),
    )

    private fun isCurrent(token: GenerationToken): Boolean =
        !closed.get() && publicationGate.tryIsCurrent(token) == true

    private fun notifyStatus(fileGeneration: Long?, status: String, detail: String? = null) {
        mainHandler.post { listener.onStatus(fileGeneration, status, detail) }
    }

    private fun notifyOpened(metadata: ContainerMetadata, video: IndexedVideo) {
        mainHandler.post {
            listener.onVideoIndexed(video)
            listener.onVideoOpened(metadata)
        }
    }

    private fun sanitizeError(error: Throwable): String {
        val allowed = setOf(
            "SOURCE_OPEN_FAILED",
            "VIDEO_TRACK_NOT_FOUND",
            "VIDEO_HAS_NO_FRAMES",
            "HARDWARE_DECODER_REQUIRED",
            "RENDER_SURFACE_NOT_READY",
            "DOLBY_VISION_UNSUPPORTED",
            "CODEC_UNSUPPORTED",
            "PROFILE_OR_BIT_DEPTH_UNSUPPORTED",
            "HDR_UNSUPPORTED",
            "MIME_MISSING",
            "ROTATION_UNSUPPORTED",
            "PIXEL_ASPECT_RATIO_UNSUPPORTED",
            "OUTPUT_FORMAT_UNSUPPORTED",
        )
        return error.message?.takeIf(allowed::contains) ?: "VIDEO_OPEN_FAILED"
    }

    private fun MediaFormat.intOrNull(key: String): Int? =
        if (containsKey(key)) runCatching { getInteger(key) }.getOrNull() else null

    private fun MediaFormat.longOrNull(key: String): Long? =
        if (containsKey(key)) runCatching { getLong(key) }.getOrNull() else null

    private fun cropLeft(format: MediaFormat): Int = format.intOrNull(MediaFormat.KEY_CROP_LEFT) ?: 0
    private fun cropTop(format: MediaFormat): Int = format.intOrNull(MediaFormat.KEY_CROP_TOP) ?: 0
    private fun cropRight(format: MediaFormat): Int =
        format.intOrNull(MediaFormat.KEY_CROP_RIGHT) ?: (format.getInteger(MediaFormat.KEY_WIDTH) - 1)
    private fun cropBottom(format: MediaFormat): Int =
        format.intOrNull(MediaFormat.KEY_CROP_BOTTOM) ?: (format.getInteger(MediaFormat.KEY_HEIGHT) - 1)

    companion object {
        private const val NO_GESTURE = Long.MIN_VALUE
        private const val NO_REVERSE_STRIDE = Long.MIN_VALUE
        private const val FOREGROUND_INPUT_BATCH_SIZE = 8
        private const val FOREGROUND_OUTPUT_BATCH_SIZE = 8
        private const val REFILL_BATCH_TARGETS = 2
        private const val REFILL_YIELD_DELAY_MS = 1L
        private const val REFILL_TIMEOUT_MS = 5_000L
        private const val REFILL_STALL_LIMIT_US = 250_000L
        private const val REFILL_LATENCY_SAMPLE_LIMIT = 32
        private const val REVERSE_ONE_CADENCE_US = 66_667L
        private const val REVERSE_FIVE_CADENCE_US = 83_333L
        private const val REVERSE_ONE_REFILL_GAP_US = 100_000L
        private const val REVERSE_FIVE_REFILL_GAP_US = 125_000L
        private const val REVERSE_BUILD_TEST_BARRIER_TIMEOUT_MS = 10_000L
        private val UNSUPPORTED_CODES = setOf(
            "DOLBY_VISION_UNSUPPORTED",
            "CODEC_UNSUPPORTED",
            "PROFILE_OR_BIT_DEPTH_UNSUPPORTED",
            "HDR_UNSUPPORTED",
            "ROTATION_UNSUPPORTED",
            "PIXEL_ASPECT_RATIO_UNSUPPORTED",
            "HARDWARE_DECODER_REQUIRED",
            "OUTPUT_FORMAT_UNSUPPORTED",
        )
    }
}
