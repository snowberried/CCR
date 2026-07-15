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
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecodedOutputMetadata
import com.snowberried.ctcinereviewer.media.FrameImageProbe
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameRequest
import com.snowberried.ctcinereviewer.media.GenerationToken
import com.snowberried.ctcinereviewer.media.PublicationEvent
import com.snowberried.ctcinereviewer.media.PublicationGate
import com.snowberried.ctcinereviewer.media.PublicationResult
import com.snowberried.ctcinereviewer.media.PrefetchBudgetDecision
import com.snowberried.ctcinereviewer.media.prefetchBudgetDecision
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min

class EglFrameRenderer(
    private val publicationGate: PublicationGate,
    private val onDecoderSurfaceChanged: (Boolean) -> Unit,
    renderMode: FrameRenderMode,
) : AutoCloseable {
    enum class AckStatus { PUBLISHED, CACHED, STALE, ERROR }

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
    }

    private data class PendingTarget(
        val token: GenerationToken,
        val expectedKey: FrameKey,
        val publicationRequest: FrameRequest?,
        val complete: (RenderAck) -> Unit,
    )

    private data class CachedTexture(
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

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowSurface: Surface? = null
    private var config: EGLConfig? = null
    private var surfaceTexture: SurfaceTexture? = null
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
    private var prefetchCacheHitCount = 0L
    private var prefetchEvictedBeforeUseCount = 0L
    private var prefetchWastedCount = 0L
    private val probePolicy = FrameProbePolicy(renderMode)
    private val surfaceLeases = SurfaceLeaseTracker()

    private val byteBudget = min(128L * 1024L * 1024L, Runtime.getRuntime().maxMemory() / 4L)
    private val cache = DirectionalByteCache<FrameKey, CachedTexture>(
        byteBudget = byteBudget,
        frameIndex = { it.displayFrameIndex },
        onEvict = { key, texture ->
            GLES30.glDeleteTextures(1, intArrayOf(texture.textureId), 0)
            if (prefetchedKeys.remove(key)) {
                prefetchEvictedBeforeUseCount += 1
                prefetchWastedCount += 1
            }
            if (lastPublishedKey == key) lastPublishedKey = null
        },
    )

    fun attachWindow(surfaceLeaseId: Long, surface: Surface, width: Int, height: Int) {
        if (closed) return
        handler.post {
            if (closed) return@post
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
        if (closed) return
        handler.post {
            if (closed) return@post
            if (!surfaceLeases.isActive(surfaceLeaseId)) return@post
            windowWidth = width.coerceAtLeast(1)
            windowHeight = height.coerceAtLeast(1)
        }
    }

    fun detachWindow(surfaceLeaseId: Long) {
        if (closed) return
        handler.post {
            if (closed) return@post
            if (!surfaceLeases.detach(surfaceLeaseId)) return@post
            releaseGl()
        }
    }

    fun awaitDecoderSurface(timeoutMs: Long): Surface? {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        synchronized(decoderSurfaceMonitor) {
            while (!closed && decoderSurface == null) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) break
                TimeUnit.NANOSECONDS.timedWait(decoderSurfaceMonitor, remaining)
            }
            return decoderSurface
        }
    }

    fun beginFile(nextFileGeneration: Long) {
        if (closed) return
        val latch = CountDownLatch(1)
        handler.post {
            if (closed) {
                latch.countDown()
                return@post
            }
            fileGeneration = nextFileGeneration
            probePolicy.reset()
            pendingTarget?.complete?.invoke(RenderAck(AckStatus.STALE, 0, "FILE_CHANGED"))
            pendingTarget = null
            if (display != EGL14.EGL_NO_DISPLAY) cache.clear()
            lastPublishedKey = null
            prefetchedKeys.clear()
            prefetchCacheHitCount = 0
            prefetchEvictedBeforeUseCount = 0
            prefetchWastedCount = 0
            latch.countDown()
        }
        latch.await(1, TimeUnit.SECONDS)
    }

    fun configureFrame(
        container: ContainerMetadata,
        decoded: DecodedOutputMetadata? = null,
    ) {
        if (closed) return
        val latch = CountDownLatch(1)
        handler.post {
            if (closed) {
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
        if (closed) return RenderAck(AckStatus.STALE, 0, "RENDERER_CLOSED")
        val latch = CountDownLatch(1)
        val result = AtomicReference<RenderAck?>()
        handler.post {
            if (closed) {
                result.set(RenderAck(AckStatus.STALE, 0, "RENDERER_CLOSED"))
                latch.countDown()
                return@post
            }
            if (request.token.fileGeneration != fileGeneration || display == EGL14.EGL_NO_DISPLAY) {
                result.set(RenderAck(AckStatus.STALE, 0, "CACHE_GENERATION_STALE"))
            } else {
                cache.recordRequest(request.requestedFrameIndex)
                val cached = cache.get(request.expectedKey)
                if (cached != null) {
                    if (prefetchedKeys.remove(request.expectedKey)) prefetchCacheHitCount += 1
                    drawTextureToWindow(cached)
                    val event = publish(request, cached.timestampNs)
                    if (event.result == PublicationResult.PUBLISHED) lastPublishedKey = request.expectedKey
                    result.set(
                        renderAckFor(
                            event,
                            cacheHit = true,
                            imageProbe = cached.imageProbe,
                        ),
                    )
                }
            }
            latch.countDown()
        }
        return if (latch.await(2, TimeUnit.SECONDS)) result.get() else RenderAck(AckStatus.ERROR, 0, "CACHE_RENDER_TIMEOUT")
    }

    fun queueTarget(request: FrameRequest): TargetHandle? {
        if (closed) return null
        val latch = CountDownLatch(1)
        val result = AtomicReference<TargetHandle?>()
        handler.post {
            if (closed) {
                latch.countDown()
                return@post
            }
            if (pendingTarget == null && display != EGL14.EGL_NO_DISPLAY && request.token.fileGeneration == fileGeneration) {
                TargetHandle(request).also {
                    pendingTarget = PendingTarget(
                        token = request.token,
                        expectedKey = request.expectedKey,
                        publicationRequest = request,
                        complete = it::complete,
                    )
                    cache.recordRequest(request.requestedFrameIndex)
                    result.set(it)
                }
            }
            latch.countDown()
        }
        return if (latch.await(2, TimeUnit.SECONDS)) result.get() else null
    }

    fun queueCacheOnly(token: GenerationToken, expectedKey: FrameKey): CacheTargetHandle? {
        if (closed) return null
        val latch = CountDownLatch(1)
        val result = AtomicReference<CacheTargetHandle?>()
        handler.post {
            if (closed) {
                latch.countDown()
                return@post
            }
            if (
                pendingTarget == null &&
                display != EGL14.EGL_NO_DISPLAY &&
                token.fileGeneration == fileGeneration &&
                publicationGate.isCurrent(token)
            ) {
                CacheTargetHandle(token, expectedKey).also {
                    pendingTarget = PendingTarget(
                        token = token,
                        expectedKey = expectedKey,
                        publicationRequest = null,
                        complete = it::complete,
                    )
                    result.set(it)
                }
            }
            latch.countDown()
        }
        return if (latch.await(2, TimeUnit.SECONDS)) result.get() else null
    }

    fun cacheByteSize(): Long = cache.byteSize
    fun cacheHits(): Long = cache.hitCount
    fun cacheMisses(): Long = cache.missCount
    fun fullFrameReadbacks(): Long = probePolicy.readbackCount()

    internal fun prefetchSnapshot(frameKeys: Collection<FrameKey> = emptyList()): PrefetchSnapshot {
        if (closed) return emptyPrefetchSnapshot()
        val latch = CountDownLatch(1)
        val result = AtomicReference<PrefetchSnapshot?>()
        handler.post {
            if (closed) {
                latch.countDown()
                return@post
            }
            result.set(
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
                ),
            )
            latch.countDown()
        }
        return if (latch.await(2, TimeUnit.SECONDS)) {
            result.get() ?: emptyPrefetchSnapshot()
        } else {
            emptyPrefetchSnapshot()
        }
    }

    fun trimCache(level: Int) {
        if (closed) return
        handler.post {
            if (closed) return@post
            val targetBytes = cacheTargetBytes(level, byteBudget)
            if (targetBytes == 0L) cache.clear() else cache.trimToBytes(targetBytes)
        }
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
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

        val texture = IntArray(1)
        GLES30.glGenTextures(1, texture, 0)
        oesTextureId = texture[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        val textureSource = SurfaceTexture(oesTextureId).apply {
            setDefaultBufferSize(sourceWidth, sourceHeight)
            setOnFrameAvailableListener({ onFrameAvailable() }, handler)
        }
        surfaceTexture = textureSource
        synchronized(decoderSurfaceMonitor) {
            decoderSurface = Surface(textureSource)
            decoderSurfaceMonitor.notifyAll()
        }
        onDecoderSurfaceChanged(true)
    }

    private fun onFrameAvailable() {
        val source = surfaceTexture ?: return
        try {
            source.updateTexImage()
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
        if (handle.token.fileGeneration != fileGeneration || !publicationGate.isCurrent(handle.token)) {
            handle.complete(RenderAck(AckStatus.STALE, timestampNs, "TEXTURE_GENERATION_STALE"))
            return
        }

        val textureMatrix = FloatArray(16)
        source.getTransformMatrix(textureMatrix)
        val cached = try {
            copyExternalTexture(textureMatrix, canonicalGeometry.rotationDegrees, timestampNs)
        } catch (_: Throwable) {
            handle.complete(RenderAck(AckStatus.ERROR, timestampNs, "TEXTURE_COPY_FAILED"))
            return
        }
        val prefetchBudget = prefetchBudgetDecision(cached.width, cached.height, byteBudget)
        val frameBytes = prefetchBudget.canonicalFrameBytes
        val retained = frameBytes > 0 && cache.put(
                key = handle.expectedKey,
                value = cached,
                bytes = frameBytes,
                protectedKeys = setOfNotNull(lastPublishedKey),
                maximumByteSize = if (handle.publicationRequest == null) {
                    prefetchBudget.availablePrefetchBytes + frameBytes
                } else {
                    byteBudget
                },
            )
        completeCachedTextureTarget(
            publicationRequest = handle.publicationRequest,
            onCacheOnly = {
                if (retained) {
                    prefetchedKeys += handle.expectedKey
                    handle.complete(RenderAck(AckStatus.CACHED, timestampNs, imageProbe = cached.imageProbe))
                } else {
                    GLES30.glDeleteTextures(1, intArrayOf(cached.textureId), 0)
                    handle.complete(RenderAck(AckStatus.ERROR, timestampNs, "PREFETCH_NOT_RETAINED"))
                }
            },
            onPublish = { publicationRequest ->
                drawTextureToWindow(cached)
                val event = publish(publicationRequest, timestampNs)
                if (event.result == PublicationResult.PUBLISHED) lastPublishedKey = handle.expectedKey
                handle.complete(renderAckFor(event, imageProbe = cached.imageProbe))
                if (!retained) GLES30.glDeleteTextures(1, intArrayOf(cached.textureId), 0)
            },
        )
    }

    private fun publish(request: FrameRequest, textureTimestampNs: Long): PublicationEvent =
        publicationGate.publish(
            request = request,
            textureTimestampNs = textureTimestampNs,
            surfaceValid = {
                display != EGL14.EGL_NO_DISPLAY &&
                    eglWindowSurface != EGL14.EGL_NO_SURFACE &&
                    windowSurface?.isValid == true
            },
            swap = { EGL14.eglSwapBuffers(display, eglWindowSurface) },
        )

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

        val framebuffers = IntArray(1)
        GLES30.glGenFramebuffers(1, framebuffers, 0)
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
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glDeleteFramebuffers(1, framebuffers, 0)
        return CachedTexture(textureId, outputWidth, outputHeight, timestampNs, imageProbe)
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
        pendingTarget?.complete?.invoke(RenderAck(AckStatus.ERROR, 0, "SURFACE_RELEASED"))
        pendingTarget = null
        if (display != EGL14.EGL_NO_DISPLAY) {
            runCatching { EGL14.eglMakeCurrent(display, eglWindowSurface, eglWindowSurface, context) }
            cache.clear()
            lastPublishedKey = null
            if (oesTextureId != 0) GLES30.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
            if (oesProgram != 0) GLES30.glDeleteProgram(oesProgram)
            if (textureProgram != 0) GLES30.glDeleteProgram(textureProgram)
            if (vertexBuffer != 0) GLES30.glDeleteBuffers(1, intArrayOf(vertexBuffer), 0)
            if (vertexArray != 0) GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
        }
        synchronized(decoderSurfaceMonitor) {
            decoderSurface?.release()
            decoderSurface = null
            decoderSurfaceMonitor.notifyAll()
        }
        surfaceTexture?.release()
        surfaceTexture = null
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

    private fun emptyPrefetchSnapshot(): PrefetchSnapshot = PrefetchSnapshot(
        budget = prefetchBudgetDecision(0, 0, byteBudget),
        cachedFrameKeys = emptySet(),
        cacheHitCount = prefetchCacheHitCount,
        evictedBeforeUseCount = prefetchEvictedBeforeUseCount,
        wastedCount = prefetchWastedCount,
        currentDepth = prefetchedKeys.size,
    )

    companion object {
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
