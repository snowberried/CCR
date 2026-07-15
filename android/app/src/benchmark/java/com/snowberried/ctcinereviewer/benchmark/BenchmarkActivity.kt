package com.snowberried.ctcinereviewer.benchmark

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import com.snowberried.ctcinereviewer.BuildConfig
import com.snowberried.ctcinereviewer.ViewerUiState
import com.snowberried.ctcinereviewer.ViewerViewModel
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import kotlin.math.abs
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/** Benchmark-only fixture entry. It is never packaged in debug or release builds. */
class BenchmarkActivity : ComponentActivity() {
    private enum class Phase {
        OPENING,
        INITIAL_FRAME,
        ADJACENT_MISS_WARMUP,
        TARGET_FRAME,
        SWITCHED_FRAME,
        COMPLETE,
    }

    private lateinit var viewer: ViewerViewModel
    private lateinit var statusView: TextView
    private val mainHandler = Handler(Looper.getMainLooper())
    private var scenario = SCENARIO_ENTRY
    private var phase = Phase.OPENING
    private var started = false
    private var failed = false
    private var firstFileGeneration: Long? = null
    private var secondFileGeneration: Long? = null
    private var expectedTargetIndex: Int? = null
    private var displayedFrameIndex: Int? = null
    private var latestRequestedFrameIndex: Int? = null
    private var handledPublication: Triple<Long, Long, Long>? = null
    private var openIndexTraceCookie: Long? = null
    private var openFirstTraceCookie: Long? = null
    private var requestTraceCookie: Long? = null
    private var switchTraceCookie: Long? = null
    private var resumeTraceCookie: Long? = null
    private var expectedCacheHit: Boolean? = null
    private var cacheHitBaseline = 0L
    private var cacheMissBaseline = 0L
    private var observedSurfaceGeneration = 0L
    private var surfaceRecreateCount = 0L
    private var backgroundStopped = false
    private var backgroundMeasurementPending = false
    private var traceCookieSeed = System.nanoTime()
    private var stateObservation: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        require(BuildConfig.BUILD_TYPE == "benchmark" && !BuildConfig.DEBUG) {
            "BENCHMARK_VARIANT_REQUIRED"
        }
        scenario = intent.getStringExtra(EXTRA_SCENARIO) ?: SCENARIO_ENTRY
        if (scenario == SCENARIO_ENTRY) beginAsync(TRACE_FIXTURE_ENTRY, ENTRY_TRACE_COOKIE)
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

