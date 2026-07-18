package com.snowberried.ctcinereviewer.benchmark

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.Trace
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.widget.FrameLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import com.snowberried.ctcinereviewer.BuildConfig
import com.snowberried.ctcinereviewer.CcrSpikeApp
import com.snowberried.ctcinereviewer.ViewerUiState
import com.snowberried.ctcinereviewer.ViewerViewModel
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.PublicationResult
import androidx.metrics.performance.JankStats
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/** Benchmark-only fixture entry. It is never packaged in debug or release builds. */
class BenchmarkActivity : ComponentActivity() {
    private enum class Phase {
        OPENING,
        INITIAL_FRAME,
        PREFETCH_WARMUP,
        ADJACENT_MISS_WARMUP,
        TARGET_FRAME,
        SWITCHED_FRAME,
        REPRESENTATIVE_ACTIVE,
        REPRESENTATIVE_RESET,
        REPRESENTATIVE_SETTLING,
        COMPLETE,
    }

    private data class CounterVector(
        val decoded: Long,
        val coalesced: Long,
        val prefetchHit: Long,
        val prefetchStarted: Long,
        val prefetchCompleted: Long,
        val prefetchCancelled: Long,
        val prefetchWasted: Long,
        val prefetchEvictedBeforeUse: Long,
        val cacheEviction: Long,
        val seek: Long,
        val flush: Long,
        val sequentialEntry: Long,
        val sequentialFallback: Long,
        val sequentialOutput: Long,
        val swapFailure: Long,
    )

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
    private var jankStats: JankStats? = null
    private var measurementStarted = false
    private var measurementActive = false
    private var jankMeasurementActive = false
    private var metricSegmentStartedNs = 0L
    private var activeMetricDurationNs = 0L
    private var lastPublicationNs: Long? = null
    private var lastObservedPublicationSequence = 0L
    private var publicationCount = 0L
    private val publicationIntervalsNs = mutableListOf<Long>()
    private var publicationGapMaxNs = 0L
    private val requestedDisplayedLag = mutableListOf<Long>()
    private val acceptedTargetSequence = mutableListOf<Int>()
    private var issuedRequestCount = 0L
    private var coalescedRequestCount = 0L
    private var jankFrameCount = 0L
    private var jankCount = 0L
    private var counterPrevious: CounterVector? = null
    private var foregroundDecodedCount = 0L
    private var prefetchHitCount = 0L
    private var prefetchStartedCount = 0L
    private var prefetchCompletedCount = 0L
    private var prefetchCancelledCount = 0L
    private var prefetchWastedCount = 0L
    private var prefetchEvictedBeforeUseCount = 0L
    private var cacheEvictionCount = 0L
    private var seekCount = 0L
    private var flushCount = 0L
    private var sequentialEntryCount = 0L
    private var sequentialFallbackCount = 0L
    private var sequentialOutputCount = 0L
    private var swapFailureCount = 0L
    private var holdDelta = 0
    private var holdActiveTargetNs = 0L
    private var holdAccumulatedNs = 0L
    private var holdGestureGeneration: Long? = null
    private var representativeResetAction: (() -> Unit)? = null
    private var representativeDeadlineMs = 0L
    private lateinit var runId: String
    private lateinit var runtimeSourceSha: String
    private lateinit var harnessSourceSha: String
    private lateinit var runtimeInputsTreeSha256: String
    private lateinit var appApkSha256: String
    private lateinit var testApkSha256: String
    private lateinit var traceIdentity: String
    private var runIteration = 0
    private var identityTraceCookie: Long? = null
    private var outstandingForegroundTargetDepthMax = 0
    private var outstandingForegroundTargetSampleCount = 0L
    private var acceptedTargetCount = 0L
    private var releaseAfterAcceptedTargetCount = 0L
    private var lastAcceptedRequestGeneration: Long? = null
    private var releaseRequestGeneration: Long? = null
    private var releaseVerificationActive = false
    private var releaseGraceComplete = false
    private var counterObservationComplete = true
    private var counterCompleteness = false
    private var representativeCompletionStarted = false
    private var finalDiagnostics: DecoderDiagnostics? = null

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
        if (!readHarnessIdentity(intent)) {
            setContentView(statusView)
            fail("HARNESS_IDENTITY_INVALID")
            return
        }
        identityTraceCookie = nextTraceCookie().also {
            beginAsync("$TRACE_RUN_IDENTITY_PREFIX:$traceIdentity", it)
        }
        if (scenario == SCENARIO_ENTRY) beginAsync(TRACE_FIXTURE_ENTRY, ENTRY_TRACE_COOKIE)
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
        val composeView = ComposeView(this).apply {
            setContent {
                MaterialTheme {
                    CcrSpikeApp(
                        state = viewer.uiState,
                        onOpen = viewer::openVideo,
                        onRequest = viewer::requestFrame,
                        onNavigationGestureStart = viewer::beginNavigationGesture,
                        onNavigationStep = viewer::moveByGesture,
                        onNavigationHoldStart = viewer::startHoldTraversal,
                        onNavigationGestureEnd = viewer::endNavigationGesture,
                        onDirectInputChange = viewer::setDirectInput,
                        onTimelineRequest = viewer::requestTimelineFraction,
                        onCancel = viewer::cancel,
                        onCopyDiagnostics = {},
                        viewport = { viewport },
                    )
                }
            }
        }
        setContentView(FrameLayout(this).apply {
            addView(composeView, FrameLayout.LayoutParams(-1, -1))
            addView(statusView, FrameLayout.LayoutParams(2, 2).apply {
                leftMargin = 200
                topMargin = 200
            })
        })
        jankStats = JankStats.createAndTrack(window) { frameData ->
            if (jankMeasurementActive) {
                jankFrameCount += 1
                if (frameData.isJank) jankCount += 1
            }
        }
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
        observeMeasurement(state)
        traceDiagnostics(state)
        stopLongPressAtAcceptedTarget(state)
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
                    SCENARIO_CACHE_HIT -> startDirectionalPrefetchWarmup()
                    SCENARIO_CACHE_MISS -> startAdjacentMissWarmup()
                    SCENARIO_TIMELINE_SEEK -> requestTarget(36)
                    SCENARIO_STEP_FIVE -> requestDirectionalTarget(5)
                    SCENARIO_LONG_PRESS -> startRepeatedRequests()
                    SCENARIO_SWITCH_H264_H264,
                    SCENARIO_SWITCH_H264_HEVC,
                    SCENARIO_SWITCH_HEVC_H264,
                    SCENARIO_SWITCH_HEVC_HEVC -> startSwitch()
                    SCENARIO_BACKGROUND_FOREGROUND -> complete()
                    SCENARIO_HOLD_720_PLUS_ONE,
                    SCENARIO_HOLD_720_PLUS_FIVE,
                    SCENARIO_HOLD_1080_PLUS_ONE,
                    SCENARIO_HOLD_1080_PLUS_FIVE -> startRepresentativeHold()
                    SCENARIO_HOLD_1080_MINUS_ONE -> preparePureReverseHold(state, -1)
                    SCENARIO_HOLD_1080_MINUS_FIVE -> preparePureReverseHold(state, -5)
                    SCENARIO_REVERSE_1080 -> prepareRepresentativeReverse(state)
                    SCENARIO_SEEK_1080 -> startRepresentativeSeek(state)
                    SCENARIO_SWITCH_1080_H264_HEVC,
                    SCENARIO_SWITCH_1080_HEVC_H264 -> startRepresentativeSwitch()
                }
            }
            Phase.TARGET_FRAME -> {
                if (displayed != expectedTargetIndex) return
                if (!assertExpectedCacheCounters(state.diagnostics)) return
                if (!isRepresentativeScenario()) {
                    requestTraceCookie?.let { endAsync(TRACE_REQUEST_TO_PUBLISH, it) }
                    requestTraceCookie = null
                }
                if (scenario == SCENARIO_BACKGROUND_FOREGROUND && backgroundMeasurementPending) {
                    resumeTraceCookie?.let { endAsync(TRACE_BACKGROUND_TO_FIRST_FRAME, it) }
                    resumeTraceCookie = null
                    backgroundMeasurementPending = false
                }
                if (isRepresentativeScenario()) finishRepresentativeNow() else complete()
            }
            Phase.ADJACENT_MISS_WARMUP -> {
                if (displayed != DISTANT_FRAME) return
                requestTarget(DISTANT_FRAME - 1, expectCacheHit = false)
            }
            Phase.PREFETCH_WARMUP -> {
                if (displayed != 1) return
                waitForPrefetchThenRequest(2)
            }
            Phase.SWITCHED_FRAME -> {
                if (state.activeFileGeneration != secondFileGeneration) return
                switchTraceCookie?.let { endAsync(TRACE_SWITCH_TO_FIRST_FRAME, it) }
                switchTraceCookie = null
                if (isRepresentativeScenario()) finishRepresentativeNow() else complete()
            }
            Phase.REPRESENTATIVE_RESET -> {
                if (displayed != expectedTargetIndex) return
                representativeResetAction?.also { representativeResetAction = null }?.invoke()
            }
            Phase.REPRESENTATIVE_ACTIVE,
            Phase.REPRESENTATIVE_SETTLING,
            Phase.OPENING,
            Phase.COMPLETE -> Unit
        }
    }

    private fun startRepresentativeHold() {
        holdDelta = if (scenario.endsWith("plus-five")) 5 else 1
        holdActiveTargetNs = REPRESENTATIVE_HOLD_ACTIVE_NS
        holdAccumulatedNs = 0L
        beginRepresentativeSegment(resetMetrics = true)
        scheduleHoldTick()
    }

    private fun preparePureReverseHold(state: ViewerUiState, delta: Int) {
        val lastIndex = (state.metadata?.frameCount ?: return) - 1
        phase = Phase.REPRESENTATIVE_RESET
        expectedTargetIndex = lastIndex
        representativeResetAction = {
            holdDelta = delta
            holdActiveTargetNs = REPRESENTATIVE_HOLD_ACTIVE_NS
            holdAccumulatedNs = 0L
            beginRepresentativeSegment(resetMetrics = true)
            scheduleHoldTick()
        }
        viewer.requestFrame(lastIndex)
    }

    private fun prepareRepresentativeReverse(state: ViewerUiState) {
        val middle = (state.metadata?.frameCount ?: return) / 2
        phase = Phase.REPRESENTATIVE_RESET
        expectedTargetIndex = middle
        representativeResetAction = {
            holdDelta = 1
            holdActiveTargetNs = REPRESENTATIVE_REVERSE_ACTIVE_NS
            holdAccumulatedNs = 0L
            representativeDeadlineMs = SystemClock.elapsedRealtime() + REVERSE_DIRECTION_INTERVAL_MS
            beginRepresentativeSegment(resetMetrics = true)
            scheduleHoldTick()
        }
        viewer.requestFrame(middle)
    }

    private fun startRepresentativeSeek(state: ViewerUiState) {
        val target = ((state.metadata?.frameCount ?: return) * 4 / 5).coerceAtLeast(1)
        beginRepresentativeSegment(resetMetrics = true)
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = target
        issuedRequestCount += 1
        latestRequestedFrameIndex = target
        Trace.setCounter("ccr.requested_frame", target.toLong())
        viewer.requestFrame(target)
        recordLag(viewer.uiState)
    }

    private fun startRepresentativeSwitch() {
        beginRepresentativeSegment(resetMetrics = true)
        phase = Phase.SWITCHED_FRAME
        secondFileGeneration = null
        viewer.openVideo(fixtureUri(secondFixture()))
    }

    private fun beginRepresentativeSegment(resetMetrics: Boolean) {
        if (resetMetrics) resetRepresentativeMetrics()
        phase = Phase.REPRESENTATIVE_ACTIVE
        measurementStarted = true
        measurementActive = true
        jankMeasurementActive = true
        metricSegmentStartedNs = SystemClock.elapsedRealtimeNanos()
        lastPublicationNs = null
        counterPrevious = counterVector(viewer.uiState.diagnostics)
        lastAcceptedRequestGeneration = viewer.uiState.activeRequestGeneration
        observeForegroundTargetMetrics(viewer.uiState)
        requestTraceCookie = nextTraceCookie().also { beginAsync(TRACE_REPRESENTATIVE_SMOOTHNESS, it) }
        holdGestureGeneration = viewer.beginNavigationGesture()
        viewer.startHoldTraversal(holdDelta, requireNotNull(holdGestureGeneration))
        observeForegroundTargetMetrics(viewer.uiState)
    }

    private fun scheduleHoldTick() {
        mainHandler.postDelayed(::runHoldTick, REPEAT_INTERVAL_MS)
    }

    private fun runHoldTick() {
        if (phase != Phase.REPRESENTATIVE_ACTIVE) return
        val nowNs = SystemClock.elapsedRealtimeNanos()
        val activeNs = holdAccumulatedNs + (nowNs - metricSegmentStartedNs).coerceAtLeast(0)
        if (activeNs >= holdActiveTargetNs) {
            stopActiveMeasurementSegment()
            finishRepresentativeAfterSettled()
            return
        }
        if (scenario == SCENARIO_REVERSE_1080 && SystemClock.elapsedRealtime() >= representativeDeadlineMs) {
            holdDelta = -holdDelta
            representativeDeadlineMs += REVERSE_DIRECTION_INTERVAL_MS
            holdGestureGeneration?.let(viewer::endNavigationGesture)
            holdGestureGeneration = viewer.beginNavigationGesture()
            viewer.startHoldTraversal(holdDelta, requireNotNull(holdGestureGeneration))
        }
        val state = viewer.uiState
        val lastIndex = (state.metadata?.frameCount ?: 1) - 1
        val next = state.requestedFrameIndex + holdDelta
        if (next !in 0..lastIndex) {
            pauseRepresentativeSegment()
            val resetIndex = if (holdDelta > 0) 0 else lastIndex
            phase = Phase.REPRESENTATIVE_RESET
            expectedTargetIndex = resetIndex
            representativeResetAction = {
                beginRepresentativeSegment(resetMetrics = false)
                scheduleHoldTick()
            }
            viewer.requestFrame(resetIndex)
            return
        }
        if (latestRequestedFrameIndex != state.requestedFrameIndex) {
            issuedRequestCount += 1
            latestRequestedFrameIndex = state.requestedFrameIndex
            Trace.setCounter("ccr.requested_frame", state.requestedFrameIndex.toLong())
        }
        scheduleHoldTick()
    }

    private fun pauseRepresentativeSegment() {
        stopActiveMeasurementSegment()
    }

    private fun finishRepresentativeAfterSettled() {
        phase = Phase.REPRESENTATIVE_SETTLING
        holdGestureGeneration?.let(viewer::endNavigationGesture)
        holdGestureGeneration = null
        releaseRequestGeneration = viewer.uiState.activeRequestGeneration
        releaseVerificationActive = true
        observeReleaseAcceptance(viewer.uiState)
        val settleDeadline = SystemClock.elapsedRealtime() + REPRESENTATIVE_SETTLE_TIMEOUT_MS
        var settledObservedAtMs: Long? = null
        fun poll() {
            val state = viewer.uiState
            observeReleaseAcceptance(state)
            val settled = state.currentDecodeTarget == null &&
                state.latestPendingRequest == null &&
                state.displayedFrameIndex == state.requestedFrameIndex
            val publicationObserved = handledPublication?.third == state.diagnostics.publishedSwapCount
            val now = SystemClock.elapsedRealtime()
            if (settled && publicationObserved) {
                if (measurementActive) stopActiveMeasurementSegment()
                if (settledObservedAtMs == null) settledObservedAtMs = now
            } else {
                settledObservedAtMs = null
            }
            if (
                settledObservedAtMs?.let { now - it >= RELEASE_ACCEPTANCE_GRACE_MS } == true &&
                !measurementActive
            ) {
                releaseGraceComplete = true
                releaseVerificationActive = false
                finishRepresentativeNow()
            } else if (now >= settleDeadline) {
                releaseVerificationActive = false
                stopActiveMeasurementSegment()
                fail("REPRESENTATIVE_SETTLE_TIMEOUT")
            } else {
                mainHandler.postDelayed(::poll, REPRESENTATIVE_SETTLE_POLL_MS)
            }
        }
        poll()
    }

    private fun finishRepresentativeNow() {
        if (!measurementStarted) {
            complete()
            return
        }
        if (representativeCompletionStarted) return
        stopActiveMeasurementSegment()
        representativeCompletionStarted = true
        Thread({
            val diagnostics = viewer.diagnosticsSnapshotForTest()
            runOnUiThread {
                if (failed) return@runOnUiThread
                if (diagnostics == null) {
                    fail("REPRESENTATIVE_DIAGNOSTICS_SNAPSHOT_TIMEOUT")
                    return@runOnUiThread
                }
                finalDiagnostics = diagnostics
                accumulateCounters(diagnostics)
                counterPrevious = null
                emitRepresentativeTraceCounters(diagnostics)
                complete()
            }
        }, "ccr-benchmark-final-diagnostics").start()
    }

    private fun stopActiveMeasurementSegment() {
        if (!measurementActive) return
        val endedAtNs = SystemClock.elapsedRealtimeNanos()
        observeForegroundTargetMetrics(viewer.uiState)
        accumulateCounters(viewer.uiState.diagnostics)
        recordSegmentEndGap(endedAtNs)
        val segmentDurationNs = (endedAtNs - metricSegmentStartedNs).coerceAtLeast(0)
        activeMetricDurationNs += segmentDurationNs
        if (isSegmentedHoldScenario()) holdAccumulatedNs += segmentDurationNs
        measurementActive = false
        jankMeasurementActive = false
        lastPublicationNs = null
        holdGestureGeneration?.let(viewer::endNavigationGesture)
        holdGestureGeneration = null
        requestTraceCookie?.let { endAsync(TRACE_REPRESENTATIVE_SMOOTHNESS, it) }
        requestTraceCookie = null
    }

    private fun recordSegmentEndGap(endedAtNs: Long) {
        val gap = (endedAtNs - (lastPublicationNs ?: metricSegmentStartedNs)).coerceAtLeast(0)
        publicationGapMaxNs = maxOf(publicationGapMaxNs, gap)
    }

    private fun resetRepresentativeMetrics() {
        measurementStarted = false
        activeMetricDurationNs = 0L
        holdAccumulatedNs = 0L
        publicationCount = 0L
        publicationIntervalsNs.clear()
        publicationGapMaxNs = 0L
        requestedDisplayedLag.clear()
        acceptedTargetSequence.clear()
        issuedRequestCount = 0L
        coalescedRequestCount = 0L
        jankFrameCount = 0L
        jankCount = 0L
        foregroundDecodedCount = 0L
        prefetchHitCount = 0L
        prefetchStartedCount = 0L
        prefetchCompletedCount = 0L
        prefetchCancelledCount = 0L
        prefetchWastedCount = 0L
        prefetchEvictedBeforeUseCount = 0L
        cacheEvictionCount = 0L
        seekCount = 0L
        flushCount = 0L
        sequentialEntryCount = 0L
        sequentialFallbackCount = 0L
        sequentialOutputCount = 0L
        swapFailureCount = 0L
        outstandingForegroundTargetDepthMax = 0
        outstandingForegroundTargetSampleCount = 0L
        acceptedTargetCount = 0L
        releaseAfterAcceptedTargetCount = 0L
        lastAcceptedRequestGeneration = null
        releaseRequestGeneration = null
        releaseVerificationActive = false
        releaseGraceComplete = false
        counterObservationComplete = true
        counterCompleteness = false
        representativeCompletionStarted = false
        finalDiagnostics = null
    }

    private fun observeMeasurement(state: ViewerUiState) {
        if (measurementActive) observeForegroundTargetMetrics(state)
        if (releaseVerificationActive) observeReleaseAcceptance(state)
        val events = state.diagnostics.publicationEventHistory
            .filter { it.eventSequence > lastObservedPublicationSequence }
            .sortedBy { it.eventSequence }
        for (event in events) {
            lastObservedPublicationSequence = maxOf(lastObservedPublicationSequence, event.eventSequence)
            if (!measurementActive || event.result != PublicationResult.PUBLISHED) continue
            val previousPublicationNs = lastPublicationNs
            if (previousPublicationNs == null) {
                publicationGapMaxNs = maxOf(
                    publicationGapMaxNs,
                    (event.elapsedRealtimeNanos - metricSegmentStartedNs).coerceAtLeast(0),
                )
            } else {
                val intervalNs = (event.elapsedRealtimeNanos - previousPublicationNs).coerceAtLeast(0)
                publicationIntervalsNs += intervalNs
                publicationGapMaxNs = maxOf(publicationGapMaxNs, intervalNs)
            }
            lastPublicationNs = event.elapsedRealtimeNanos
            publicationCount += 1
        }
        if (measurementActive) {
            accumulateCounters(state.diagnostics)
        }
    }

    private fun recordLag(state: ViewerUiState) {
        val displayed = state.displayedFrameIndex ?: return
        requestedDisplayedLag += abs(state.requestedFrameIndex.toLong() - displayed.toLong())
    }

    private fun observeForegroundTargetMetrics(state: ViewerUiState) {
        val depth = (if (state.currentDecodeTarget != null) 1 else 0) +
            (if (state.latestPendingRequest != null) 1 else 0)
        outstandingForegroundTargetDepthMax = maxOf(outstandingForegroundTargetDepthMax, depth)
        outstandingForegroundTargetSampleCount += 1
        Trace.setCounter("ccr.outstanding_foreground_target_depth", depth.toLong())

        val currentGeneration = state.activeRequestGeneration ?: return
        val previousGeneration = lastAcceptedRequestGeneration
        if (previousGeneration != null) {
            if (currentGeneration < previousGeneration) {
                counterObservationComplete = false
            } else {
                val acceptedDelta = currentGeneration - previousGeneration
                acceptedTargetCount += acceptedDelta
                if (acceptedDelta > 1L) {
                    counterObservationComplete = false
                } else if (acceptedDelta == 1L) {
                    acceptedTargetSequence += state.requestedFrameIndex
                    recordLag(state)
                }
            }
        }
        lastAcceptedRequestGeneration = currentGeneration
        Trace.setCounter("ccr.accepted_target", acceptedTargetCount)
    }

    private fun observeReleaseAcceptance(state: ViewerUiState) {
        val currentGeneration = state.activeRequestGeneration ?: return
        val previousGeneration = releaseRequestGeneration ?: currentGeneration.also {
            releaseRequestGeneration = it
        }
        if (currentGeneration < previousGeneration) {
            counterObservationComplete = false
        } else {
            releaseAfterAcceptedTargetCount += currentGeneration - previousGeneration
        }
        releaseRequestGeneration = currentGeneration
        Trace.setCounter("ccr.release_after_accepted_target", releaseAfterAcceptedTargetCount)
    }

    private fun accumulateCounters(diagnostics: DecoderDiagnostics) {
        val current = counterVector(diagnostics)
        val previous = counterPrevious ?: current.also { counterPrevious = it }
        fun delta(before: Long, after: Long): Long = if (after >= before) after - before else after
        foregroundDecodedCount += delta(previous.decoded, current.decoded)
        coalescedRequestCount += delta(previous.coalesced, current.coalesced)
        prefetchHitCount += delta(previous.prefetchHit, current.prefetchHit)
        prefetchStartedCount += delta(previous.prefetchStarted, current.prefetchStarted)
        prefetchCompletedCount += delta(previous.prefetchCompleted, current.prefetchCompleted)
        prefetchCancelledCount += delta(previous.prefetchCancelled, current.prefetchCancelled)
        prefetchWastedCount += delta(previous.prefetchWasted, current.prefetchWasted)
        prefetchEvictedBeforeUseCount += delta(previous.prefetchEvictedBeforeUse, current.prefetchEvictedBeforeUse)
        cacheEvictionCount += delta(previous.cacheEviction, current.cacheEviction)
        seekCount += delta(previous.seek, current.seek)
        flushCount += delta(previous.flush, current.flush)
        sequentialEntryCount += delta(previous.sequentialEntry, current.sequentialEntry)
        sequentialFallbackCount += delta(previous.sequentialFallback, current.sequentialFallback)
        sequentialOutputCount += delta(previous.sequentialOutput, current.sequentialOutput)
        swapFailureCount += delta(previous.swapFailure, current.swapFailure)
        counterPrevious = current
    }

    private fun counterVector(value: DecoderDiagnostics) = CounterVector(
        decoded = value.foregroundDecodedFrameCount,
        coalesced = value.requestCoalescedCount,
        prefetchHit = value.prefetchCacheHit,
        prefetchStarted = value.prefetchStarted,
        prefetchCompleted = value.prefetchCompleted,
        prefetchCancelled = value.prefetchCancelled,
        prefetchWasted = value.prefetchWasted,
        prefetchEvictedBeforeUse = value.prefetchEvictedBeforeUse,
        cacheEviction = value.cacheEvictionCount,
        seek = value.seekCount,
        flush = value.flushCount,
        sequentialEntry = value.sequentialEntryCount,
        sequentialFallback = value.sequentialFallbackCount,
        sequentialOutput = value.sequentialOutputCount,
        swapFailure = value.swapFailureCount,
    )

    private fun emitRepresentativeTraceCounters(diagnostics: DecoderDiagnostics) {
        val activeNs = activeMetricDurationNs
        val activeSeconds = activeNs / 1_000_000_000.0
        val intervalsUs = publicationIntervalsNs.map { it / 1_000L }.sorted()
        val lags = requestedDisplayedLag.sorted()
        val publishedFpsMilli = if (activeSeconds > 0.0) {
            (publicationCount * 1_000.0 / activeSeconds).toLong()
        } else {
            0L
        }
        val jankRatioPpm = if (jankFrameCount > 0) jankCount * 1_000_000L / jankFrameCount else 0L
        counterCompleteness = counterObservationComplete &&
            activeMetricDurationNs > 0L &&
            publicationCount > 0L &&
            requestedDisplayedLag.isNotEmpty() &&
            (!isSegmentedHoldScenario() || (
                acceptedTargetCount > 0L &&
                    requestedDisplayedLag.size.toLong() == acceptedTargetCount &&
                    acceptedTargetSequence.size.toLong() == acceptedTargetCount &&
                    outstandingForegroundTargetSampleCount >= acceptedTargetCount &&
                    releaseGraceComplete
                ))
        Trace.setCounter("ccr.publication_interval_p50_us", intervalsUs.percentile(0.50))
        Trace.setCounter("ccr.publication_interval_p95_us", intervalsUs.percentile(0.95))
        Trace.setCounter("ccr.publication_interval_max_us", intervalsUs.maxOrNull() ?: 0L)
        Trace.setCounter("ccr.published_fps_milli", publishedFpsMilli)
        Trace.setCounter("ccr.requested_displayed_lag_p50", lags.percentile(0.50))
        Trace.setCounter("ccr.requested_displayed_lag_p95", lags.percentile(0.95))
        Trace.setCounter("ccr.requested_displayed_lag_max", lags.maxOrNull() ?: 0L)
        Trace.setCounter("ccr.publication_gap_max_us", publicationGapMaxNs / 1_000L)
        Trace.setCounter("ccr.foreground_decoded", foregroundDecodedCount)
        Trace.setCounter("ccr.issued_request", issuedRequestCount)
        Trace.setCounter("ccr.coalesced_request", coalescedRequestCount)
        Trace.setCounter("ccr.prefetch_hit", prefetchHitCount)
        Trace.setCounter("ccr.prefetch_started", prefetchStartedCount)
        Trace.setCounter("ccr.prefetch_completed", prefetchCompletedCount)
        Trace.setCounter("ccr.prefetch_cancel", prefetchCancelledCount)
        Trace.setCounter("ccr.prefetch_waste", prefetchWastedCount)
        Trace.setCounter("ccr.prefetch_evicted_before_use", prefetchEvictedBeforeUseCount)
        Trace.setCounter("ccr.cache_eviction", cacheEvictionCount)
        Trace.setCounter("ccr.seek", seekCount)
        Trace.setCounter("ccr.flush", flushCount)
        Trace.setCounter("ccr.sequential_entry", sequentialEntryCount)
        Trace.setCounter("ccr.sequential_fallback", sequentialFallbackCount)
        Trace.setCounter("ccr.sequential_output", sequentialOutputCount)
        Trace.setCounter("ccr.measurement_swap_failure", swapFailureCount)
        Trace.setCounter("ccr.jank_count", jankCount)
        Trace.setCounter("ccr.jank_ratio_ppm", jankRatioPpm)
        Trace.setCounter("ccr.outstanding_foreground_target_depth_max", outstandingForegroundTargetDepthMax.toLong())
        Trace.setCounter("ccr.accepted_target_count", acceptedTargetCount)
        Trace.setCounter("ccr.accepted_target_sequence_count", acceptedTargetSequence.size.toLong())
        Trace.setCounter("ccr.raw_lag_sample_count", requestedDisplayedLag.size.toLong())
        Trace.setCounter("ccr.outstanding_foreground_target_sample_count", outstandingForegroundTargetSampleCount)
        Trace.setCounter("ccr.release_after_accepted_target_count", releaseAfterAcceptedTargetCount)
        Trace.setCounter("ccr.raw_lag_max", lags.maxOrNull() ?: 0L)
        Trace.setCounter("ccr.hold_prefetch_started", prefetchStartedCount)
        Trace.setCounter("ccr.hold_prefetch_completed", prefetchCompletedCount)
        Trace.setCounter("ccr.counter_complete", if (counterCompleteness) 1L else 0L)
        Trace.setCounter("ccr.run_iteration", runIteration.toLong())
        Trace.setCounter("ccr.publication_count", publicationCount)
        Trace.setCounter("ccr.active_duration_ms", activeMetricDurationNs / 1_000_000L)
        Trace.setCounter("ccr.measurement_target_ms", holdActiveTargetNs / 1_000_000L)
        Trace.setCounter("ccr.valid_trace_identity", 1L)
        Trace.setCounter("ccr.run_id_hash53", identityHash53(runId))
        Trace.setCounter("ccr.trace_identity_hash53", identityHash53(traceIdentity))
        Trace.setCounter("ccr.runtime_source_hash53", identityHash53(runtimeSourceSha))
        Trace.setCounter("ccr.harness_source_hash53", identityHash53(harnessSourceSha))
        Trace.setCounter("ccr.runtime_inputs_tree_hash53", identityHash53(runtimeInputsTreeSha256))
        Trace.setCounter("ccr.app_apk_hash53", identityHash53(appApkSha256))
        Trace.setCounter("ccr.test_apk_hash53", identityHash53(testApkSha256))
        Trace.setCounter("ccr.cache_bytes", diagnostics.cacheBytes)
        Trace.setCounter("ccr.cache_peak_bytes", diagnostics.peakCacheBytes)
        Trace.setCounter("ccr.reverse_window_refill_stall", diagnostics.reverseWindowRefillStallCount)
        Trace.setCounter("ccr.reverse_window_refill_stall_max_us", diagnostics.reverseWindowRefillStallMaxUs)
        Trace.setCounter("ccr.swap_failure", diagnostics.swapFailureCount)
        Trace.setCounter("ccr.stale_discard", diagnostics.staleDiscardCount)
        Trace.setCounter("ccr.invariant_violation", diagnostics.publicationInvariantViolationCount)
    }

    private fun metricStatusSuffix(): String {
        val identity = buildString {
            append("|artifactSetRevision=").append(ARTIFACT_SET_REVISION)
            append("|runtimeSourceSha=").append(runtimeSourceSha)
            append("|harnessSourceSha=").append(harnessSourceSha)
            append("|runtimeInputsTreeSha256=").append(runtimeInputsTreeSha256)
            append("|appApkSha256=").append(appApkSha256)
            append("|testApkSha256=").append(testApkSha256)
            append("|status=PASS")
            append("|runId=").append(runId)
            append("|traceIdentity=").append(traceIdentity)
            append("|runIteration=").append(runIteration)
        }
        if (!measurementStarted) return identity
        val activeNs = activeMetricDurationNs
        val intervalsUs = publicationIntervalsNs.map { it / 1_000L }.sorted()
        val lags = requestedDisplayedLag.sorted()
        val activeSeconds = activeNs / 1_000_000_000.0
        val fps = if (activeSeconds > 0.0) publicationCount / activeSeconds else 0.0
        val ratio = if (jankFrameCount > 0) jankCount.toDouble() / jankFrameCount else 0.0
        val metadata = viewer.uiState.metadata
        val diagnostics = finalDiagnostics ?: viewer.uiState.diagnostics
        val runtime = Runtime.getRuntime()
        val memory = Debug.MemoryInfo().also(Debug::getMemoryInfo)
        return identity + buildString {
            append("|segmented=").append(isSegmentedHoldScenario())
            append("|activeMs=").append(activeNs / 1_000_000L)
            append("|measurementTargetMs=").append(holdActiveTargetNs / 1_000_000L)
            append("|published=").append(publicationCount)
            append("|fps=").append(String.format(Locale.ROOT, "%.3f", fps))
            append("|intervalP50Us=").append(intervalsUs.percentile(0.50))
            append("|intervalP95Us=").append(intervalsUs.percentile(0.95))
            append("|intervalMaxUs=").append(intervalsUs.maxOrNull() ?: 0L)
            append("|gapMaxUs=").append(publicationGapMaxNs / 1_000L)
            append("|lagP50=").append(lags.percentile(0.50))
            append("|lagP95=").append(lags.percentile(0.95))
            append("|lagMax=").append(lags.maxOrNull() ?: 0L)
            append("|foregroundDecoded=").append(foregroundDecodedCount)
            append("|issued=").append(issuedRequestCount)
            append("|coalesced=").append(coalescedRequestCount)
            append("|prefetchHit=").append(prefetchHitCount)
            append("|prefetchStarted=").append(prefetchStartedCount)
            append("|prefetchCompleted=").append(prefetchCompletedCount)
            append("|prefetchCancel=").append(prefetchCancelledCount)
            append("|prefetchWaste=").append(prefetchWastedCount)
            append("|prefetchEvictedBeforeUse=").append(prefetchEvictedBeforeUseCount)
            append("|cacheEviction=").append(cacheEvictionCount)
            append("|seek=").append(seekCount)
            append("|flush=").append(flushCount)
            append("|sequentialEntry=").append(sequentialEntryCount)
            append("|sequentialFallback=").append(sequentialFallbackCount)
            append("|sequentialOutput=").append(sequentialOutputCount)
            append("|swapFailure=").append(swapFailureCount)
            append("|jank=").append(jankCount).append('/').append(jankFrameCount)
            append("|jankRatio=").append(String.format(Locale.ROOT, "%.6f", ratio))
            append("|outstandingForegroundTargetDepthMax=").append(outstandingForegroundTargetDepthMax)
            append("|acceptedTargetCount=").append(acceptedTargetCount)
            append("|acceptedTargetSequenceCount=").append(acceptedTargetSequence.size)
            append("|acceptedTargetSequenceSha256=").append(acceptedTargetSequenceSha256())
            append("|rawLagSampleCount=").append(requestedDisplayedLag.size)
            append("|outstandingForegroundTargetSampleCount=")
                .append(outstandingForegroundTargetSampleCount)
            append("|releaseAfterAcceptedTargetCount=").append(releaseAfterAcceptedTargetCount)
            append("|holdPrefetchStarted=").append(prefetchStartedCount)
            append("|holdPrefetchCompleted=").append(prefetchCompletedCount)
            append("|codecComponent=").append(safeMetricToken(metadata?.codecComponent))
            append("|hardwareAccelerated=").append(metadata?.hardwareAccelerated == true)
            append("|canonicalFrameBytes=").append(diagnostics.canonicalFrameBytes)
            append("|cacheBudgetBytes=").append(diagnostics.cacheBudgetBytes)
            append("|cacheBytes=").append(diagnostics.cacheBytes)
            append("|peakCacheBytes=").append(diagnostics.peakCacheBytes)
            append("|cacheEntryCount=").append(diagnostics.cacheEntryCount)
            append("|peakCacheEntryCount=").append(diagnostics.peakCacheEntryCount)
            append("|cacheRejectionCount=").append(diagnostics.cacheRejectionCount)
            append("|cacheThrashCount=").append(diagnostics.cacheThrashCount)
            append("|liveTextureCount=").append(diagnostics.liveTextureCount)
            append("|peakLiveTextureCount=").append(diagnostics.peakLiveTextureCount)
            append("|textureDoubleReleaseCount=").append(diagnostics.textureDoubleReleaseCount)
            append("|reverseWindowBuildCount=").append(diagnostics.reverseWindowBuildCount)
            append("|reverseWindowHitCount=").append(diagnostics.reverseWindowHitCount)
            append("|reverseWindowSeekCount=").append(diagnostics.reverseWindowSeekCount)
            append("|reverseWindowRefillCount=").append(diagnostics.reverseWindowRefillCount)
            append("|reverseWindowInitialReadyCount=").append(diagnostics.reverseWindowInitialReadyCount)
            append("|reverseWindowRollingAppendRefillCount=")
                .append(diagnostics.reverseWindowRollingAppendRefillCount)
            append("|reverseWindowRefillNeeded=").append(diagnostics.reverseWindowRefillNeeded)
            append("|reverseWindowRefillStallCount=").append(diagnostics.reverseWindowRefillStallCount)
            append("|reverseWindowRefillStallMaxUs=").append(diagnostics.reverseWindowRefillStallMaxUs)
            append("|reverseWindowRefillStallOver250MsCount=")
                .append(diagnostics.reverseWindowRefillStallOver250MsCount)
            append("|staleDiscardCount=").append(diagnostics.staleDiscardCount)
            append("|staleBeforeSwapCount=").append(diagnostics.staleBeforeSwapCount)
            append("|surfaceInvalidCount=").append(diagnostics.surfaceInvalidCount)
            append("|publicationInvariantViolationCount=")
                .append(diagnostics.publicationInvariantViolationCount)
            append("|decoderRecreateCount=").append(diagnostics.decoderRecreateCount)
            append("|javaUsedBytes=").append(runtime.totalMemory() - runtime.freeMemory())
            append("|nativeAllocatedBytes=").append(Debug.getNativeHeapAllocatedSize())
            append("|totalPssBytes=").append(memory.totalPss.toLong() * 1_024L)
            append("|gpuMetricAvailability=UNKNOWN")
            append("|counterComplete=").append(counterCompleteness)
        }
    }

    private fun safeMetricToken(value: String?): String = value
        ?.takeIf { it.matches(SAFE_METRIC_TOKEN_PATTERN) }
        ?: "UNKNOWN"

    private fun readHarnessIdentity(source: Intent): Boolean {
        runId = source.getStringExtra(EXTRA_RUN_ID).orEmpty()
        runtimeSourceSha = source.getStringExtra(EXTRA_RUNTIME_SOURCE_SHA).orEmpty()
        harnessSourceSha = source.getStringExtra(EXTRA_HARNESS_SOURCE_SHA).orEmpty()
        runtimeInputsTreeSha256 = source.getStringExtra(EXTRA_RUNTIME_INPUTS_TREE_SHA256).orEmpty()
        appApkSha256 = source.getStringExtra(EXTRA_APP_APK_SHA256).orEmpty()
        testApkSha256 = source.getStringExtra(EXTRA_TEST_APK_SHA256).orEmpty()
        traceIdentity = source.getStringExtra(EXTRA_TRACE_IDENTITY).orEmpty()
        runIteration = source.getIntExtra(EXTRA_RUN_ITERATION, 0)
        val installedAppSha256 = runCatching { sha256(File(applicationInfo.sourceDir)) }.getOrNull()
        return source.getIntExtra(EXTRA_ARTIFACT_SET_REVISION, 0) == ARTIFACT_SET_REVISION &&
            runId.matches(RUN_ID_PATTERN) &&
            runtimeSourceSha == EXPECTED_RUNTIME_SOURCE_SHA &&
            BuildConfig.COMMIT_SHA == EXPECTED_RUNTIME_SOURCE_SHA &&
            harnessSourceSha.matches(GIT_SHA_PATTERN) &&
            runtimeInputsTreeSha256.matches(SHA256_PATTERN) &&
            runtimeInputsTreeSha256 == EXPECTED_RUNTIME_INPUTS_TREE_SHA256 &&
            appApkSha256.matches(SHA256_PATTERN) &&
            testApkSha256.matches(SHA256_PATTERN) &&
            installedAppSha256 == appApkSha256 &&
            traceIdentity.matches(TRACE_IDENTITY_PATTERN) &&
            runIteration > 0
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }
    }

    private fun identityHash53(value: String): Long {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.US_ASCII))
        var prefix = 0L
        repeat(7) { index -> prefix = (prefix shl 8) or (digest[index].toLong() and 0xffL) }
        return prefix ushr 3
    }

    private fun acceptedTargetSequenceSha256(): String = MessageDigest.getInstance("SHA-256")
        .digest(acceptedTargetSequence.joinToString(",").toByteArray(StandardCharsets.US_ASCII))
        .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }

    private fun List<Long>.percentile(fraction: Double): Long {
        if (isEmpty()) return 0L
        return this[(ceil(size * fraction).toInt() - 1).coerceIn(0, lastIndex)]
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

    private fun startDirectionalPrefetchWarmup() {
        phase = Phase.PREFETCH_WARMUP
        latestRequestedFrameIndex = 1
        Trace.setCounter("ccr.requested_frame", 1)
        viewer.moveBy(1)
    }

    private fun requestDirectionalTarget(delta: Int) {
        val lastIndex = (viewer.uiState.metadata?.frameCount ?: 1) - 1
        val target = (viewer.uiState.requestedFrameIndex + delta).coerceIn(0, lastIndex)
        phase = Phase.TARGET_FRAME
        expectedTargetIndex = target
        latestRequestedFrameIndex = target
        expectedCacheHit = null
        cacheHitBaseline = viewer.uiState.diagnostics.cacheHitCount
        cacheMissBaseline = viewer.uiState.diagnostics.cacheMissCount
        requestTraceCookie = nextTraceCookie().also { beginAsync(TRACE_REQUEST_TO_PUBLISH, it) }
        Trace.setCounter("ccr.requested_frame", target.toLong())
        viewer.moveBy(delta)
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
        holdGestureGeneration = viewer.beginNavigationGesture()
        viewer.startHoldTraversal(1, requireNotNull(holdGestureGeneration))
    }

    private fun stopLongPressAtAcceptedTarget(state: ViewerUiState) {
        if (
            scenario != SCENARIO_LONG_PRESS ||
            phase != Phase.TARGET_FRAME ||
            state.requestedFrameIndex != LONG_PRESS_LAST_FRAME ||
            state.currentDecodeTarget != LONG_PRESS_LAST_FRAME
        ) return
        holdGestureGeneration?.let(viewer::endNavigationGesture)
        holdGestureGeneration = null
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
        Trace.setCounter("ccr.prefetch_started_total", diagnostics.prefetchStarted)
        Trace.setCounter("ccr.prefetch_completed_total", diagnostics.prefetchCompleted)
        Trace.setCounter("ccr.prefetch_cancelled", diagnostics.prefetchCancelled)
        Trace.setCounter("ccr.prefetch_wasted", diagnostics.prefetchWasted)
        Trace.setCounter("ccr.prefetch_evicted_before_use_total", diagnostics.prefetchEvictedBeforeUse)
        Trace.setCounter("ccr.cache_bytes", diagnostics.cacheBytes)
        Trace.setCounter("ccr.cache_peak_bytes", diagnostics.peakCacheBytes)
        Trace.setCounter("ccr.reverse_window_refill_stall", diagnostics.reverseWindowRefillStallCount)
        Trace.setCounter("ccr.reverse_window_refill_stall_max_us", diagnostics.reverseWindowRefillStallMaxUs)
        Trace.setCounter("ccr.seek_total", diagnostics.seekCount)
        Trace.setCounter("ccr.flush_total", diagnostics.flushCount)
        Trace.setCounter("ccr.sequential_entry_total", diagnostics.sequentialEntryCount)
        Trace.setCounter("ccr.sequential_fallback_total", diagnostics.sequentialFallbackCount)
        Trace.setCounter("ccr.sequential_output_total", diagnostics.sequentialOutputCount)
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
        statusView.updateStatus(status(SUFFIX_COMPLETE) + metricStatusSuffix())
        endIdentityTrace()
    }

    private fun fail(code: String) {
        if (failed) return
        failed = true
        statusView.updateStatus(status("failed-$code"))
        endIdentityTrace()
    }

    private fun endIdentityTrace() {
        identityTraceCookie?.let { endAsync("$TRACE_RUN_IDENTITY_PREFIX:$traceIdentity", it) }
        identityTraceCookie = null
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
        SCENARIO_HOLD_720_PLUS_ONE,
        SCENARIO_HOLD_720_PLUS_FIVE -> REPRESENTATIVE_720_H264_BFRAMES
        SCENARIO_HOLD_1080_PLUS_ONE,
        SCENARIO_HOLD_1080_PLUS_FIVE,
        SCENARIO_HOLD_1080_MINUS_ONE,
        SCENARIO_HOLD_1080_MINUS_FIVE,
        SCENARIO_REVERSE_1080,
        SCENARIO_SEEK_1080 -> REPRESENTATIVE_1080_H264_BFRAMES
        SCENARIO_SWITCH_1080_HEVC_H264 -> REPRESENTATIVE_1080_SWITCH_HEVC
        SCENARIO_SWITCH_1080_H264_HEVC -> REPRESENTATIVE_1080_SWITCH_H264
        SCENARIO_SWITCH_HEVC_H264, SCENARIO_SWITCH_HEVC_HEVC -> HEVC_FIXTURE
        else -> H264_FIXTURE
    }

    private fun secondFixture(): String = when (scenario) {
        SCENARIO_SWITCH_1080_H264_HEVC -> REPRESENTATIVE_1080_SWITCH_HEVC
        SCENARIO_SWITCH_1080_HEVC_H264 -> REPRESENTATIVE_1080_SWITCH_H264
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
        jankStats?.isTrackingEnabled = false
        mainHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    private fun isRepresentativeScenario(): Boolean = scenario in REPRESENTATIVE_SCENARIOS

    private fun isSegmentedHoldScenario(): Boolean = scenario in REPRESENTATIVE_HOLD_SCENARIOS

    companion object {
        const val EXTRA_SCENARIO = "benchmark-scenario"
        const val EXTRA_RUN_ID = "benchmark-run-id"
        const val EXTRA_RUNTIME_SOURCE_SHA = "benchmark-runtime-source-sha"
        const val EXTRA_HARNESS_SOURCE_SHA = "benchmark-harness-source-sha"
        const val EXTRA_RUNTIME_INPUTS_TREE_SHA256 = "benchmark-runtime-inputs-tree-sha256"
        const val EXTRA_APP_APK_SHA256 = "benchmark-app-apk-sha256"
        const val EXTRA_TEST_APK_SHA256 = "benchmark-test-apk-sha256"
        const val EXTRA_TRACE_IDENTITY = "benchmark-trace-identity"
        const val EXTRA_RUN_ITERATION = "benchmark-run-iteration"
        const val EXTRA_ARTIFACT_SET_REVISION = "benchmark-artifact-set-revision"
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
        const val SCENARIO_HOLD_720_PLUS_ONE = "720p-hold-plus-one"
        const val SCENARIO_HOLD_720_PLUS_FIVE = "720p-hold-plus-five"
        const val SCENARIO_HOLD_1080_PLUS_ONE = "1080p-hold-plus-one"
        const val SCENARIO_HOLD_1080_PLUS_FIVE = "1080p-hold-plus-five"
        const val SCENARIO_HOLD_1080_MINUS_ONE = "1080p-hold-minus-one"
        const val SCENARIO_HOLD_1080_MINUS_FIVE = "1080p-hold-minus-five"
        const val SCENARIO_REVERSE_1080 = "1080p-direction-reverse"
        const val SCENARIO_SEEK_1080 = "1080p-distant-seek"
        const val SCENARIO_SWITCH_1080_H264_HEVC = "1080p-switch-h264-hevc"
        const val SCENARIO_SWITCH_1080_HEVC_H264 = "1080p-switch-hevc-h264"

        const val TRACE_OPEN_TO_INDEX = "ccr.open_to_index"
        const val TRACE_OPEN_TO_FIRST_FRAME = "ccr.open_to_first_frame"
        const val TRACE_REQUEST_TO_PUBLISH = "ccr.request_to_publish"
        const val TRACE_SWITCH_TO_FIRST_FRAME = "ccr.switch_to_first_frame"
        const val TRACE_FIXTURE_ENTRY = "ccr.fixture_entry"
        const val TRACE_BACKGROUND_TO_FIRST_FRAME = "ccr.background_to_first_frame"
        const val TRACE_REPRESENTATIVE_SMOOTHNESS = "ccr.representative_smoothness"
        const val TRACE_RUN_IDENTITY_PREFIX = "ccr.run_identity"

        private const val H264_FIXTURE = "burst.mp4"
        private const val H264_SECOND_FIXTURE = "h264-ip.mp4"
        private const val HEVC_FIXTURE = "hevc-main8.mp4"
        private const val REPRESENTATIVE_720_H264_BFRAMES = "720p-h264-bframes.mp4"
        private const val REPRESENTATIVE_1080_H264_BFRAMES = "1080p-h264-bframes.mp4"
        private const val REPRESENTATIVE_1080_H264_LONG_GOP = "1080p-h264-long-gop.mp4"
        private const val REPRESENTATIVE_1080_HEVC_MAIN8 = "1080p-hevc-main8.mp4"
        private const val REPRESENTATIVE_1080_VFR = "1080p-vfr.mp4"
        private const val REPRESENTATIVE_1080_SWITCH_H264 = "1080p-switch-a.mp4"
        private const val REPRESENTATIVE_1080_SWITCH_HEVC = "1080p-switch-b.mp4"
        private const val LONG_PRESS_LAST_FRAME = 30
        private const val DISTANT_FRAME = 36
        private const val REPEAT_INTERVAL_MS = 50L
        private const val REPRESENTATIVE_HOLD_ACTIVE_NS = 30_000_000_000L
        private const val REPRESENTATIVE_REVERSE_ACTIVE_NS = 30_000_000_000L
        private const val REVERSE_DIRECTION_INTERVAL_MS = 5_000L
        private const val REPRESENTATIVE_SETTLE_TIMEOUT_MS = 10_000L
        private const val REPRESENTATIVE_SETTLE_POLL_MS = 50L
        private const val RELEASE_ACCEPTANCE_GRACE_MS = 500L
        private const val ENTRY_TRACE_COOKIE = 1L
        private const val ARTIFACT_SET_REVISION = 3
        private const val EXPECTED_RUNTIME_SOURCE_SHA = "bd3a803a1f13584f578357fcc60dce8abf2c2200"
        private const val EXPECTED_RUNTIME_INPUTS_TREE_SHA256 =
            "1d1f46d89c73f537d2dd496d8717b23323d3ce59b36ebdc39f618aa8107239fd"
        private val RUN_ID_PATTERN = Regex("[A-Za-z0-9._:-]{1,80}")
        private val TRACE_IDENTITY_PATTERN = Regex("[A-Za-z0-9._:-]{1,120}")
        private val GIT_SHA_PATTERN = Regex("[0-9a-f]{40}")
        private val SAFE_METRIC_TOKEN_PATTERN = Regex("[A-Za-z0-9._-]{1,96}")
        private val SHA256_PATTERN = Regex("[0-9a-f]{64}")
        private val REPRESENTATIVE_HOLD_SCENARIOS = setOf(
            SCENARIO_HOLD_720_PLUS_ONE,
            SCENARIO_HOLD_720_PLUS_FIVE,
            SCENARIO_HOLD_1080_PLUS_ONE,
            SCENARIO_HOLD_1080_PLUS_FIVE,
            SCENARIO_HOLD_1080_MINUS_ONE,
            SCENARIO_HOLD_1080_MINUS_FIVE,
            SCENARIO_REVERSE_1080,
        )
        private val REPRESENTATIVE_SCENARIOS = REPRESENTATIVE_HOLD_SCENARIOS + setOf(
            SCENARIO_SEEK_1080,
            SCENARIO_SWITCH_1080_H264_HEVC,
            SCENARIO_SWITCH_1080_HEVC_H264,
        )
        private val REQUIRED_FIXTURES = listOf(
            H264_FIXTURE,
            H264_SECOND_FIXTURE,
            HEVC_FIXTURE,
            REPRESENTATIVE_720_H264_BFRAMES,
            REPRESENTATIVE_1080_H264_BFRAMES,
            REPRESENTATIVE_1080_H264_LONG_GOP,
            REPRESENTATIVE_1080_HEVC_MAIN8,
            REPRESENTATIVE_1080_VFR,
            REPRESENTATIVE_1080_SWITCH_H264,
            REPRESENTATIVE_1080_SWITCH_HEVC,
        )

        private fun beginAsync(name: String, cookie: Long) {
            Trace.beginAsyncSection(name, cookie.toInt())
        }

        private fun endAsync(name: String, cookie: Long) {
            Trace.endAsyncSection(name, cookie.toInt())
        }
    }
}
