package com.snowberried.ctcinereviewer.benchmark

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.view.SurfaceHolder
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.widget.FrameLayout
import android.widget.TextView
import com.snowberried.ctcinereviewer.BuildConfig
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.ExactFrameSession
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import com.snowberried.ctcinereviewer.media.PublicationEvent
import com.snowberried.ctcinereviewer.render.FrameRenderMode
import kotlin.math.abs

/** Benchmark-only fixture entry. It is never packaged in debug or release builds. */
class BenchmarkActivity : Activity(), ExactFrameSession.Listener {
    private enum class Phase {
        OPENING,
        INITIAL_FRAME,
        ADJACENT_MISS_WARMUP,
        TARGET_FRAME,
        SWITCHED_FRAME,
        COMPLETE,
    }

    private lateinit var session: ExactFrameSession
    private lateinit var statusView: TextView
    private val mainHandler = Handler(Looper.getMainLooper())
    private var scenario = SCENARIO_ENTRY
    private var phase = Phase.OPENING
    private var started = false
    private var surfaceAvailable = false
    private var firstFileGeneration = -1L
    private var secondFileGeneration = -1L
    private var expectedTargetIndex: Int? = null
    private var displayedFrameIndex: Int? = null
    private var latestRequestedFrameIndex: Int? = null
    private var requestTraceCookie: Long? = null
    private var surfaceRecreateCount = 0L
    private var sawSurfaceUnavailable = false
    private var resumePending = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        require(BuildConfig.BUILD_TYPE == "benchmark" && !BuildConfig.DEBUG) {
            "BENCHMARK_VARIANT_REQUIRED"
        }
        scenario = intent.getStringExtra(EXTRA_SCENARIO) ?: SCENARIO_ENTRY
        statusView = TextView(this).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            updateStatus(status(SUFFIX_WAITING))
        }
        if (scenario == SCENARIO_PREPARE) {
            setContentView(statusView)
            Thread({
                runCatching { BenchmarkFixtureProvider.prepare(this, REQUIRED_FIXTURES) }
                    .onSuccess { runOnUiThread(::complete) }
                    .onFailure { runOnUiThread { fail("FIXTURE_PREPARE_FAILED") } }
            }, "ccr-benchmark-fixture-prepare").start()
            return
        }

        session = ExactFrameSession(this, this, FrameRenderMode.PILOT)
        val viewport = session.createViewport(this)
        viewport.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = Unit
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
            override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
        })
        setContentView(FrameLayout(this).apply {
            addView(viewport, FrameLayout.LayoutParams(-1, -1))
            addView(statusView, FrameLayout.LayoutParams(2, 2).apply {
                leftMargin = 200
                topMargin = 200
            })
        })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getStringExtra(EXTRA_SCENARIO) == SCENARIO_BACKGROUND_FOREGROUND) {
            scenario = SCENARIO_BACKGROUND_FOREGROUND
            resumePending = true
            statusView.updateStatus(status(SUFFIX_WAITING))
            requestResumeFrameIfReady()
        }
    }

    override fun onStatus(fileGeneration: Long?, status: String, detail: String?) {
        if (status == "error" || status == "unsupported") fail("$status:${detail ?: "UNKNOWN"}")
    }

    override fun onVideoOpened(metadata: ContainerMetadata) = Unit

    override fun onVideoIndexed(video: IndexedVideo) {
        if (video.fileGeneration == firstFileGeneration) {
            endAsync(TRACE_OPEN_TO_INDEX, firstFileGeneration)
            if (scenario == SCENARIO_OPEN_INDEX) {
                endAsync(TRACE_OPEN_TO_FIRST_FRAME, firstFileGeneration)
                complete()
            }
        }
    }

    override fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics) {
        traceDiagnostics(result, diagnostics)
        if (diagnostics.fullFrameReadbackCount != 0L) {
            fail("PRODUCT_READBACK_FORBIDDEN")
            return
        }
        when (result) {
            is FrameResult.Published -> onPublished(result)
            is FrameResult.Error -> fail(result.code)
            is FrameResult.Unsupported -> fail(result.reason)
            is FrameResult.DiscardedStale -> Unit
        }
    }

    override fun onPublicationEvent(event: PublicationEvent) = Unit

    override fun onSurfaceAvailabilityChanged(available: Boolean) {
        if (!available) {
            surfaceAvailable = false
            sawSurfaceUnavailable = true
            return
        }
        surfaceAvailable = true
        if (sawSurfaceUnavailable) {
            surfaceRecreateCount += 1
            Trace.setCounter("ccr.surface_recreate", surfaceRecreateCount)
        }
        if (!started) startScenario() else requestResumeFrameIfReady()
    }

    private fun startScenario() {
        started = true
        phase = Phase.INITIAL_FRAME
        val token = session.open(fixtureUri(firstFixture())) ?: return fail("OPEN_REJECTED")
        firstFileGeneration = token.fileGeneration
        beginAsync(TRACE_OPEN_TO_INDEX, token.fileGeneration)
        beginAsync(TRACE_OPEN_TO_FIRST_FRAME, token.fileGeneration)
    }

    private fun onPublished(result: FrameResult.Published) {
        displayedFrameIndex = result.request.requestedFrameIndex
        Trace.setCounter("ccr.displayed_frame", result.request.requestedFrameIndex.toLong())
        when (phase) {
            Phase.INITIAL_FRAME -> {
                if (result.request.token.fileGeneration != firstFileGeneration) return
                endAsync(TRACE_OPEN_TO_FIRST_FRAME, firstFileGeneration)
                when (scenario) {
                    SCENARIO_ENTRY, SCENARIO_OPEN_FIRST_FRAME -> complete()
                    SCENARIO_CACHE_HIT -> waitForPrefetchThenRequest(1)
                    SCENARIO_CACHE_MISS -> startAdjacentMissWarmup()
                    SCENARIO_TIMELINE_SEEK -> requestTarget(36)
                    SCENARIO_STEP_FIVE -> waitForPrefetchThenRequest(5)
                    SCENARIO_LONG_PRESS -> startRepeatedRequests()
                    SCENARIO_SWITCH_H264_H264,
                    SCENARIO_SWITCH_H264_HEVC,
                    SCENARIO_SWITCH_HEVC_H264,
                    SCENARIO_SWITCH_HEVC_HEVC -> startSwitch()
                    SCENARIO_BACKGROUND_FOREGROUND -> complete()
                }
            }
            Phase.TARGET_FRAME -> {
                if (result.request.requestedFrameIndex != expectedTargetIndex) return
                requestTraceCookie?.let { endAsync(TRACE_REQUEST_TO_PUBLISH, it) }
                requestTraceCookie = null
                complete()
            }
            Phase.ADJACENT_MISS_WARMUP -> {
                if (result.request.requestedFrameIndex != DISTANT_FRAME) return
                requestTarget(DISTANT_FRAME - 1)
            }
            Phase.SWITCHED_FRAME -> {
                if (result.request.token.fileGeneration != secondFileGeneration) return
                endAsync(TRACE_SWITCH_TO_FIRST_FRAME, secondFileGeneration)
                complete()
            }
            Phase.OPENING, Phase.COMPLETE -> Unit
        }
    }

    private fun waitForPrefetchThenRequest(frameIndex: Int) {
        Thread({
            if (!session.awaitActorIdleForTest()) {
                runOnUiThread { fail("PREFETCH_IDLE_TIMEOUT") }
                return@Thread
            }
            runOnUiThread { requestTarget(frameIndex) }
        }, "ccr-benchmark-prefetch-wait").start()
    }

    private fun requestTarget(frameIndex: Int) {
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = frameIndex
        latestRequestedFrameIndex = frameIndex
        val acceptance = session.requestFrame(frameIndex) ?: return fail("REQUEST_REJECTED")
        requestTraceCookie = acceptance.request.token.requestGeneration
        beginAsync(TRACE_REQUEST_TO_PUBLISH, requireNotNull(requestTraceCookie))
        Trace.setCounter("ccr.requested_frame", frameIndex.toLong())
    }

    private fun startAdjacentMissWarmup() {
        phase = Phase.ADJACENT_MISS_WARMUP
        latestRequestedFrameIndex = DISTANT_FRAME
        Trace.setCounter("ccr.requested_frame", DISTANT_FRAME.toLong())
        if (session.requestFrame(DISTANT_FRAME) == null) fail("MISS_WARMUP_REJECTED")
    }

    private fun startRepeatedRequests() {
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = LONG_PRESS_LAST_FRAME
        val cookie = System.nanoTime().toInt()
        requestTraceCookie = cookie.toLong()
        beginAsync(TRACE_REQUEST_TO_PUBLISH, requireNotNull(requestTraceCookie))
        repeat(LONG_PRESS_LAST_FRAME) { offset ->
            mainHandler.postDelayed({
                val frameIndex = offset + 1
                latestRequestedFrameIndex = frameIndex
                Trace.setCounter("ccr.requested_frame", frameIndex.toLong())
                session.requestFrame(frameIndex)
            }, offset * REPEAT_INTERVAL_MS)
        }
    }

    private fun startSwitch() {
        phase = Phase.SWITCHED_FRAME
        val token = session.open(fixtureUri(secondFixture())) ?: return fail("SWITCH_REJECTED")
        secondFileGeneration = token.fileGeneration
        beginAsync(TRACE_SWITCH_TO_FIRST_FRAME, token.fileGeneration)
    }

    private fun requestResumeFrameIfReady() {
        val frame = displayedFrameIndex ?: return
        if (!resumePending || !surfaceAvailable) return
        resumePending = false
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = frame
        latestRequestedFrameIndex = frame
        val acceptance = session.requestFrame(frame) ?: return fail("RESUME_REQUEST_REJECTED")
        requestTraceCookie = acceptance.request.token.requestGeneration
        beginAsync(TRACE_REQUEST_TO_PUBLISH, requireNotNull(requestTraceCookie))
    }

    private fun traceDiagnostics(result: FrameResult, diagnostics: DecoderDiagnostics) {
        val displayed = displayedFrameIndex ?: result.request.requestedFrameIndex
        val requested = latestRequestedFrameIndex ?: result.request.requestedFrameIndex
        Trace.setCounter("ccr.requested_displayed_lag", abs(requested - displayed).toLong())
        Trace.setCounter("ccr.decoded_output", diagnostics.decodeOrdinal)
        Trace.setCounter("ccr.cache_hit", diagnostics.cacheHitCount)
        Trace.setCounter("ccr.cache_miss", diagnostics.cacheMissCount)
        Trace.setCounter("ccr.prefetch_completed", diagnostics.prefetchedFrameCount)
        Trace.setCounter("ccr.cache_bytes", diagnostics.cacheBytes)
        Trace.setCounter("ccr.codec_recreate", diagnostics.decoderRecreateCount)
        Trace.setCounter("ccr.swap_failure", diagnostics.swapFailureCount)
        Trace.setCounter("ccr.stale_discard", diagnostics.staleDiscardCount)
        Trace.setCounter("ccr.invariant_violation", diagnostics.publicationInvariantViolationCount)
        Trace.setCounter("ccr.full_frame_readback", diagnostics.fullFrameReadbackCount)
    }

    private fun complete() {
        phase = Phase.COMPLETE
        statusView.updateStatus(status(SUFFIX_COMPLETE))
    }

    private fun fail(code: String) {
        statusView.updateStatus(status("failed-$code"))
    }

    private fun TextView.updateStatus(value: String) {
        text = value
        contentDescription = value
        sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }

    private fun fixtureUri(name: String): Uri = Uri.Builder()
        .scheme("content")
        .authority("$packageName.benchmark-fixture")
        .appendPath(name)
        .build()

    private fun firstFixture(): String = when (scenario) {
        SCENARIO_SWITCH_HEVC_H264, SCENARIO_SWITCH_HEVC_HEVC -> HEVC_FIXTURE
        else -> H264_FIXTURE
    }

    private fun secondFixture(): String = when (scenario) {
        SCENARIO_SWITCH_H264_HEVC, SCENARIO_SWITCH_HEVC_HEVC -> HEVC_FIXTURE
        else -> H264_SECOND_FIXTURE
    }

    private fun status(suffix: String) = "$STATUS_PREFIX-$scenario-$suffix"

    override fun onDestroy() {
        if (::session.isInitialized) session.close()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_SCENARIO = "benchmark-scenario"
        const val STATUS_PREFIX = "ccr-benchmark"
        const val SUFFIX_WAITING = "waiting"
        const val SUFFIX_COMPLETE = "complete"

        const val SCENARIO_PREPARE = "prepare"
        const val SCENARIO_ENTRY = "entry"
        const val SCENARIO_OPEN_INDEX = "open-index"
        const val SCENARIO_OPEN_FIRST_FRAME = "open-first-frame"
        const val SCENARIO_CACHE_HIT = "plus-one-cache-hit"
        const val SCENARIO_CACHE_MISS = "plus-one-cache-miss"
        const val SCENARIO_STEP_FIVE = "plus-five"
        const val SCENARIO_LONG_PRESS = "long-press"
        const val SCENARIO_TIMELINE_SEEK = "timeline-distant-seek"
        const val SCENARIO_SWITCH_H264_H264 = "switch-h264-h264"
        const val SCENARIO_SWITCH_H264_HEVC = "switch-h264-hevc"
        const val SCENARIO_SWITCH_HEVC_H264 = "switch-hevc-h264"
        const val SCENARIO_SWITCH_HEVC_HEVC = "switch-hevc-hevc"
        const val SCENARIO_BACKGROUND_FOREGROUND = "background-foreground"

        const val TRACE_OPEN_TO_INDEX = "ccr.open_to_index"
        const val TRACE_OPEN_TO_FIRST_FRAME = "ccr.open_to_first_frame"
        const val TRACE_REQUEST_TO_PUBLISH = "ccr.request_to_publish"
        const val TRACE_SWITCH_TO_FIRST_FRAME = "ccr.switch_to_first_frame"

        private const val H264_FIXTURE = "burst.mp4"
        private const val H264_SECOND_FIXTURE = "h264-ip.mp4"
        private const val HEVC_FIXTURE = "hevc-main8.mp4"
        private const val LONG_PRESS_LAST_FRAME = 12
        private const val DISTANT_FRAME = 36
        private const val REPEAT_INTERVAL_MS = 50L
        private val REQUIRED_FIXTURES = listOf(H264_FIXTURE, H264_SECOND_FIXTURE, HEVC_FIXTURE)

        private fun beginAsync(name: String, cookie: Long) {
            Trace.beginAsyncSection(name, cookie.toInt())
        }

        private fun endAsync(name: String, cookie: Long) {
            Trace.endAsyncSection(name, cookie.toInt())
        }

    }
}