        viewer = ViewModelProvider(this)[ViewerViewModel::class.java]
        val viewport = viewer.createViewport(this)
        setContentView(FrameLayout(this).apply {
            addView(viewport, FrameLayout.LayoutParams(-1, -1))
            // The product UI starts Compose's process-wide snapshot notification loop.
            // This View-only benchmark host must do the same before collecting uiState.
            addView(ComposeView(this@BenchmarkActivity).apply { setContent {} }, FrameLayout.LayoutParams(1, 1))
            addView(statusView, FrameLayout.LayoutParams(2, 2).apply {
                leftMargin = 200
                topMargin = 200
            })
        })
    }

    override fun onStart() {
        super.onStart()
        if (!::viewer.isInitialized) return
        if (scenario == SCENARIO_BACKGROUND_FOREGROUND && backgroundStopped) {
            prepareBackgroundMeasurement()
        }
        stateObservation?.cancel()
        stateObservation = lifecycleScope.launch {
            snapshotFlow { viewer.uiState }.collect { state ->
                if (!failed) observeState(state)
            }
        }
        viewer.onForeground(this)
    }

    override fun onStop() {
        stateObservation?.cancel()
        stateObservation = null
        if (::viewer.isInitialized) {
            if (
                scenario == SCENARIO_BACKGROUND_FOREGROUND &&
                phase == Phase.COMPLETE &&
                displayedFrameIndex != null
            ) {
                backgroundStopped = true
            }
            viewer.onBackground(this)
        }
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getStringExtra(EXTRA_SCENARIO) == SCENARIO_BACKGROUND_FOREGROUND) {
            scenario = SCENARIO_BACKGROUND_FOREGROUND
            prepareBackgroundMeasurement()
        }
    }

    private fun observeState(state: ViewerUiState) {
        traceDiagnostics(state)
        if (state.diagnostics.fullFrameReadbackCount != 0L) {
            fail("PRODUCT_READBACK_FORBIDDEN")
            return
        }
        if (state.status == "error" || state.status == "unsupported") {
            fail("${state.status}:${state.lastErrorCode ?: state.detail ?: "UNKNOWN"}")
            return
        }
        traceSurfaceGeneration(state.surfaceGeneration)

        if (!started && state.surfaceAvailable) {
            if (scenario == SCENARIO_ENTRY) {
                started = true
                endAsync(TRACE_FIXTURE_ENTRY, ENTRY_TRACE_COOKIE)
                complete()
            } else {
                startScenario()
            }
        }
        if (!started || phase == Phase.OPENING) return

        val activeFileGeneration = state.activeFileGeneration
        if (firstFileGeneration == null && phase != Phase.SWITCHED_FRAME) {
            firstFileGeneration = activeFileGeneration
        }
        if (
            phase == Phase.SWITCHED_FRAME &&
            activeFileGeneration != null &&
            activeFileGeneration != firstFileGeneration
        ) {
            secondFileGeneration = activeFileGeneration
        }

        if (
            openIndexTraceCookie != null &&
            state.framePtsUs.isNotEmpty() &&
            activeFileGeneration == firstFileGeneration
        ) {
            endOpenIndexTrace()
            if (scenario == SCENARIO_OPEN_INDEX) {
                endOpenFirstTrace()
                complete()
            }
        }

        val requestGeneration = state.activeRequestGeneration
        val displayed = state.displayedFrameIndex
        if (
            state.status == "ready" &&
            activeFileGeneration != null &&
            requestGeneration != null &&
            displayed != null
        ) {
            val publication = Triple(
                activeFileGeneration,
                requestGeneration,
                state.diagnostics.publishedSwapCount,
            )
            if (publication != handledPublication) {
                handledPublication = publication
                onPublished(state, displayed)
            }
        }
    }

    private fun startScenario() {
        started = true
        phase = Phase.INITIAL_FRAME
        latestRequestedFrameIndex = 0
        openIndexTraceCookie = nextTraceCookie().also { beginAsync(TRACE_OPEN_TO_INDEX, it) }
        openFirstTraceCookie = nextTraceCookie().also { beginAsync(TRACE_OPEN_TO_FIRST_FRAME, it) }
        viewer.openVideo(fixtureUri(firstFixture()))
    }

    private fun onPublished(state: ViewerUiState, displayed: Int) {
        displayedFrameIndex = displayed
        Trace.setCounter("ccr.displayed_frame", displayed.toLong())
        when (phase) {
            Phase.INITIAL_FRAME -> {
                if (state.activeFileGeneration != firstFileGeneration) return
                endOpenFirstTrace()
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
                if (displayed != expectedTargetIndex) return
                if (!assertExpectedCacheCounters(state.diagnostics)) return
                requestTraceCookie?.let { endAsync(TRACE_REQUEST_TO_PUBLISH, it) }
                requestTraceCookie = null
                if (scenario == SCENARIO_BACKGROUND_FOREGROUND && backgroundMeasurementPending) {
                    resumeTraceCookie?.let { endAsync(TRACE_BACKGROUND_TO_FIRST_FRAME, it) }
                    resumeTraceCookie = null
                    backgroundMeasurementPending = false
                }
                complete()
            }
            Phase.ADJACENT_MISS_WARMUP -> {
                if (displayed != DISTANT_FRAME) return
                requestTarget(DISTANT_FRAME - 1, expectCacheHit = false)
            }
            Phase.SWITCHED_FRAME -> {
                if (state.activeFileGeneration != secondFileGeneration) return
                switchTraceCookie?.let { endAsync(TRACE_SWITCH_TO_FIRST_FRAME, it) }
                switchTraceCookie = null
                complete()
            }
            Phase.OPENING, Phase.COMPLETE -> Unit
        }
    }

    private fun waitForPrefetchThenRequest(frameIndex: Int) {
        Thread({
            if (!viewer.awaitActorIdleForTest()) {
                runOnUiThread { fail("PREFETCH_IDLE_TIMEOUT") }
                return@Thread
            }
            runOnUiThread {
                requestTarget(
                    frameIndex,
                    expectCacheHit = if (scenario == SCENARIO_CACHE_HIT) true else null,
                )
            }
        }, "ccr-benchmark-prefetch-wait").start()
    }

    private fun requestTarget(frameIndex: Int, expectCacheHit: Boolean? = null) {
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = frameIndex
        latestRequestedFrameIndex = frameIndex
        expectedCacheHit = expectCacheHit
        cacheHitBaseline = viewer.uiState.diagnostics.cacheHitCount
        cacheMissBaseline = viewer.uiState.diagnostics.cacheMissCount
        requestTraceCookie = nextTraceCookie().also { beginAsync(TRACE_REQUEST_TO_PUBLISH, it) }
        Trace.setCounter("ccr.requested_frame", frameIndex.toLong())
        viewer.requestFrame(frameIndex)
    }

    private fun startAdjacentMissWarmup() {
        phase = Phase.ADJACENT_MISS_WARMUP
        latestRequestedFrameIndex = DISTANT_FRAME
        Trace.setCounter("ccr.requested_frame", DISTANT_FRAME.toLong())
        viewer.requestFrame(DISTANT_FRAME)
    }

    private fun startRepeatedRequests() {
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = LONG_PRESS_LAST_FRAME
        expectedCacheHit = null
        requestTraceCookie = nextTraceCookie().also { beginAsync(TRACE_REQUEST_TO_PUBLISH, it) }
        val gestureGeneration = viewer.beginNavigationGesture()
        repeat(LONG_PRESS_LAST_FRAME) { offset ->
            mainHandler.postDelayed({
                val frameIndex = offset + 1
                latestRequestedFrameIndex = frameIndex
                Trace.setCounter("ccr.requested_frame", frameIndex.toLong())
                viewer.moveByGesture(1, gestureGeneration)
                if (frameIndex == LONG_PRESS_LAST_FRAME) {
                    viewer.endNavigationGesture(gestureGeneration)
                }
            }, offset * REPEAT_INTERVAL_MS)
        }
    }

    private fun startSwitch() {
        phase = Phase.SWITCHED_FRAME
        secondFileGeneration = null
        switchTraceCookie = nextTraceCookie().also { beginAsync(TRACE_SWITCH_TO_FIRST_FRAME, it) }
        viewer.openVideo(fixtureUri(secondFixture()))
    }

    private fun prepareBackgroundMeasurement() {
        if (backgroundMeasurementPending || !::viewer.isInitialized) return
        val frame = displayedFrameIndex ?: viewer.uiState.requestedFrameIndex
        backgroundStopped = false
        backgroundMeasurementPending = true
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = frame
        latestRequestedFrameIndex = frame
        expectedCacheHit = null
        resumeTraceCookie = nextTraceCookie().also {
            beginAsync(TRACE_BACKGROUND_TO_FIRST_FRAME, it)
        }
        viewer.requestFrame(frame)
        statusView.updateStatus(status(SUFFIX_WAITING))
    }

    private fun assertExpectedCacheCounters(diagnostics: DecoderDiagnostics): Boolean {
        return when (expectedCacheHit) {
            true -> if (
                diagnostics.cacheHitCount > cacheHitBaseline &&
                diagnostics.cacheMissCount == cacheMissBaseline
            ) {
                true
            } else {
                fail("EXPECTED_CACHE_HIT_COUNTER")
                false
            }
            false -> if (
                diagnostics.cacheMissCount > cacheMissBaseline &&
                diagnostics.cacheHitCount == cacheHitBaseline
            ) {
                true
            } else {
                fail("EXPECTED_CACHE_MISS_COUNTER")
                false
            }
            null -> true
        }
    }

    private fun traceSurfaceGeneration(generation: Long) {
        if (generation <= observedSurfaceGeneration) return
        if (observedSurfaceGeneration > 0L) {
            surfaceRecreateCount += generation - observedSurfaceGeneration
            Trace.setCounter("ccr.surface_recreate", surfaceRecreateCount)
        }
        observedSurfaceGeneration = generation
    }

    private fun traceDiagnostics(state: ViewerUiState) {
        val diagnostics = state.diagnostics
        val displayed = state.displayedFrameIndex ?: displayedFrameIndex ?: state.requestedFrameIndex
        val requested = latestRequestedFrameIndex ?: state.requestedFrameIndex
        Trace.setCounter("ccr.requested_displayed_lag", abs(requested - displayed).toLong())
        Trace.setCounter("ccr.decoded_output", diagnostics.decodeOrdinal)
        Trace.setCounter("ccr.cache_hit", diagnostics.cacheHitCount)
        Trace.setCounter("ccr.cache_miss", diagnostics.cacheMissCount)
        Trace.setCounter("ccr.prefetch_completed", diagnostics.prefetchedFrameCount)
        Trace.setCounter("ccr.prefetch_cache_hit", diagnostics.prefetchCacheHit)
        Trace.setCounter("ccr.prefetch_cancelled", diagnostics.prefetchCancelled)
        Trace.setCounter("ccr.prefetch_wasted", diagnostics.prefetchWasted)
        Trace.setCounter("ccr.cache_bytes", diagnostics.cacheBytes)
        Trace.setCounter("ccr.codec_recreate", diagnostics.decoderRecreateCount)
        Trace.setCounter("ccr.swap_failure", diagnostics.swapFailureCount)
        Trace.setCounter("ccr.stale_discard", diagnostics.staleDiscardCount)
        Trace.setCounter("ccr.invariant_violation", diagnostics.publicationInvariantViolationCount)
        Trace.setCounter("ccr.full_frame_readback", diagnostics.fullFrameReadbackCount)
    }

    private fun endOpenIndexTrace() {
        openIndexTraceCookie?.let { endAsync(TRACE_OPEN_TO_INDEX, it) }
        openIndexTraceCookie = null
    }

    private fun endOpenFirstTrace() {
        openFirstTraceCookie?.let { endAsync(TRACE_OPEN_TO_FIRST_FRAME, it) }
        openFirstTraceCookie = null
    }

    private fun complete() {
        if (failed) return
        phase = Phase.COMPLETE
        statusView.updateStatus(status(SUFFIX_COMPLETE))
    }

    private fun fail(code: String) {
        if (failed) return
        failed = true
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

    private fun nextTraceCookie(): Long {
        traceCookieSeed += 1
        return traceCookieSeed
    }

    override fun onDestroy() {
        stateObservation?.cancel()
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
        const val TRACE_FIXTURE_ENTRY = "ccr.fixture_entry"
        const val TRACE_BACKGROUND_TO_FIRST_FRAME = "ccr.background_to_first_frame"

        private const val H264_FIXTURE = "burst.mp4"
        private const val H264_SECOND_FIXTURE = "h264-ip.mp4"
        private const val HEVC_FIXTURE = "hevc-main8.mp4"
        private const val LONG_PRESS_LAST_FRAME = 12
        private const val DISTANT_FRAME = 36
        private const val REPEAT_INTERVAL_MS = 50L
        private const val ENTRY_TRACE_COOKIE = 1L
        private val REQUIRED_FIXTURES = listOf(H264_FIXTURE, H264_SECOND_FIXTURE, HEVC_FIXTURE)

        private fun beginAsync(name: String, cookie: Long) {
            Trace.beginAsyncSection(name, cookie.toInt())
        }

        private fun endAsync(name: String, cookie: Long) {
            Trace.endAsyncSection(name, cookie.toInt())
        }
    }
}
