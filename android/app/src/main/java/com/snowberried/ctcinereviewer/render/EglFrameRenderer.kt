package com.snowberried.ctcinereviewer.render

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.snowberried.ctcinereviewer.cache.DirectionalByteCache
import com.snowberried.ctcinereviewer.media.BackwardHistoryRing
import com.snowberried.ctcinereviewer.media.CachedNavigationCompletion
import com.snowberried.ctcinereviewer.media.CachedNavigationContextCheck
import com.snowberried.ctcinereviewer.media.CachedNavigationInput
import com.snowberried.ctcinereviewer.media.CachedNavigationMissReason
import com.snowberried.ctcinereviewer.media.CachedNavigationOutcome
import com.snowberried.ctcinereviewer.media.CachedNavigationPendingRegistry
import com.snowberried.ctcinereviewer.media.CachedNavigationSource
import com.snowberried.ctcinereviewer.media.CcrTrace
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecodedOutputMetadata
import com.snowberried.ctcinereviewer.media.DirectionalPrefetchDirection
import com.snowberried.ctcinereviewer.media.FrameImageProbe
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameRequest
import com.snowberried.ctcinereviewer.media.GenerationToken
import com.snowberried.ctcinereviewer.media.PublicationEvent
import com.snowberried.ctcinereviewer.media.PublicationGate
import com.snowberried.ctcinereviewer.media.PublicationResult
import com.snowberried.ctcinereviewer.media.PrefetchBudgetDecision
import com.snowberried.ctcinereviewer.media.canonicalFrameBytes
import com.snowberried.ctcinereviewer.media.prefetchBudgetDecision
import com.snowberried.ctcinereviewer.media.rendererCacheByteBudget
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

internal class TextureLifetimeTracker {
    private val liveAllocations = mutableSetOf<Long>()

    var createdCount: Long = 0
        private set
    var releasedCount: Long = 0
        private set
    var peakLiveCount: Int = 0
        private set
    var doubleReleaseCount: Long = 0
        private set

    val liveCount: Int get() = liveAllocations.size

    fun onCreated(allocationId: Long) {
        check(liveAllocations.add(allocationId)) { "duplicate texture allocation: $allocationId" }
        createdCount += 1
        peakLiveCount = maxOf(peakLiveCount, liveAllocations.size)
    }

    fun onReleased(allocationId: Long): Boolean {
        if (!liveAllocations.remove(allocationId)) {
            doubleReleaseCount += 1
            return false
        }
        releasedCount += 1
        return true
    }
}

