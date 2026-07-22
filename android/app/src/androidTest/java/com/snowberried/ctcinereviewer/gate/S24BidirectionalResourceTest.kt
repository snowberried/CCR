package com.snowberried.ctcinereviewer.gate

import android.content.Context
import android.content.Intent
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.BuildConfig
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.validation.ValidationHarnessIdentity
import com.snowberried.ctcinereviewer.validation.ValidationHarnessV2
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class S24BidirectionalResourceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun tenMinuteBidirectionalCacheResource() {
        assumeTrue(
            "S24 Ultra resource gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        val requestedMinutes = requestedMinutes()
        val identity = ValidationHarnessV2.requireIdentity(context, instrumentation.context)
        val startedAtNs = SystemClock.elapsedRealtimeNanos()
        val harness = ResourceHarness(context)
        val accounting = ResourceAccounting()
        val memoryTimeSeries = JSONArray()
        val diagnosticsTimeSeries = JSONArray()
        val codecComponents = linkedMapOf("H264" to linkedSetOf<String>(), "HEVC" to linkedSetOf())
        val strideCounts = linkedMapOf(1 to 0, 5 to 0, -1 to 0, -5 to 0)
        val codecOperationCounts = linkedMapOf("H264" to 0, "HEVC" to 0)
        var operations = 0
        var codecSwitches = 0
        var latest = DecoderDiagnostics()
        var measurementStartedMs = 0L
        var nextSampleMs = Long.MAX_VALUE

        fun sample(codec: String, reason: String) {
            val elapsedMs = (SystemClock.elapsedRealtime() - measurementStartedMs).coerceAtLeast(0L)
            memoryTimeSeries.put(memorySample(context, elapsedMs, operations, codec, reason))
            diagnosticsTimeSeries.put(diagnosticsSample(latest, elapsedMs, operations, codec, reason))
            nextSampleMs = SystemClock.elapsedRealtime() + SAMPLE_INTERVAL_MS
        }

        fun open(codec: CodecSpec): ContainerMetadata {
            val observed = harness.open(codec.fixture, codec.mime)
            latest = observed.diagnostics
            accounting.observeOpen(latest)
            codecComponents.getValue(codec.label) += observed.metadata.codecComponent
            sample(codec.label, if (codecSwitches == 0 && operations == 0) "initial-open" else "codec-switch")
            return observed.metadata
        }

        fun runTraversal(codec: CodecSpec, metadata: ContainerMetadata, deadlineMs: Long?) {
            assertTrue("fixture is too short for traversal contract", metadata.frameCount > MAX_TRAVERSAL_INDEX)
            var index = 0
            for (stride in TRAVERSAL_STRIDES) {
                val reverseGesture = if (stride < 0) harness.beginReverseGesture() else null
                try {
                    repeat(STEPS_PER_STRIDE) {
                        if (deadlineMs != null && SystemClock.elapsedRealtime() >= deadlineMs) return
                        index += stride
                        val observed = harness.requestHold(index, stride, reverseGesture)
                        latest = observed.diagnostics
                        accounting.observeHoldCompletion(latest)
                        operations += 1
                        strideCounts[stride] = strideCounts.getValue(stride) + 1
                        codecOperationCounts[codec.label] = codecOperationCounts.getValue(codec.label) + 1
                        if (SystemClock.elapsedRealtime() >= nextSampleMs) sample(codec.label, "periodic")
                    }
                } finally {
                    reverseGesture?.let(harness::endReverseGesture)
                }
            }
            assertEquals("traversal did not return to its start", 0, index)
        }

        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val outcome = runCatching {
            harness.start()
            measurementStartedMs = SystemClock.elapsedRealtime()
            nextSampleMs = measurementStartedMs
            val deadlineMs = measurementStartedMs + (requestedMinutes * 60_000.0).toLong().coerceAtLeast(1L)

            var codec = H264
            var metadata = open(codec)
            runTraversal(codec, metadata, deadlineMs = null)

            codec = HEVC
            codecSwitches += 1
            metadata = open(codec)
            runTraversal(codec, metadata, deadlineMs = null)

            while (SystemClock.elapsedRealtime() < deadlineMs) {
                codec = if (codec == H264) HEVC else H264
                codecSwitches += 1
                metadata = open(codec)
                runTraversal(codec, metadata, deadlineMs)
            }

            assertTrue("media actor did not become idle", harness.awaitActorIdle())
            latest = harness.diagnosticsSnapshot()
            accounting.observeFinal(latest)
            sample(codec.label, "final")
            assertTrue("no completion-driven operations", operations > 0)
            assertTrue("H264 traversal missing", codecOperationCounts.getValue("H264") > 0)
            assertTrue("HEVC traversal missing", codecOperationCounts.getValue("HEVC") > 0)
            assertTrue("codec transition missing", codecSwitches > 0)
            strideCounts.forEach { (stride, count) -> assertTrue("stride $stride missing", count > 0) }
            assertEquals("source opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
            accounting.assertNoViolations()
        }

        if (harness.started) {
            latest = harness.diagnosticsSnapshot()
            accounting.capture(latest)
            if (measurementStartedMs > 0L && outcome.isFailure) {
                sample("UNKNOWN", "failure-final")
            }
        }
        val finishedAtNs = SystemClock.elapsedRealtimeNanos()
        val reportOutcome = runCatching {
            writeReport(
                identity = identity,
                outcome = outcome,
                startedAtNs = startedAtNs,
                finishedAtNs = finishedAtNs,
                requestedMinutes = requestedMinutes,
                measurementStartedMs = measurementStartedMs,
                operations = operations,
                codecSwitches = codecSwitches,
                strideCounts = strideCounts,
                codecOperationCounts = codecOperationCounts,
                codecComponents = codecComponents,
                memoryTimeSeries = memoryTimeSeries,
                diagnosticsTimeSeries = diagnosticsTimeSeries,
                latest = latest,
                accounting = accounting,
            )
        }
        harness.close()
        outcome.exceptionOrNull()?.let { failure ->
            reportOutcome.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
        reportOutcome.getOrThrow()
    }

    private fun requestedMinutes(): Double {
        val raw = InstrumentationRegistry.getArguments().getString(ARG_RESOURCE_MINUTES)
        val value = raw?.toDoubleOrNull() ?: DEFAULT_RESOURCE_MINUTES
        require(value.isFinite() && value > 0.0 && value <= DEFAULT_RESOURCE_MINUTES) {
            "$ARG_RESOURCE_MINUTES must be in (0, $DEFAULT_RESOURCE_MINUTES]"
        }
        return value
    }

    private fun writeReport(
        identity: ValidationHarnessIdentity,
        outcome: Result<Unit>,
        startedAtNs: Long,
        finishedAtNs: Long,
        requestedMinutes: Double,
        measurementStartedMs: Long,
        operations: Int,
        codecSwitches: Int,
        strideCounts: Map<Int, Int>,
        codecOperationCounts: Map<String, Int>,
        codecComponents: Map<String, Set<String>>,
        memoryTimeSeries: JSONArray,
        diagnosticsTimeSeries: JSONArray,
        latest: DecoderDiagnostics,
        accounting: ResourceAccounting,
    ) {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val report = JSONObject()
            .put("schemaVersion", 1)
            .put("kind", "alpha5-bidirectional-resource-10m")
            .put("status", if (outcome.isSuccess) "PASS" else "FAIL")
            .put("applicationId", context.packageName)
            .put("appVersionName", packageInfo.versionName)
            .put("appVersionCode", packageInfo.longVersionCode)
            .put("appCommitSha", BuildConfig.COMMIT_SHA)
            .put("device", JSONObject()
                .put("manufacturer", Build.MANUFACTURER)
                .put("model", Build.MODEL)
                .put("sdk", Build.VERSION.SDK_INT)
                .put("securityPatch", Build.VERSION.SECURITY_PATCH))
            .put("syntheticOnly", true)
            .put("containsRealMediaMetadata", false)
            .put("mediaFileNameIncluded", false)
            .put("mediaUriIncluded", false)
            .put("mediaPathIncluded", false)
            .put("requestScheduling", "COMPLETION_DRIVEN_ONE_IN_FLIGHT")
            .put("requestedDurationMinutes", requestedMinutes)
            .put(
                "actualMeasurementDurationMs",
                if (measurementStartedMs == 0L) 0L else SystemClock.elapsedRealtime() - measurementStartedMs,
            )
            .put("operations", operations)
            .put("codecSwitches", codecSwitches)
            .put("strideOperationCounts", JSONObject().apply {
                strideCounts.forEach { (stride, count) -> put(if (stride > 0) "+$stride" else "$stride", count) }
            })
            .put("codecOperationCounts", JSONObject(codecOperationCounts))
            .put("codecComponents", JSONObject().apply {
                codecComponents.forEach { (codec, components) -> put(codec, JSONArray(components.toList())) }
            })
            .put("requiredCacheBudgetBytes", REQUIRED_CACHE_BUDGET_BYTES)
            .put("memoryMeasurement", "IN_SESSION_DEBUG_MEMORYINFO_TIME_SERIES")
            .put("graphicsMemoryMeaning", "Debug.MemoryInfo summary.graphics PSS proxy; not physical GPU allocation")
            .put("memoryTimeSeries", memoryTimeSeries)
            .put("diagnosticsTimeSeries", diagnosticsTimeSeries)
            .put("finalDiagnostics", diagnosticsJson(latest))
            .put("resourceAssessment", accounting.report())
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
            .put("pinnedIdentity", JSONObject()
                .put("R", identity.runtimeSourceSha)
                .put("H", identity.harnessSourceSha)
                .put("T", identity.runtimeInputsTreeSha256)
                .put("M", identity.artifactSetRevision)
                .put("APK", JSONObject()
                    .put("appSha256", identity.appSha256)
                    .put("testApkSha256", identity.testApkSha256)))
        ValidationHarnessV2.putReportIdentity(
            report = report,
            identity = identity,
            startedAtElapsedRealtimeNs = startedAtNs,
            finishedAtElapsedRealtimeNs = finishedAtNs,
            testCount = 1,
            instrumentationExpectedTestCount = 1,
        )
        outcome.exceptionOrNull()?.let {
            report.put("failure", JSONObject()
                .put("type", it.javaClass.simpleName)
                .put("code", "RESOURCE_GATE_FAILED"))
        }
        File(context.filesDir, REPORT_FILE).writeText(report.toString(2))
    }

    private data class CodecSpec(val label: String, val fixture: String, val mime: String)

    companion object {
        const val REPORT_FILE = "s24-alpha5-resource-10m-report.json"
        private const val ARG_RESOURCE_MINUTES = "alpha5.resourceMinutes"
        private const val DEFAULT_RESOURCE_MINUTES = 10.0
        private const val REQUIRED_CACHE_BUDGET_BYTES = 64L * 1024L * 1024L
        private const val SAMPLE_INTERVAL_MS = 5_000L
        private const val STEPS_PER_STRIDE = 12
        private const val MAX_TRAVERSAL_INDEX = 72
        private val TRAVERSAL_STRIDES = intArrayOf(1, 5, -1, -5)
        private val H264 = CodecSpec("H264", "1080p-switch-a.mp4", MediaFormat.MIMETYPE_VIDEO_AVC)
        private val HEVC = CodecSpec("HEVC", "1080p-switch-b.mp4", MediaFormat.MIMETYPE_VIDEO_HEVC)
    }
}

private data class ResourceObservation(
    val metadata: ContainerMetadata,
    val diagnostics: DecoderDiagnostics,
)

private class ResourceHarness(private val context: Context) {
    private var scenario: ActivityScenario<GateActivity>? = null
    private lateinit var activity: GateActivity
    private var metadata: ContainerMetadata? = null
    var started = false
        private set

    fun start() {
        val launched = ActivityScenario.launch<GateActivity>(
            Intent(context, GateActivity::class.java).putExtra(GateActivity.EXTRA_PILOT_MODE, true),
        )
        scenario = launched
        val ready = CountDownLatch(1)
        launched.onActivity {
            activity = it
            ready.countDown()
        }
        assertTrue("GateActivity unavailable", ready.await(5, TimeUnit.SECONDS))
        assertTrue("EGL Surface was not created", activity.awaitSurface())
        started = true
    }

    fun open(fixture: String, expectedMime: String): ResourceObservation {
        activity.clearResults()
        onMain { activity.openFixture(uri(fixture)) }
        requireNotNull(activity.awaitIndex(30)) { "INDEX_TIMEOUT" }
        val opened = requireNotNull(activity.awaitMetadata(30)) { "METADATA_TIMEOUT" }
        assertEquals(expectedMime, opened.mime)
        assertTrue("hardware decoder required", opened.hardwareAccelerated)
        metadata = opened
        return ResourceObservation(opened, awaitPublished(0))
    }

    fun beginReverseGesture(): Long = onMain { activity.beginHoldGesture() }

    fun requestHold(index: Int, stride: Int, reverseGesture: Long?): ResourceObservation {
        activity.clearResults()
        val acceptance = onMain {
            if (stride > 0) {
                require(reverseGesture == null)
                activity.requestForwardSequentialFrame(index, stride)
            } else {
                activity.requestReverseSequentialFrame(index, stride, requireNotNull(reverseGesture))
            }
        }
        requireNotNull(acceptance) { "REQUEST_NOT_ACCEPTED" }
        return ResourceObservation(requireNotNull(metadata), awaitPublished(index))
    }

    fun endReverseGesture(gesture: Long) = onMain { activity.endHoldGesture(gesture) }

    private fun awaitPublished(expectedIndex: Int): DecoderDiagnostics {
        val deadlineMs = SystemClock.elapsedRealtime() + RESULT_TIMEOUT_MS
        while (SystemClock.elapsedRealtime() < deadlineMs) {
            val observed = activity.awaitResult(2) ?: continue
            when (val result = observed.result) {
                is FrameResult.Published -> {
                    assertEquals(
                        "publication belongs to a previous file generation",
                        requireNotNull(metadata).fileGeneration,
                        result.request.token.fileGeneration,
                    )
                    assertEquals(
                        "publication belongs to a superseded resource target",
                        expectedIndex,
                        result.request.requestedFrameIndex,
                    )
                    return observed.diagnostics
                }
                is FrameResult.DiscardedStale -> error("UNEXPECTED_STALE_RESULT")
                is FrameResult.Error -> error("FRAME_RESULT_ERROR")
                is FrameResult.Unsupported -> error("FRAME_RESULT_UNSUPPORTED")
            }
        }
        error("PUBLISH_TIMEOUT")
    }

    fun awaitActorIdle(): Boolean = activity.awaitActorIdle(10_000)
    fun diagnosticsSnapshot(): DecoderDiagnostics = activity.diagnosticsSnapshot()

    fun close() {
        scenario?.close()
        scenario = null
        started = false
    }

    private fun uri(fixture: String): Uri = Uri.parse("content://${context.packageName}.fixture/$fixture")

    private fun <T> onMain(action: () -> T): T {
        val latch = CountDownLatch(1)
        val result = AtomicReference<Result<T>>()
        activity.runOnUiThread {
            result.set(runCatching(action))
            latch.countDown()
        }
        assertTrue("main action timeout", latch.await(5, TimeUnit.SECONDS))
        return requireNotNull(result.get()).getOrThrow()
    }
}

private class ResourceAccounting {
    private var previousPrefetchStarted = 0L
    private var previousPrefetchCompleted = 0L
    private var staleDiscardCount = 0L
    private var staleBeforeSwapCount = 0L
    private var swapFailureCount = 0L
    private var surfaceInvalidCount = 0L
    private var invariantViolationCount = 0L
    private var doubleReleaseCount = 0L
    private var holdPrefetchStarted = 0L
    private var holdPrefetchCompleted = 0L
    private var cacheBudgetViolationCount = 0L
    private var cachePeakViolationCount = 0L
    private var maxCacheBytes = 0L
    private var maxPeakCacheBytes = 0L

    fun observeOpen(value: DecoderDiagnostics) {
        capture(value)
        previousPrefetchStarted = value.prefetchStarted
        previousPrefetchCompleted = value.prefetchCompleted
        assertHealthy(value)
    }

    fun observeHoldCompletion(value: DecoderDiagnostics) {
        holdPrefetchStarted += counterDelta(previousPrefetchStarted, value.prefetchStarted)
        holdPrefetchCompleted += counterDelta(previousPrefetchCompleted, value.prefetchCompleted)
        previousPrefetchStarted = value.prefetchStarted
        previousPrefetchCompleted = value.prefetchCompleted
        capture(value)
        assertHealthy(value)
    }

    fun observeFinal(value: DecoderDiagnostics) {
        observeHoldCompletion(value)
    }

    fun capture(value: DecoderDiagnostics) {
        staleDiscardCount = maxOf(staleDiscardCount, value.staleDiscardCount)
        staleBeforeSwapCount = maxOf(staleBeforeSwapCount, value.staleBeforeSwapCount)
        swapFailureCount = maxOf(swapFailureCount, value.swapFailureCount)
        surfaceInvalidCount = maxOf(surfaceInvalidCount, value.surfaceInvalidCount)
        invariantViolationCount = maxOf(invariantViolationCount, value.publicationInvariantViolationCount)
        doubleReleaseCount = maxOf(doubleReleaseCount, value.textureDoubleReleaseCount)
        maxCacheBytes = maxOf(maxCacheBytes, value.cacheBytes)
        maxPeakCacheBytes = maxOf(maxPeakCacheBytes, value.peakCacheBytes)
        if (value.cacheBudgetBytes != REQUIRED_CACHE_BUDGET_BYTES) cacheBudgetViolationCount += 1
        if (value.cacheBytes > REQUIRED_CACHE_BUDGET_BYTES || value.peakCacheBytes > REQUIRED_CACHE_BUDGET_BYTES) {
            cachePeakViolationCount += 1
        }
    }

    fun assertNoViolations() {
        assertEquals("stale discard", 0L, staleDiscardCount)
        assertEquals("stale before swap", 0L, staleBeforeSwapCount)
        assertEquals("swap failure", 0L, swapFailureCount)
        assertEquals("surface invalid", 0L, surfaceInvalidCount)
        assertEquals("publication invariant violation", 0L, invariantViolationCount)
        assertEquals("texture double release", 0L, doubleReleaseCount)
        assertEquals("hold prefetch started", 0L, holdPrefetchStarted)
        assertEquals("hold prefetch completed", 0L, holdPrefetchCompleted)
        assertEquals("cache budget mismatch", 0L, cacheBudgetViolationCount)
        assertEquals("cache peak exceeded", 0L, cachePeakViolationCount)
    }

    fun report(): JSONObject = JSONObject()
        .put("status", if (totalViolations() == 0L) "PASS" else "FAIL")
        .put("cacheBudgetBytes", REQUIRED_CACHE_BUDGET_BYTES)
        .put("maxObservedCacheBytes", maxCacheBytes)
        .put("maxObservedPeakCacheBytes", maxPeakCacheBytes)
        .put("staleDiscardCount", staleDiscardCount)
        .put("staleBeforeSwapCount", staleBeforeSwapCount)
        .put("swapFailureCount", swapFailureCount)
        .put("surfaceInvalidCount", surfaceInvalidCount)
        .put("publicationInvariantViolationCount", invariantViolationCount)
        .put("textureDoubleReleaseCount", doubleReleaseCount)
        .put("holdPrefetchStarted", holdPrefetchStarted)
        .put("holdPrefetchCompleted", holdPrefetchCompleted)
        .put("holdPrefetchViolationCount", holdPrefetchStarted + holdPrefetchCompleted)
        .put("cacheBudgetViolationCount", cacheBudgetViolationCount)
        .put("cachePeakViolationCount", cachePeakViolationCount)
        .put("totalViolationCount", totalViolations())

    private fun assertHealthy(value: DecoderDiagnostics) {
        assertEquals(REQUIRED_CACHE_BUDGET_BYTES, value.cacheBudgetBytes)
        assertTrue("cache bytes exceeded budget", value.cacheBytes in 0..REQUIRED_CACHE_BUDGET_BYTES)
        assertTrue("peak cache bytes exceeded budget", value.peakCacheBytes in 0..REQUIRED_CACHE_BUDGET_BYTES)
        assertEquals(0L, value.staleDiscardCount)
        assertEquals(0L, value.staleBeforeSwapCount)
        assertEquals(0L, value.swapFailureCount)
        assertEquals(0L, value.surfaceInvalidCount)
        assertEquals(0L, value.publicationInvariantViolationCount)
        assertEquals(0L, value.textureDoubleReleaseCount)
        assertEquals(value.cacheEntryCount, value.liveTextureCount)
        assertEquals(value.liveTextureCount.toLong(), value.textureCreatedCount - value.textureReleasedCount)
    }

    private fun totalViolations(): Long = staleDiscardCount + staleBeforeSwapCount + swapFailureCount +
        surfaceInvalidCount + invariantViolationCount + doubleReleaseCount + holdPrefetchStarted +
        holdPrefetchCompleted + cacheBudgetViolationCount + cachePeakViolationCount

    private fun counterDelta(before: Long, after: Long): Long = if (after >= before) after - before else after

    companion object {
        private const val REQUIRED_CACHE_BUDGET_BYTES = 64L * 1024L * 1024L
    }
}

private fun memorySample(
    context: Context,
    elapsedMs: Long,
    operations: Int,
    codec: String,
    reason: String,
): JSONObject {
    val runtime = Runtime.getRuntime()
    val memory = Debug.MemoryInfo().also(Debug::getMemoryInfo)
    return JSONObject()
        .put("elapsedMs", elapsedMs)
        .put("operations", operations)
        .put("codec", codec)
        .put("reason", reason)
        .put("javaUsedBytes", runtime.totalMemory() - runtime.freeMemory())
        .put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
        .put("totalPssBytes", memory.totalPss.toLong() * 1_024L)
        .put("graphicsPssBytes", memory.getMemoryStat("summary.graphics")?.toLongOrNull()?.times(1_024L) ?: JSONObject.NULL)
        .put("thermalStatus", context.getSystemService(PowerManager::class.java).currentThermalStatus)
}

private fun diagnosticsSample(
    value: DecoderDiagnostics,
    elapsedMs: Long,
    operations: Int,
    codec: String,
    reason: String,
): JSONObject = diagnosticsJson(value)
    .put("elapsedMs", elapsedMs)
    .put("operations", operations)
    .put("codec", codec)
    .put("reason", reason)

private fun diagnosticsJson(value: DecoderDiagnostics): JSONObject = JSONObject()
    .put("decodeOrdinal", value.decodeOrdinal)
    .put("foregroundDecodedFrameCount", value.foregroundDecodedFrameCount)
    .put("cacheBudgetBytes", value.cacheBudgetBytes)
    .put("cacheBytes", value.cacheBytes)
    .put("peakCacheBytes", value.peakCacheBytes)
    .put("cacheEntryCount", value.cacheEntryCount)
    .put("peakCacheEntryCount", value.peakCacheEntryCount)
    .put("cacheEvictionCount", value.cacheEvictionCount)
    .put("cacheRejectionCount", value.cacheRejectionCount)
    .put("cacheThrashCount", value.cacheThrashCount)
    .put("prefetchStarted", value.prefetchStarted)
    .put("prefetchCompleted", value.prefetchCompleted)
    .put("prefetchCancelled", value.prefetchCancelled)
    .put("staleDiscardCount", value.staleDiscardCount)
    .put("staleBeforeSwapCount", value.staleBeforeSwapCount)
    .put("publishedSwapCount", value.publishedSwapCount)
    .put("swapFailureCount", value.swapFailureCount)
    .put("surfaceInvalidCount", value.surfaceInvalidCount)
    .put("publicationInvariantViolationCount", value.publicationInvariantViolationCount)
    .put("textureCreatedCount", value.textureCreatedCount)
    .put("textureReleasedCount", value.textureReleasedCount)
    .put("liveTextureCount", value.liveTextureCount)
    .put("peakLiveTextureCount", value.peakLiveTextureCount)
    .put("textureDoubleReleaseCount", value.textureDoubleReleaseCount)
    .put("reverseWindowInitialReadyCount", value.reverseWindowInitialReadyCount)
    .put("reverseWindowRollingAppendRefillCount", value.reverseWindowRollingAppendRefillCount)
    .put("reverseWindowRefillNeeded", value.reverseWindowRefillNeeded)
    .put("reverseWindowRefillStallCount", value.reverseWindowRefillStallCount)
    .put("reverseWindowRefillStallMaxUs", value.reverseWindowRefillStallMaxUs)
    .put("reverseWindowRefillStallOver250MsCount", value.reverseWindowRefillStallOver250MsCount)
    .put("decoderRecreateCount", value.decoderRecreateCount)

private const val RESULT_TIMEOUT_MS = 30_000L
