package com.snowberried.ctcinereviewer.gate

import android.app.Activity
import android.net.Uri
import android.os.Bundle
import android.view.SurfaceHolder
import android.view.WindowManager
import android.widget.FrameLayout
import com.snowberried.ctcinereviewer.NavigationMode
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DirectionalPrefetchDirection
import com.snowberried.ctcinereviewer.media.ExactFrameSession
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import com.snowberried.ctcinereviewer.media.PublicationEvent
import com.snowberried.ctcinereviewer.media.RequestAcceptance
import com.snowberried.ctcinereviewer.render.FrameRenderMode
import com.snowberried.ctcinereviewer.render.VideoViewport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class GateActivity : Activity(), ExactFrameSession.Listener {
    data class ObservedResult(val result: FrameResult, val diagnostics: DecoderDiagnostics)

    private lateinit var session: ExactFrameSession
    private lateinit var root: FrameLayout
    private val holderSurfaceReady = CountDownLatch(1)
    private val decoderSurfaceReady = CountDownLatch(1)
    private val metadata = LinkedBlockingQueue<ContainerMetadata>()
    private val indexes = LinkedBlockingQueue<IndexedVideo>()
    private val results = LinkedBlockingQueue<ObservedResult>()
    private val statuses = LinkedBlockingQueue<Pair<String, String?>>()
    private val publicationEvents = LinkedBlockingQueue<PublicationEvent>()
    @Volatile private var replacementSurfaceReady: CountDownLatch? = null
    @Volatile private var latestDiagnostics = DecoderDiagnostics()
    private var lastRequestedIndex = 0
    private var nextHoldGestureGeneration = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val renderMode = if (intent.getBooleanExtra(EXTRA_PILOT_MODE, false)) {
            FrameRenderMode.PILOT
        } else {
            FrameRenderMode.EXACTNESS
        }
        session = ExactFrameSession(this, this, renderMode)
        root = FrameLayout(this)
        setContentView(root)
        installViewport(holderSurfaceReady)
    }

    private fun installViewport(holderReady: CountDownLatch) {
        val viewport: VideoViewport = session.createViewport(this)
        viewport.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = holderReady.countDown()
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
            override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
        })
        root.removeAllViews()
        root.addView(viewport, FrameLayout.LayoutParams(-1, -1))
    }

    fun awaitSurface(timeoutSeconds: Long = 5): Boolean {
        val deadlineNs = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
        if (!holderSurfaceReady.await(timeoutSeconds, TimeUnit.SECONDS)) return false
        val remainingNs = deadlineNs - System.nanoTime()
        return remainingNs > 0 && decoderSurfaceReady.await(remainingNs, TimeUnit.NANOSECONDS)
    }

    fun openFixture(uri: Uri) {
        metadata.clear()
        indexes.clear()
        results.clear()
        statuses.clear()
        lastRequestedIndex = 0
        session.open(uri)
    }

    fun requestFrame(index: Int): RequestAcceptance? {
        lastRequestedIndex = index
        return session.requestNavigationFrame(index, NavigationMode.DIRECT_FRAME_SEEK)
    }

    fun requestDirectionalFrame(index: Int): RequestAcceptance? {
        val direction = if (index < lastRequestedIndex) {
            DirectionalPrefetchDirection.REVERSE
        } else {
            DirectionalPrefetchDirection.FORWARD
        }
        lastRequestedIndex = index
        return session.requestDirectionalFrame(index, direction)
    }

    fun requestForwardSequentialFrame(index: Int, stride: Int): RequestAcceptance? {
        require(stride == 1 || stride == 5)
        lastRequestedIndex = index
        return session.tryRequestFrame(
            frameIndex = index,
            prefetchPermit = null,
            holdTraversalStride = stride,
            holdGestureGeneration = 0,
            navigationMode = NavigationMode.HOLD_FORWARD,
        )
    }

    fun beginHoldGesture(): Long {
        nextHoldGestureGeneration += 1
        return nextHoldGestureGeneration
    }

    fun requestReverseSequentialFrame(
        index: Int,
        stride: Int,
        gestureGeneration: Long,
    ): RequestAcceptance? {
        require(stride == -1 || stride == -5)
        lastRequestedIndex = index
        return session.requestNavigationFrame(
            frameIndex = index,
            navigationMode = NavigationMode.HOLD_REVERSE,
            holdTraversalStride = stride,
            holdGestureGeneration = gestureGeneration,
        )
    }

    fun endHoldGesture(gestureGeneration: Long) = session.endHoldTraversal(gestureGeneration)

    fun replaceSurfaceForTest(): CountDownLatch = CountDownLatch(2).also { ready ->
        replacementSurfaceReady = ready
        installViewport(ready)
    }

    fun awaitActorIdle(timeoutMs: Long = 5_000): Boolean = session.awaitActorIdleForTest(timeoutMs)
    fun diagnosticsSnapshot(): DecoderDiagnostics = latestDiagnostics
    fun configureValidationDisplay(brightness: Float) {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.attributes = window.attributes.apply { screenBrightness = brightness.coerceIn(0.01f, 1f) }
    }
    fun cancel() = session.cancel()
    fun clearResults() {
        results.clear()
        publicationEvents.clear()
    }
    fun awaitMetadata(timeoutSeconds: Long = 10): ContainerMetadata? = metadata.poll(timeoutSeconds, TimeUnit.SECONDS)
    fun awaitIndex(timeoutSeconds: Long = 10): IndexedVideo? = indexes.poll(timeoutSeconds, TimeUnit.SECONDS)
    fun awaitResult(timeoutSeconds: Long = 20): ObservedResult? = results.poll(timeoutSeconds, TimeUnit.SECONDS)
    fun drainResults(): List<ObservedResult> = buildList { results.drainTo(this) }
    fun drainStatuses(): List<Pair<String, String?>> = buildList { statuses.drainTo(this) }
    fun drainPublicationEvents(): List<PublicationEvent> = buildList { publicationEvents.drainTo(this) }

    override fun onStatus(fileGeneration: Long?, status: String, detail: String?) {
        statuses += status to detail
    }

    override fun onVideoOpened(metadata: ContainerMetadata) {
        this.metadata += metadata
    }

    override fun onVideoIndexed(video: IndexedVideo) {
        indexes += video
    }

    override fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics) {
        latestDiagnostics = diagnostics
        results += ObservedResult(result, diagnostics)
    }

    override fun onPublicationEvent(event: PublicationEvent) {
        publicationEvents += event
    }

    override fun onSurfaceAvailabilityChanged(available: Boolean) {
        if (available) {
            decoderSurfaceReady.countDown()
            replacementSurfaceReady?.countDown()
        }
    }

    override fun onDestroy() {
        session.close()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_PILOT_MODE = "pilot-mode"
    }
}