class EglFrameRenderer(
    private val publicationGate: PublicationGate,
    private val onDecoderSurfaceChanged: (Boolean) -> Unit,
    renderMode: FrameRenderMode,
) : AutoCloseable {
    enum class AckStatus { PUBLISHED, CACHED, STALE, ERROR }
    enum class CacheTargetKind { PREFETCH, REVERSE_WINDOW }

    data class RenderAck(
        val status: AckStatus,
        val textureTimestampNs: Long,
        val code: String? = null,
        val cacheHit: Boolean = false,
        val imageProbe: FrameImageProbe? = null,
    )

    internal data class PrefetchSnapshot(
        val budget: PrefetchBudgetDecision,
        val cachedFrameKeys: Set<FrameKey>,
        val cacheHitCount: Long,
        val evictedBeforeUseCount: Long,
        val wastedCount: Long,
        val currentDepth: Int,
        val cacheEntryCount: Int,
        val peakCacheEntryCount: Int,
        val cacheEvictionCount: Long,
        val cacheRejectionCount: Long,
        val cacheThrashCount: Long,
        val cacheBytes: Long,
        val peakCacheBytes: Long,
        val cacheRequestHitCount: Long,
        val cacheRequestMissCount: Long,
        val textureCreatedCount: Long,
        val textureReleasedCount: Long,
        val liveTextureCount: Int,
        val peakLiveTextureCount: Int,
        val textureDoubleReleaseCount: Long,
        val fullFrameReadbackCount: Long,
        val protectedTextureCount: Int,
        val backwardHistoryCapacity: Int,
        val backwardHistoryDepth: Int,
        val backwardHistoryKeys: Set<FrameKey>,
        val backwardHistoryHitCount: Long,
        val reverseWindowReadyCount: Int,
        val reverseWindowKeys: Set<FrameKey>,
        val reverseWindowHitCount: Long,
        val lastPublishedKey: FrameKey?,
    )

    class TargetHandle internal constructor(val request: FrameRequest) {
        private val latch = CountDownLatch(1)
        private val result = AtomicReference<RenderAck?>()

        internal fun complete(ack: RenderAck) {
            if (result.compareAndSet(null, ack)) latch.countDown()
        }

        fun await(timeoutMs: Long): RenderAck =
            if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                result.get() ?: RenderAck(AckStatus.ERROR, 0, "RENDER_ACK_MISSING")
            } else {
                RenderAck(AckStatus.ERROR, 0, "RENDER_TIMEOUT")
            }

        internal fun completedResult(): RenderAck? = result.get()
    }

    class CacheTargetHandle internal constructor(
        val token: GenerationToken,
        val expectedKey: FrameKey,
    ) {
        private val latch = CountDownLatch(1)
        private val result = AtomicReference<RenderAck?>()

        internal fun complete(ack: RenderAck) {
            if (result.compareAndSet(null, ack)) latch.countDown()
        }

        fun await(timeoutMs: Long): RenderAck =
            if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                result.get() ?: RenderAck(AckStatus.ERROR, 0, "CACHE_ACK_MISSING")
            } else {
                RenderAck(AckStatus.ERROR, 0, "CACHE_TIMEOUT")
            }

        internal fun completedResult(): RenderAck? = result.get()
    }

    private data class PendingTarget(
        val owner: Any,
        val token: GenerationToken,
        val expectedKey: FrameKey,
        val publicationRequest: FrameRequest?,
        val cacheRetentionAllowed: (() -> Boolean)?,
        val cacheTargetKind: CacheTargetKind?,
        val cacheMaximumByteSize: Long?,
        val commitReverseWindowKeys: (() -> Set<FrameKey>?)?,
        val requireCurrentRequest: Boolean,
        val complete: (RenderAck) -> Unit,
    )

    private data class CachedTexture(
        val allocationId: Long,
        val textureId: Int,
        val width: Int,
        val height: Int,
        val timestampNs: Long,
        val imageProbe: FrameImageProbe?,
    )

    private val thread = HandlerThread("ccr-egl-render").apply { start() }
    private val handler = Handler(thread.looper)
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val decoderSurfaceMonitor = java.lang.Object()
    @Volatile private var decoderSurface: Surface? = null
    @Volatile private var closed = false
    @Volatile private var terminalFailure = false

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowSurface: Surface? = null
    private var config: EGLConfig? = null
    private var surfaceTexture: SurfaceTexture? = null
    private var inputSourceEpoch = 0L
    private var oesTextureId = 0
    private var oesProgram = 0
    private var textureProgram = 0
    private var vertexArray = 0
    private var vertexBuffer = 0
    private var windowWidth = 1
    private var windowHeight = 1
    private var sourceWidth = 1
    private var sourceHeight = 1
    private var canonicalGeometry = CanonicalGeometry(1, 1, 1, 1, 0)
    private var fileGeneration = 0L
    private var pendingTarget: PendingTarget? = null
    private var lastPublishedKey: FrameKey? = null
    private val prefetchedKeys = mutableSetOf<FrameKey>()
    private val reverseWindowKeys = mutableSetOf<FrameKey>()
    private val stagedReverseWindowKeys = mutableSetOf<FrameKey>()
    private var prefetchCacheHitCount = 0L
    private var prefetchEvictedBeforeUseCount = 0L
    private var prefetchWastedCount = 0L
    private var prefetchRejectedCount = 0L
    private var backwardHistoryHitCount = 0L
    private var reverseWindowHitCount = 0L
    private var nextTextureAllocationId = 0L
    private val textureLifetimeTracker = TextureLifetimeTracker()
    private val probePolicy = FrameProbePolicy(renderMode)
    private val surfaceLeases = SurfaceLeaseTracker()

    private val byteBudget = rendererCacheByteBudget(Runtime.getRuntime().maxMemory())
    private val backwardHistory = BackwardHistoryRing(byteBudget)
    private val cachedNavigationCommands = CachedNavigationPendingRegistry()
    private val cache = DirectionalByteCache<FrameKey, CachedTexture>(
        byteBudget = byteBudget,
        frameIndex = { it.displayFrameIndex },
        onEvict = { key, texture ->
            CcrTrace.section(CcrTrace.frameLabel(CcrTrace.CACHE_EVICT, fileGeneration, key)) {
                releaseCachedTexture(texture)
            }
            if (prefetchedKeys.remove(key)) {
                prefetchEvictedBeforeUseCount += 1
                prefetchWastedCount += 1
            }
            backwardHistory.remove(key)
            reverseWindowKeys.remove(key)
            stagedReverseWindowKeys.remove(key)
            if (lastPublishedKey == key) lastPublishedKey = null
        },
    )

    fun attachWindow(surfaceLeaseId: Long, surface: Surface, width: Int, height: Int) {
        if (unavailable()) return
        handler.post {
            if (unavailable()) return@post
            if (!surfaceLeases.attach(surfaceLeaseId)) return@post
            releaseGl()
            try {
                initializeGl(surface, width, height)
            } catch (error: Throwable) {
                Log.e(TAG, "EGL window initialization failed", error)
                releaseGl()
            }
        }
    }

    fun resize(surfaceLeaseId: Long, width: Int, height: Int) {
        if (unavailable()) return
        handler.post {
            if (unavailable()) return@post
            if (!surfaceLeases.isActive(surfaceLeaseId)) return@post
            windowWidth = width.coerceAtLeast(1)
            windowHeight = height.coerceAtLeast(1)
        }
    }

    fun detachWindow(surfaceLeaseId: Long) {
        if (unavailable()) return
        handler.post {
            if (unavailable()) return@post
            if (!surfaceLeases.detach(surfaceLeaseId)) return@post
            releaseGl()
        }
    }

    fun awaitDecoderSurface(timeoutMs: Long): Surface? {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        synchronized(decoderSurfaceMonitor) {
            while (!unavailable() && decoderSurface == null) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) break
                TimeUnit.NANOSECONDS.timedWait(decoderSurfaceMonitor, remaining)
            }
            return decoderSurface
        }
    }

    fun beginFile(nextFileGeneration: Long): Boolean {
        if (unavailable()) return false
        return callOnRenderer(1_000, false) {
            if (unavailable() || display == EGL14.EGL_NO_DISPLAY) return@callOnRenderer false
            completeCachedNavigationCommands("FILE_CHANGED")
            fileGeneration = nextFileGeneration
            probePolicy.reset()
            pendingTarget?.complete?.invoke(RenderAck(AckStatus.STALE, 0, "FILE_CHANGED"))
            pendingTarget = null
            cache.clear()
            backwardHistory.reset()
            rebindDecoderInputSurface()
            lastPublishedKey = null
            prefetchedKeys.clear()
            reverseWindowKeys.clear()
            stagedReverseWindowKeys.clear()
            prefetchCacheHitCount = 0
            prefetchEvictedBeforeUseCount = 0
            prefetchWastedCount = 0
            prefetchRejectedCount = 0
            backwardHistoryHitCount = 0
            reverseWindowHitCount = 0
            true
        }
    }

    fun configureFrame(
        container: ContainerMetadata,
        decoded: DecodedOutputMetadata? = null,
    ) {
        if (unavailable()) return
        val latch = CountDownLatch(1)
        handler.post {
            if (unavailable()) {
                latch.countDown()
                return@post
            }
            val nextSourceWidth = (decoded?.width ?: container.codedWidth).coerceAtLeast(1)
            val nextSourceHeight = (decoded?.height ?: container.codedHeight).coerceAtLeast(1)
            val nextGeometry = CanonicalGeometry.fromInclusiveCrop(
                cropLeft = decoded?.cropLeft ?: container.cropLeft,
                cropTop = decoded?.cropTop ?: container.cropTop,
                cropRight = decoded?.cropRight ?: container.cropRight,
                cropBottom = decoded?.cropBottom ?: container.cropBottom,
                pixelAspectRatioWidth = container.pixelAspectRatioWidth,
                pixelAspectRatioHeight = container.pixelAspectRatioHeight,
                rotationDegrees = container.rotationDegrees,
            )
            if (nextSourceWidth != sourceWidth || nextSourceHeight != sourceHeight || nextGeometry != canonicalGeometry) {
                if (display != EGL14.EGL_NO_DISPLAY) cache.clear()
                backwardHistory.reset()
                lastPublishedKey = null
                sourceWidth = nextSourceWidth
                sourceHeight = nextSourceHeight
                canonicalGeometry = nextGeometry
            }
            surfaceTexture?.setDefaultBufferSize(sourceWidth, sourceHeight)
            latch.countDown()
        }
        latch.await(1, TimeUnit.SECONDS)
    }

    fun presentCached(request: FrameRequest): RenderAck? {
        if (unavailable()) return RenderAck(AckStatus.STALE, 0, "RENDERER_CLOSED")
        return callOnRenderer<RenderAck?>(
            timeoutMs = 2_000,
            fallback = RenderAck(AckStatus.ERROR, 0, "CACHE_RENDER_TIMEOUT"),
        ) {
            if (unavailable()) return@callOnRenderer RenderAck(AckStatus.STALE, 0, "RENDERER_CLOSED")
            if (request.token.fileGeneration != fileGeneration || display == EGL14.EGL_NO_DISPLAY) {
                return@callOnRenderer RenderAck(AckStatus.STALE, 0, "CACHE_GENERATION_STALE")
            }
            cache.recordRequest(request.requestedFrameIndex)
            val backwardHistoryHit = backwardHistory.contains(request.expectedKey)
            val prefetched = request.expectedKey in prefetchedKeys
            val reverseWindow = request.expectedKey in reverseWindowKeys
            val cached = cache.get(request.expectedKey) ?: return@callOnRenderer null
            CcrTrace.section(CcrTrace.requestLabel(CcrTrace.DRAW, request)) {
                drawTextureToWindow(cached)
            }
            val event = publish(request, cached.timestampNs)
            if (event.result == PublicationResult.PUBLISHED) {
                if (backwardHistoryHit) backwardHistoryHitCount += 1
                if (prefetched && prefetchedKeys.remove(request.expectedKey)) prefetchCacheHitCount += 1
                if (reverseWindow && reverseWindowKeys.remove(request.expectedKey)) reverseWindowHitCount += 1
                recordPublished(request.expectedKey)
            }
            renderAckFor(
                event,
                cacheHit = true,
                imageProbe = cached.imageProbe,
            )
        }
    }

    /**
     * Probes and publishes an exact cached reverse-navigation texture without waiting on the
     * caller. Every cache and EGL operation runs on the renderer thread. A miss is intentionally
     * distinct from stale/error so the caller can fall back with the same accepted FrameRequest.
     */
    internal fun enqueueCachedNavigation(
        input: CachedNavigationInput,
        contextCurrent: CachedNavigationContextCheck,
        completion: CachedNavigationCompletion,
    ): Boolean {
        val ticket = cachedNavigationCommands.register(input, completion)
        if (unavailable()) {
            completeCachedNavigation(
                ticket,
                CachedNavigationOutcome.Stale(input, "RENDERER_CLOSED"),
            )
            return true
        }
        val posted = runCatching {
            handler.post {
                CcrTrace.section(
                    CcrTrace.requestLabel(CcrTrace.CACHED_NAVIGATION_START, input.request),
                ) {
                    executeCachedNavigation(ticket, contextCurrent)
                }
            }
        }.getOrDefault(false)
        if (!posted) {
            completeCachedNavigation(
                ticket,
                CachedNavigationOutcome.Error(input, "CACHE_NAVIGATION_QUEUE_REJECTED"),
            )
        }
        return true
    }

    private fun executeCachedNavigation(
        ticket: CachedNavigationPendingRegistry.Ticket,
        contextCurrent: CachedNavigationContextCheck,
    ) {
        if (!cachedNavigationCommands.isPending(ticket)) return
        val input = ticket.input
        val request = input.request
        try {
            if (unavailable()) {
                completeCachedNavigation(ticket, CachedNavigationOutcome.Stale(input, "RENDERER_CLOSED"))
                return
            }
            if (request.token.fileGeneration != fileGeneration || display == EGL14.EGL_NO_DISPLAY) {
                completeCachedNavigation(ticket, CachedNavigationOutcome.Stale(input, "CACHE_GENERATION_STALE"))
                return
            }
            if (!contextIsCurrent(input, contextCurrent) || !publicationGate.isCurrent(request.token)) {
                completeCachedNavigation(ticket, CachedNavigationOutcome.Stale(input, "CONTEXT_GENERATION_STALE"))
                return
            }

            val key = request.expectedKey
            val backwardHistoryHit = backwardHistory.contains(key)
            val prefetched = key in prefetchedKeys
            val reverseWindowHit = key in reverseWindowKeys
            val source = when {
                reverseWindowHit -> CachedNavigationSource.REVERSE_WINDOW
                backwardHistoryHit -> CachedNavigationSource.BACKWARD_HISTORY
                else -> null
            }
            if (source == null || source !in input.allowedSources) {
                val reason = if (cache.containsKey(key)) {
                    CachedNavigationMissReason.SOURCE_NOT_ALLOWED
                } else {
                    CachedNavigationMissReason.NOT_CACHED
                }
                completeCachedNavigation(ticket, CachedNavigationOutcome.Miss(input, reason))
                return
            }

            cache.recordRequest(request.requestedFrameIndex, explicitDirection = -1)
            val cached = cache.get(key)
            if (cached == null) {
                completeCachedNavigation(
                    ticket,
                    CachedNavigationOutcome.Miss(input, CachedNavigationMissReason.NOT_CACHED),
                )
                return
            }
            val expectedTimestampNs = runCatching { Math.multiplyExact(key.ptsUs, 1_000L) }.getOrNull()
            if (expectedTimestampNs == null || cached.timestampNs != expectedTimestampNs) {
                cache.remove(key)
                completeCachedNavigation(
                    ticket,
                    CachedNavigationOutcome.Miss(input, CachedNavigationMissReason.FRAME_KEY_MISMATCH),
                )
                return
            }

            CcrTrace.section(CcrTrace.requestLabel(CcrTrace.DRAW, request)) {
                drawTextureToWindow(cached)
            }
            val event = publish(request, cached.timestampNs) {
                contextIsCurrent(input, contextCurrent)
            }
            when (event.result) {
                PublicationResult.PUBLISHED -> {
                    if (backwardHistoryHit) backwardHistoryHitCount += 1
                    if (prefetched && prefetchedKeys.remove(key)) prefetchCacheHitCount += 1
                    if (reverseWindowHit && reverseWindowKeys.remove(key)) reverseWindowHitCount += 1
                    recordPublished(key)
                    completeCachedNavigation(
                        ticket,
                        CachedNavigationOutcome.Published(input, event, source, cached.imageProbe),
                    )
                }
                PublicationResult.STALE_BEFORE_SWAP -> completeCachedNavigation(
                    ticket,
                    CachedNavigationOutcome.Stale(input, "STALE_BEFORE_SWAP", event),
                )
                PublicationResult.SURFACE_INVALID -> {
                    val outcome = if (!contextIsCurrent(input, contextCurrent)) {
                        CachedNavigationOutcome.Stale(input, "CONTEXT_GENERATION_STALE", event)
                    } else {
                        CachedNavigationOutcome.Error(input, "SURFACE_INVALID", event)
                    }
                    completeCachedNavigation(ticket, outcome)
                }
                PublicationResult.SWAP_FAILED -> completeCachedNavigation(
                    ticket,
                    CachedNavigationOutcome.Error(input, "EGL_SWAP_FAILED", event),
                )
            }
        } catch (_: Throwable) {
            completeCachedNavigation(
                ticket,
                CachedNavigationOutcome.Error(input, "CACHE_NAVIGATION_FAILED"),
            )
        }
    }

    private fun contextIsCurrent(
        input: CachedNavigationInput,
        contextCurrent: CachedNavigationContextCheck,
    ): Boolean = runCatching { contextCurrent(input) }.getOrDefault(false)

    private fun completeCachedNavigation(
        ticket: CachedNavigationPendingRegistry.Ticket,
        outcome: CachedNavigationOutcome,
    ) {
        cachedNavigationCommands.complete(ticket, outcome)
    }

    private fun completeCachedNavigationCommands(code: String) {
        cachedNavigationCommands.completeAll { input -> CachedNavigationOutcome.Stale(input, code) }
    }

    fun queueTarget(request: FrameRequest): TargetHandle? {
        if (unavailable()) return null
        return callOnRenderer<TargetHandle?>(2_000, null) {
            if (unavailable()) return@callOnRenderer null
            if (pendingTarget == null && display != EGL14.EGL_NO_DISPLAY && request.token.fileGeneration == fileGeneration) {
                TargetHandle(request).also {
                    pendingTarget = PendingTarget(
                        owner = it,
                        token = request.token,
                        expectedKey = request.expectedKey,
                        publicationRequest = request,
                        cacheRetentionAllowed = null,
                        cacheTargetKind = null,
                        cacheMaximumByteSize = null,
                        commitReverseWindowKeys = null,
                        requireCurrentRequest = true,
                        complete = it::complete,
                    )
                    cache.recordRequest(request.requestedFrameIndex)
                }
            } else {
                null
            }
        }
    }

    fun queueCacheOnly(
        token: GenerationToken,
        expectedKey: FrameKey,
        cacheRetentionAllowed: () -> Boolean,
        kind: CacheTargetKind = CacheTargetKind.PREFETCH,
        maximumByteSize: Long? = null,
        commitReverseWindowKeys: (() -> Set<FrameKey>?)? = null,
        requireCurrentRequest: Boolean = true,
    ): CacheTargetHandle? {
        if (unavailable()) return null
        return callOnRenderer<CacheTargetHandle?>(2_000, null) {
            if (unavailable()) return@callOnRenderer null
            if (
                pendingTarget == null &&
                display != EGL14.EGL_NO_DISPLAY &&
                token.fileGeneration == fileGeneration &&
                (!requireCurrentRequest || publicationGate.isCurrent(token))
            ) {
                CacheTargetHandle(token, expectedKey).also {
                    pendingTarget = PendingTarget(
                        owner = it,
                        token = token,
                        expectedKey = expectedKey,
                        publicationRequest = null,
                        cacheRetentionAllowed = cacheRetentionAllowed,
                        cacheTargetKind = kind,
                        cacheMaximumByteSize = maximumByteSize,
                        commitReverseWindowKeys = commitReverseWindowKeys,
                        requireCurrentRequest = requireCurrentRequest,
                        complete = it::complete,
                    )
                }
            } else {
                null
            }
        }
    }

    fun cacheByteSize(): Long = cache.byteSize
    fun cacheHits(): Long = cache.hitCount
    fun cacheMisses(): Long = cache.missCount
    fun fullFrameReadbacks(): Long = probePolicy.readbackCount()

    internal fun recordForegroundRequest(
        frameIndex: Int,
        direction: DirectionalPrefetchDirection?,
    ) {
        if (unavailable()) return
        callOnRenderer(1_000, Unit) {
            cache.recordRequest(
                index = frameIndex,
                explicitDirection = when (direction) {
                    DirectionalPrefetchDirection.FORWARD -> 1
                    DirectionalPrefetchDirection.REVERSE -> -1
                    null -> null
                },
            )
        }
    }

    fun discardPrefetched(key: FrameKey): Boolean = callOnRenderer(1_000, false) {
        if (key !in prefetchedKeys) return@callOnRenderer false
        cache.remove(key)
    }

    fun invalidateReverseWindow(preserveCachedKey: FrameKey? = null): Int = callOnRenderer(1_000, 0) {
        val keys = (reverseWindowKeys + stagedReverseWindowKeys).toList()
        keys.filterNot { it == preserveCachedKey }.forEach(cache::remove)
        reverseWindowKeys.clear()
        stagedReverseWindowKeys.clear()
        keys.count { it != preserveCachedKey }
    }

    fun discardReverseWindowKeys(keys: Collection<FrameKey>): Int = callOnRenderer(1_000, 0) {
        keys.count { key ->
            reverseWindowKeys.remove(key)
            stagedReverseWindowKeys.remove(key)
            cache.remove(key)
        }
    }

    fun preemptReverseWindowCacheTarget() {
        if (unavailable()) return
        handler.post {
            val pending = pendingTarget
            if (
                pending?.publicationRequest == null &&
                pending?.cacheTargetKind == CacheTargetKind.REVERSE_WINDOW
            ) {
                pendingTarget = null
                pending.complete(RenderAck(AckStatus.STALE, 0, "FOREGROUND_PREEMPTED"))
            }
        }
    }

    fun awaitTarget(handle: TargetHandle, timeoutMs: Long): RenderAck {
        val waited = handle.await(timeoutMs)
        if (waited.code != "RENDER_TIMEOUT") return waited
        handle.completedResult()?.let { return it }
        publicationGate.tryInvalidateIfCurrent(handle.request.token)
        cancelPendingTarget(handle, "RENDER_TIMEOUT")
        return handle.completedResult() ?: waited
    }

    fun awaitCacheTarget(
        handle: CacheTargetHandle,
        timeoutMs: Long,
        invalidateRequestOnTimeout: Boolean = true,
    ): RenderAck {
        val waited = handle.await(timeoutMs)
        if (waited.code != "CACHE_TIMEOUT") return waited
        handle.completedResult()?.let { return it }
        if (invalidateRequestOnTimeout) publicationGate.tryInvalidateIfCurrent(handle.token)
        cancelPendingTarget(handle, "CACHE_TIMEOUT")
        return handle.completedResult() ?: waited
    }

    private fun cancelPendingTarget(owner: Any, code: String) {
        callOnRenderer(1_000, false) {
            val pending = pendingTarget
            if (pending?.owner === owner) {
                pendingTarget = null
                pending.complete(RenderAck(AckStatus.STALE, 0, code))
            }
            true
        }
    }

    fun cancelImmediately() {
        terminalFailure = true
        completeCachedNavigationCommands("RENDERER_CANCELLED")
        synchronized(decoderSurfaceMonitor) { decoderSurfaceMonitor.notifyAll() }
    }

    internal fun prefetchSnapshot(frameKeys: Collection<FrameKey> = emptyList()): PrefetchSnapshot {
        if (unavailable()) return emptyPrefetchSnapshot()
        val latch = CountDownLatch(1)
        val result = AtomicReference<PrefetchSnapshot?>()
        handler.post {
            if (unavailable()) {
                latch.countDown()
                return@post
            }
            result.set(prefetchSnapshotOnRenderer(frameKeys))
            latch.countDown()
        }
        return if (latch.await(2, TimeUnit.SECONDS)) {
            result.get() ?: emptyPrefetchSnapshot()
        } else {
            emptyPrefetchSnapshot()
        }
    }

    /** Used only by a cached-navigation completion already running on the EGL thread. */
    internal fun cachedNavigationSnapshot(): PrefetchSnapshot {
        check(android.os.Looper.myLooper() == thread.looper) { "cached navigation snapshot must run on EGL thread" }
        return if (unavailable()) emptyPrefetchSnapshot() else prefetchSnapshotOnRenderer(emptyList())
    }

    private fun prefetchSnapshotOnRenderer(frameKeys: Collection<FrameKey>): PrefetchSnapshot =
        backwardHistory.snapshot().let { history ->
            PrefetchSnapshot(
                budget = prefetchBudgetDecision(
                    width = canonicalGeometry.width,
                    height = canonicalGeometry.height,
                    cacheBudgetBytes = byteBudget,
                ),
                cachedFrameKeys = frameKeys.filterTo(mutableSetOf(), cache::containsKey),
                cacheHitCount = prefetchCacheHitCount,
                evictedBeforeUseCount = prefetchEvictedBeforeUseCount,
                wastedCount = prefetchWastedCount,
                currentDepth = prefetchedKeys.size,
                cacheEntryCount = cache.size,
                peakCacheEntryCount = cache.peakSize,
                cacheEvictionCount = cache.evictionCount,
                cacheRejectionCount = cache.rejectionCount,
                cacheThrashCount = prefetchEvictedBeforeUseCount + prefetchRejectedCount,
                cacheBytes = cache.byteSize,
                peakCacheBytes = cache.peakByteSize,
                cacheRequestHitCount = cache.hitCount,
                cacheRequestMissCount = cache.missCount,
                textureCreatedCount = textureLifetimeTracker.createdCount,
                textureReleasedCount = textureLifetimeTracker.releasedCount,
                liveTextureCount = textureLifetimeTracker.liveCount,
                peakLiveTextureCount = textureLifetimeTracker.peakLiveCount,
                textureDoubleReleaseCount = textureLifetimeTracker.doubleReleaseCount,
                fullFrameReadbackCount = probePolicy.readbackCount(),
                protectedTextureCount = protectedCacheKeys().count(cache::containsKey),
                backwardHistoryCapacity = history.capacity,
                backwardHistoryDepth = history.depth,
                backwardHistoryKeys = history.keys.toSet(),
                backwardHistoryHitCount = backwardHistoryHitCount,
                reverseWindowReadyCount = if (reverseWindowKeys.isEmpty()) 0 else 1,
                reverseWindowKeys = reverseWindowKeys.toSet(),
                reverseWindowHitCount = reverseWindowHitCount,
                lastPublishedKey = lastPublishedKey,
            )
        }

    fun trimCache(level: Int) {
        if (unavailable()) return
        handler.post {
            if (unavailable()) return@post
            val targetBytes = cacheTargetBytes(level, byteBudget)
            cache.trimToBytes(targetBytes, protectedCacheKeys())
            backwardHistory.configure(
                canonicalFrameBytes = backwardHistory.snapshot().frameBytes,
                availableBudgetBytes = targetBytes,
            )
        }
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        completeCachedNavigationCommands("RENDERER_CLOSED")
        synchronized(decoderSurfaceMonitor) { decoderSurfaceMonitor.notifyAll() }
        handler.removeCallbacksAndMessages(null)
        handler.postAtFrontOfQueue {
            pendingTarget?.complete?.invoke(RenderAck(AckStatus.STALE, 0, "RENDERER_CLOSED"))
            pendingTarget = null
            releaseGl()
            thread.quitSafely()
        }
    }

    private fun initializeGl(surface: Surface, width: Int, height: Int) {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY)
        check(EGL14.eglInitialize(display, IntArray(2), 0, IntArray(2), 0))

        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE,
        )
        check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] == 1)
        config = configs[0]
        context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE),
            0,
        )
        check(context != EGL14.EGL_NO_CONTEXT)
        eglWindowSurface = EGL14.eglCreateWindowSurface(
            display,
            config,
            surface,
            intArrayOf(EGL14.EGL_NONE),
            0,
        )
        check(eglWindowSurface != EGL14.EGL_NO_SURFACE)
        windowSurface = surface
        check(EGL14.eglMakeCurrent(display, eglWindowSurface, eglWindowSurface, context))

        windowWidth = width.coerceAtLeast(1)
        windowHeight = height.coerceAtLeast(1)
        createGeometry()
        oesProgram = createProgram(VERTEX_SHADER, OES_FRAGMENT_SHADER)
        textureProgram = createProgram(VERTEX_SHADER, TEXTURE_FRAGMENT_SHADER)

        createDecoderInputSurface()
        onDecoderSurfaceChanged(true)
    }

    private fun onFrameAvailable(source: SurfaceTexture, sourceEpoch: Long) {
        if (source !== surfaceTexture || sourceEpoch != inputSourceEpoch) return
        if (unavailable()) {
            pendingTarget?.complete?.invoke(RenderAck(AckStatus.STALE, 0, "RENDERER_CANCELLED"))
            pendingTarget = null
            return
        }
        try {
            CcrTrace.section(
                pendingTarget?.let { CcrTrace.frameLabel(CcrTrace.TEXTURE_UPDATE, it.token, it.expectedKey) }
                    ?: CcrTrace.TEXTURE_UPDATE,
            ) {
                source.updateTexImage()
            }
        } catch (_: Throwable) {
            pendingTarget?.complete?.invoke(RenderAck(AckStatus.ERROR, 0, "TEXTURE_UPDATE_FAILED"))
            pendingTarget = null
            return
        }
        val handle = pendingTarget ?: return
        pendingTarget = null
        val timestampNs = source.timestamp
        val expectedTimestampNs = handle.expectedKey.ptsUs * 1_000L
        if (timestampNs != expectedTimestampNs) {
            handle.complete(RenderAck(AckStatus.ERROR, timestampNs, "TEXTURE_TIMESTAMP_MISMATCH"))
            return
        }
        if (
            handle.token.fileGeneration != fileGeneration ||
            (handle.requireCurrentRequest && !publicationGate.isCurrent(handle.token))
        ) {
            handle.complete(RenderAck(AckStatus.STALE, timestampNs, "TEXTURE_GENERATION_STALE"))
            return
        }

        val expectedFrameBytes = canonicalFrameBytes(canonicalGeometry.width, canonicalGeometry.height)
        val residentTargetBytes = residentCacheTargetBytes(byteBudget, expectedFrameBytes)
        if (
            expectedFrameBytes <= 0 ||
            !cache.trimToBytes(residentTargetBytes, protectedCacheKeys())
        ) {
            handle.complete(RenderAck(AckStatus.ERROR, timestampNs, "IN_FLIGHT_CACHE_BUDGET_EXCEEDED"))
            return
        }
        backwardHistory.configure(expectedFrameBytes)

        val textureMatrix = FloatArray(16)
        source.getTransformMatrix(textureMatrix)
        val cached = try {
            CcrTrace.section(CcrTrace.frameLabel(CcrTrace.TEXTURE_COPY, handle.token, handle.expectedKey)) {
                CcrTrace.section(CcrTrace.frameLabel(CcrTrace.CANONICAL_COPY, handle.token, handle.expectedKey)) {
                    copyExternalTexture(textureMatrix, canonicalGeometry.rotationDegrees, timestampNs)
                }
            }
        } catch (_: Throwable) {
            handle.complete(RenderAck(AckStatus.ERROR, timestampNs, "TEXTURE_COPY_FAILED"))
            return
        }
        if (unavailable()) {
            releaseCachedTexture(cached)
            handle.complete(RenderAck(AckStatus.STALE, timestampNs, "RENDERER_CANCELLED"))
            return
        }
        val prefetchBudget = prefetchBudgetDecision(cached.width, cached.height, byteBudget)
        val frameBytes = prefetchBudget.canonicalFrameBytes
        check(frameBytes == expectedFrameBytes)
        val retentionAllowed = handle.publicationRequest != null || handle.cacheRetentionAllowed?.invoke() == true
        var cacheAdmissionAttempted = false
        val retained = retentionAllowed && frameBytes > 0 && CcrTrace.section(
            CcrTrace.frameLabel(CcrTrace.CACHE_PUT, handle.token, handle.expectedKey),
        ) {
            val put = {
                cacheAdmissionAttempted = true
                cache.put(
                    key = handle.expectedKey,
                    value = cached,
                    bytes = frameBytes,
                    protectedKeys = protectedCacheKeys(),
                    maximumByteSize = handle.cacheMaximumByteSize ?: if (handle.publicationRequest == null) {
                        prefetchBudget.availablePrefetchBytes + frameBytes
                    } else {
                        byteBudget
                    },
                )
            }
            if (handle.requireCurrentRequest) {
                publicationGate.runIfCurrent(handle.token, put) == true
            } else {
                handle.token.fileGeneration == fileGeneration && handle.cacheRetentionAllowed?.invoke() == true && put()
            }
        }
        val committedReverseWindowKeys = if (
            retained && handle.cacheTargetKind == CacheTargetKind.REVERSE_WINDOW &&
            handle.commitReverseWindowKeys != null
        ) {
            runCatching(handle.commitReverseWindowKeys).getOrNull()
        } else {
            null
        }
        val cacheCommitAccepted = retained && (
            handle.cacheTargetKind != CacheTargetKind.REVERSE_WINDOW ||
                handle.commitReverseWindowKeys == null ||
                committedReverseWindowKeys != null
            )
        completeCachedTextureTarget(
            publicationRequest = handle.publicationRequest,
            onCacheOnly = {
                if (cacheCommitAccepted) {
                    when (handle.cacheTargetKind) {
                        CacheTargetKind.PREFETCH -> prefetchedKeys += handle.expectedKey
                        CacheTargetKind.REVERSE_WINDOW -> {
                            val exposed = committedReverseWindowKeys ?: setOf(handle.expectedKey)
                            if (handle.commitReverseWindowKeys != null) {
                                stagedReverseWindowKeys += handle.expectedKey
                                stagedReverseWindowKeys.removeAll(exposed)
                            }
                            reverseWindowKeys += exposed
                        }
                        null -> Unit
                    }
                    handle.complete(RenderAck(AckStatus.CACHED, timestampNs, imageProbe = cached.imageProbe))
                } else {
                    if (cacheAdmissionAttempted) prefetchRejectedCount += 1
                    if (retained) cache.remove(handle.expectedKey) else releaseCachedTexture(cached)
                    handle.complete(
                        RenderAck(
                            AckStatus.ERROR,
                            timestampNs,
                            when {
                                retained -> "REVERSE_WINDOW_COMMIT_REJECTED"
                                retentionAllowed -> "PREFETCH_NOT_RETAINED"
                                else -> "PREFETCH_NOT_ACTIVE"
                            },
                        ),
                    )
                }
            },
            onPublish = { publicationRequest ->
                CcrTrace.section(CcrTrace.requestLabel(CcrTrace.DRAW, publicationRequest)) {
                    drawTextureToWindow(cached)
                }
                val event = publish(publicationRequest, timestampNs)
                if (event.result == PublicationResult.PUBLISHED) recordPublished(handle.expectedKey)
                handle.complete(renderAckFor(event, imageProbe = cached.imageProbe))
                if (!retained) releaseCachedTexture(cached)
            },
        )
    }

    private fun publish(
        request: FrameRequest,
        textureTimestampNs: Long,
        contextCurrent: () -> Boolean = { true },
    ): PublicationEvent =
        CcrTrace.section(CcrTrace.requestLabel(CcrTrace.PUBLISH, request)) {
            publicationGate.publish(
                request = request,
                textureTimestampNs = textureTimestampNs,
                surfaceValid = {
                    contextCurrent() &&
                        !unavailable() &&
                        display != EGL14.EGL_NO_DISPLAY &&
                        eglWindowSurface != EGL14.EGL_NO_SURFACE &&
                        windowSurface?.isValid == true
                },
                swap = { EGL14.eglSwapBuffers(display, eglWindowSurface) },
            )
        }

    private fun renderAckFor(
        event: PublicationEvent,
        cacheHit: Boolean = false,
        imageProbe: FrameImageProbe? = null,
    ): RenderAck = when (event.result) {
        PublicationResult.PUBLISHED -> RenderAck(
            AckStatus.PUBLISHED,
            event.textureTimestampNs,
            cacheHit = cacheHit,
            imageProbe = imageProbe,
        )
        PublicationResult.STALE_BEFORE_SWAP -> RenderAck(
            AckStatus.STALE,
            event.textureTimestampNs,
            "STALE_BEFORE_SWAP",
            cacheHit = cacheHit,
            imageProbe = imageProbe,
        )
        PublicationResult.SWAP_FAILED -> RenderAck(
            AckStatus.ERROR,
            event.textureTimestampNs,
            "EGL_SWAP_FAILED",
            cacheHit = cacheHit,
            imageProbe = imageProbe,
        )
        PublicationResult.SURFACE_INVALID -> RenderAck(
            AckStatus.ERROR,
            event.textureTimestampNs,
            "SURFACE_INVALID",
            cacheHit = cacheHit,
            imageProbe = imageProbe,
        )
    }

    private fun copyExternalTexture(
        textureMatrix: FloatArray,
        rotationDegrees: Int,
        timestampNs: Long,
    ): CachedTexture {
        val outputWidth = canonicalGeometry.width
        val outputHeight = canonicalGeometry.height
        val textures = IntArray(1)
        GLES30.glGenTextures(1, textures, 0)
        val textureId = textures[0]
        check(textureId != 0)
        val cached = trackCachedTexture(textureId, outputWidth, outputHeight, timestampNs)
        val framebuffers = IntArray(1)
        try {
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, textureId)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
            GLES30.glTexImage2D(
                GLES30.GL_TEXTURE_2D,
                0,
                GLES30.GL_RGBA8,
                outputWidth,
                outputHeight,
                0,
                GLES30.GL_RGBA,
                GLES30.GL_UNSIGNED_BYTE,
                null,
            )

            GLES30.glGenFramebuffers(1, framebuffers, 0)
            check(framebuffers[0] != 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffers[0])
            GLES30.glFramebufferTexture2D(
                GLES30.GL_FRAMEBUFFER,
                GLES30.GL_COLOR_ATTACHMENT0,
                GLES30.GL_TEXTURE_2D,
                textureId,
                0,
            )
            check(GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) == GLES30.GL_FRAMEBUFFER_COMPLETE)
            GLES30.glViewport(0, 0, outputWidth, outputHeight)
            GLES30.glClearColor(0f, 0f, 0f, 1f)
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
            draw(oesProgram, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId, textureMatrix, 1f, 1f, rotationDegrees)
            val imageProbe = probePolicy.capture { readbackProbe(outputWidth, outputHeight) }
            return cached.copy(imageProbe = imageProbe)
        } catch (error: Throwable) {
            releaseCachedTexture(cached)
            throw error
        } finally {
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            if (framebuffers[0] != 0) GLES30.glDeleteFramebuffers(1, framebuffers, 0)
        }
    }

    private fun trackCachedTexture(
        textureId: Int,
        width: Int,
        height: Int,
        timestampNs: Long,
    ): CachedTexture {
        nextTextureAllocationId += 1
        val texture = CachedTexture(
            allocationId = nextTextureAllocationId,
            textureId = textureId,
            width = width,
            height = height,
            timestampNs = timestampNs,
            imageProbe = null,
        )
        textureLifetimeTracker.onCreated(texture.allocationId)
        return texture
    }

    private fun releaseCachedTexture(texture: CachedTexture) {
        if (!textureLifetimeTracker.onReleased(texture.allocationId)) return
        GLES30.glDeleteTextures(1, intArrayOf(texture.textureId), 0)
    }

    private fun readbackProbe(outputWidth: Int, outputHeight: Int): FrameImageProbe {
        val rgba = ByteBuffer.allocateDirect(outputWidth * outputHeight * 4)
        GLES30.glReadPixels(
            0,
            0,
            outputWidth,
            outputHeight,
            GLES30.GL_RGBA,
            GLES30.GL_UNSIGNED_BYTE,
            rgba,
        )
        rgba.rewind()
        val bytes = ByteArray(rgba.remaining())
        rgba.get(bytes)
        return FrameProbe.fromRgbaBottomUp(bytes, outputWidth, outputHeight, canonicalGeometry)
    }

    private fun drawTextureToWindow(texture: CachedTexture) {
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, windowWidth, windowHeight)
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        val frameAspect = texture.width.toFloat() / texture.height.toFloat()
        val windowAspect = windowWidth.toFloat() / windowHeight.toFloat()
        val scaleX: Float
        val scaleY: Float
        if (frameAspect > windowAspect) {
            scaleX = 1f
            scaleY = windowAspect / frameAspect
        } else {
            scaleX = frameAspect / windowAspect
            scaleY = 1f
        }
        draw(textureProgram, GLES30.GL_TEXTURE_2D, texture.textureId, IDENTITY_MATRIX, scaleX, scaleY, 0)
    }

    private fun draw(
        program: Int,
        target: Int,
        textureId: Int,
        matrix: FloatArray,
        scaleX: Float,
        scaleY: Float,
        rotationDegrees: Int,
    ) {
        GLES30.glUseProgram(program)
        GLES30.glBindVertexArray(vertexArray)
        GLES30.glUniformMatrix4fv(GLES30.glGetUniformLocation(program, "uTextureMatrix"), 1, false, matrix, 0)
        GLES30.glUniform2f(GLES30.glGetUniformLocation(program, "uScale"), scaleX, scaleY)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uRotationDegrees"), rotationDegrees)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(target, textureId)
        GLES30.glUniform1i(GLES30.glGetUniformLocation(program, "uTexture"), 0)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)
        GLES30.glBindVertexArray(0)
    }

    private fun createGeometry() {
        val data = floatArrayOf(
            -1f, -1f, 0f, 0f,
            1f, -1f, 1f, 0f,
            -1f, 1f, 0f, 1f,
            1f, 1f, 1f, 1f,
        )
        val buffer = ByteBuffer.allocateDirect(data.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(data)
            position(0)
        }
        val arrays = IntArray(1)
        val buffers = IntArray(1)
        GLES30.glGenVertexArrays(1, arrays, 0)
        GLES30.glGenBuffers(1, buffers, 0)
        vertexArray = arrays[0]
        vertexBuffer = buffers[0]
        GLES30.glBindVertexArray(vertexArray)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vertexBuffer)
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, data.size * 4, buffer, GLES30.GL_STATIC_DRAW)
        GLES30.glEnableVertexAttribArray(0)
        GLES30.glVertexAttribPointer(0, 2, GLES30.GL_FLOAT, false, 16, 0)
        GLES30.glEnableVertexAttribArray(1)
        GLES30.glVertexAttribPointer(1, 2, GLES30.GL_FLOAT, false, 16, 8)
        GLES30.glBindVertexArray(0)
    }

    private fun rebindDecoderInputSurface() {
        releaseDecoderInputSurface()
        createDecoderInputSurface()
    }

    private fun createDecoderInputSurface() {
        val texture = IntArray(1)
        GLES30.glGenTextures(1, texture, 0)
        oesTextureId = texture[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        val epoch = ++inputSourceEpoch
        val textureSource = SurfaceTexture(oesTextureId).apply {
            setDefaultBufferSize(sourceWidth, sourceHeight)
        }
        textureSource.setOnFrameAvailableListener(
            { onFrameAvailable(textureSource, epoch) },
            handler,
        )
        surfaceTexture = textureSource
        synchronized(decoderSurfaceMonitor) {
            decoderSurface = Surface(textureSource)
            decoderSurfaceMonitor.notifyAll()
        }
    }

    private fun releaseDecoderInputSurface() {
        inputSourceEpoch += 1
        surfaceTexture?.setOnFrameAvailableListener(null)
        synchronized(decoderSurfaceMonitor) {
            decoderSurface?.release()
            decoderSurface = null
            decoderSurfaceMonitor.notifyAll()
        }
        surfaceTexture?.release()
        surfaceTexture = null
        if (display != EGL14.EGL_NO_DISPLAY && oesTextureId != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
        }
        oesTextureId = 0
    }

    private fun createProgram(vertexSource: String, fragmentSource: String): Int {
        fun compile(type: Int, source: String): Int {
            val shader = GLES30.glCreateShader(type)
            GLES30.glShaderSource(shader, source)
            GLES30.glCompileShader(shader)
            val status = IntArray(1)
            GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
            check(status[0] == GLES30.GL_TRUE) { GLES30.glGetShaderInfoLog(shader) }
            return shader
        }

        val vertex = compile(GLES30.GL_VERTEX_SHADER, vertexSource)
        val fragment = compile(GLES30.GL_FRAGMENT_SHADER, fragmentSource)
        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vertex)
        GLES30.glAttachShader(program, fragment)
        GLES30.glLinkProgram(program)
        val status = IntArray(1)
        GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
        GLES30.glDeleteShader(vertex)
        GLES30.glDeleteShader(fragment)
        check(status[0] == GLES30.GL_TRUE) { GLES30.glGetProgramInfoLog(program) }
        return program
    }

    private fun releaseGl() {
        completeCachedNavigationCommands("SURFACE_RELEASED")
        pendingTarget?.complete?.invoke(RenderAck(AckStatus.ERROR, 0, "SURFACE_RELEASED"))
        pendingTarget = null
        if (display != EGL14.EGL_NO_DISPLAY) {
            runCatching { EGL14.eglMakeCurrent(display, eglWindowSurface, eglWindowSurface, context) }
            cache.clear()
            backwardHistory.reset()
            lastPublishedKey = null
            if (oesProgram != 0) GLES30.glDeleteProgram(oesProgram)
            if (textureProgram != 0) GLES30.glDeleteProgram(textureProgram)
            if (vertexBuffer != 0) GLES30.glDeleteBuffers(1, intArrayOf(vertexBuffer), 0)
            if (vertexArray != 0) GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
        }
        releaseDecoderInputSurface()
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglWindowSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglWindowSurface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
        display = EGL14.EGL_NO_DISPLAY
        context = EGL14.EGL_NO_CONTEXT
        eglWindowSurface = EGL14.EGL_NO_SURFACE
        windowSurface = null
        config = null
        oesTextureId = 0
        oesProgram = 0
        textureProgram = 0
        vertexArray = 0
        vertexBuffer = 0
        onDecoderSurfaceChanged(false)
    }

    private fun <T> callOnRenderer(timeoutMs: Long, fallback: T, block: () -> T): T {
        if (unavailable()) return fallback
        val state = AtomicInteger(COMMAND_PENDING)
        val result = AtomicReference(fallback)
        val latch = CountDownLatch(1)
        val posted = handler.post {
            if (!state.compareAndSet(COMMAND_PENDING, COMMAND_RUNNING)) {
                latch.countDown()
                return@post
            }
            try {
                result.set(block())
            } catch (_: Throwable) {
                result.set(fallback)
            } finally {
                state.set(COMMAND_COMPLETE)
                latch.countDown()
            }
        }
        if (!posted) return fallback
        if (latch.await(timeoutMs, TimeUnit.MILLISECONDS)) return result.get()
        if (state.compareAndSet(COMMAND_PENDING, COMMAND_CANCELLED)) return fallback
        if (latch.await(COMMAND_RUNNING_GRACE_MS, TimeUnit.MILLISECONDS)) return result.get()
        terminalFailure = true
        publicationGate.tryInvalidateRequest()
        synchronized(decoderSurfaceMonitor) { decoderSurfaceMonitor.notifyAll() }
        return fallback
    }

    private fun unavailable(): Boolean = closed || terminalFailure

    private fun emptyPrefetchSnapshot(): PrefetchSnapshot = backwardHistory.snapshot().let { history ->
        PrefetchSnapshot(
            budget = prefetchBudgetDecision(0, 0, byteBudget),
            cachedFrameKeys = emptySet(),
            cacheHitCount = prefetchCacheHitCount,
            evictedBeforeUseCount = prefetchEvictedBeforeUseCount,
            wastedCount = prefetchWastedCount,
            currentDepth = prefetchedKeys.size,
            cacheEntryCount = cache.size,
            peakCacheEntryCount = cache.peakSize,
            cacheEvictionCount = cache.evictionCount,
            cacheRejectionCount = cache.rejectionCount,
            cacheThrashCount = prefetchEvictedBeforeUseCount + prefetchRejectedCount,
            cacheBytes = cache.byteSize,
            peakCacheBytes = cache.peakByteSize,
            cacheRequestHitCount = cache.hitCount,
            cacheRequestMissCount = cache.missCount,
            textureCreatedCount = textureLifetimeTracker.createdCount,
            textureReleasedCount = textureLifetimeTracker.releasedCount,
            liveTextureCount = textureLifetimeTracker.liveCount,
            peakLiveTextureCount = textureLifetimeTracker.peakLiveCount,
            textureDoubleReleaseCount = textureLifetimeTracker.doubleReleaseCount,
            fullFrameReadbackCount = probePolicy.readbackCount(),
            protectedTextureCount = protectedCacheKeys().count(cache::containsKey),
            backwardHistoryCapacity = history.capacity,
            backwardHistoryDepth = history.depth,
            backwardHistoryKeys = history.keys.toSet(),
            backwardHistoryHitCount = backwardHistoryHitCount,
            reverseWindowReadyCount = if (reverseWindowKeys.isEmpty()) 0 else 1,
            reverseWindowKeys = reverseWindowKeys.toSet(),
            reverseWindowHitCount = reverseWindowHitCount,
            lastPublishedKey = lastPublishedKey,
        )
    }

    private fun protectedCacheKeys(): Set<FrameKey> = buildSet {
        lastPublishedKey?.let(::add)
        pendingTarget?.expectedKey?.let(::add)
        addAll(reverseWindowKeys)
        addAll(stagedReverseWindowKeys)
    }

    private fun recordPublished(key: FrameKey) {
        val previous = lastPublishedKey?.takeIf(cache::containsKey)
        backwardHistory.recordPublished(previous, key)
        lastPublishedKey = key
    }

    companion object {
        private const val COMMAND_PENDING = 0
        private const val COMMAND_RUNNING = 1
        private const val COMMAND_CANCELLED = 2
        private const val COMMAND_COMPLETE = 3
        private const val COMMAND_RUNNING_GRACE_MS = 2_000L
        private const val TAG = "CcrEglRenderer"
        private val IDENTITY_MATRIX = floatArrayOf(
            1f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f,
            0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f,
        )

        private const val VERTEX_SHADER = """
            #version 300 es
            layout(location = 0) in vec2 aPosition;
            layout(location = 1) in vec2 aTextureCoordinate;
            uniform mat4 uTextureMatrix;
            uniform vec2 uScale;
            uniform int uRotationDegrees;
            out vec2 vTextureCoordinate;
            vec2 inverseClockwiseRotation(vec2 uv) {
              if (uRotationDegrees == 90) return vec2(1.0 - uv.y, uv.x);
              if (uRotationDegrees == 180) return vec2(1.0 - uv.x, 1.0 - uv.y);
              if (uRotationDegrees == 270) return vec2(uv.y, 1.0 - uv.x);
              return uv;
            }
            void main() {
              gl_Position = vec4(aPosition * uScale, 0.0, 1.0);
              vec2 sourceCoordinate = inverseClockwiseRotation(aTextureCoordinate);
              vTextureCoordinate = (uTextureMatrix * vec4(sourceCoordinate, 0.0, 1.0)).xy;
            }
        """

        private const val OES_FRAGMENT_SHADER = """
            #version 300 es
            #extension GL_OES_EGL_image_external_essl3 : require
            precision mediump float;
            uniform samplerExternalOES uTexture;
            in vec2 vTextureCoordinate;
            out vec4 color;
            void main() { color = texture(uTexture, vTextureCoordinate); }
        """

        private const val TEXTURE_FRAGMENT_SHADER = """
            #version 300 es
            precision mediump float;
            uniform sampler2D uTexture;
            in vec2 vTextureCoordinate;
            out vec4 color;
            void main() { color = texture(uTexture, vTextureCoordinate); }
        """
    }
}

internal fun completeCachedTextureTarget(
    publicationRequest: FrameRequest?,
    onCacheOnly: () -> Unit,
    onPublish: (FrameRequest) -> Unit,
) {
    if (publicationRequest == null) onCacheOnly() else onPublish(publicationRequest)
}

internal fun cacheTargetBytes(level: Int, byteBudget: Long): Long = when {
    level >= 15 -> 0L
    level >= 10 -> byteBudget / 2L
    level >= 5 -> byteBudget * 3L / 4L
    else -> byteBudget
}

internal fun residentCacheTargetBytes(byteBudget: Long, incomingFrameBytes: Long): Long {
    require(byteBudget >= 0)
    require(incomingFrameBytes >= 0)
    return (byteBudget - incomingFrameBytes).coerceAtLeast(0)
}
