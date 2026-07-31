package com.snowberried.ctcinereviewer.gate

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaFormat
import android.net.Uri
import android.os.BatteryManager
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
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class RepresentativeCachePressureTest {
    @Test
    fun cacheBudgetAndRepresentativePrefetchLimits() {
        requireS24Ultra()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val harness = RepresentativeHarness(context)
        val history = JSONArray()
        var latest = DecoderDiagnostics()
        var opened720Diagnostics = DecoderDiagnostics()
        var opened1080Diagnostics = DecoderDiagnostics()
        var reversalCancellationDelta = 0L
        val outcome = runCatching {
            harness.start()
            val opened720 = harness.open(H264_720, MediaFormat.MIMETYPE_VIDEO_AVC)
            opened720Diagnostics = opened720.diagnostics
            assertEquals(12, opened720.diagnostics.effectivePrefetchLimit)
            assertEquals(PRODUCT_CACHE_BUDGET_BYTES, opened720.diagnostics.cacheBudgetBytes)
            assertHealthy(opened720.diagnostics)
            val opened1080 = harness.open(H264_1080, MediaFormat.MIMETYPE_VIDEO_AVC)
            opened1080Diagnostics = opened1080.diagnostics
            assertEquals(4, opened1080.diagnostics.effectivePrefetchLimit)
            assertEquals(PRODUCT_CACHE_BUDGET_BYTES, opened1080.diagnostics.cacheBudgetBytes)
            assertHealthy(opened1080.diagnostics)
            val forwardIndexes = (0 until opened1080.metadata.frameCount step 5).toList()
            val reverseIndexes = (opened1080.metadata.frameCount - 1 downTo 0 step 5).toList()
            for (index in forwardIndexes) {
                val observed = harness.request(index)
                latest = observed.diagnostics
                history.put(cacheSample(index, latest).put("direction", "forward"))
                assertTrue("cache byte budget exceeded", latest.cacheBytes <= latest.cacheBudgetBytes)
                assertHealthy(latest)
            }
            val cancellationBeforeReverse = latest.prefetchCancelled
            for (index in reverseIndexes) {
                val observed = harness.request(index)
                latest = observed.diagnostics
                history.put(cacheSample(index, latest).put("direction", "reverse"))
                assertTrue("cache byte budget exceeded", latest.cacheBytes <= latest.cacheBudgetBytes)
                assertHealthy(latest)
            }
            reversalCancellationDelta = latest.prefetchCancelled - cancellationBeforeReverse
            assertTrue("direction reversal did not cancel opposite prefetch", reversalCancellationDelta > 0)
            assertTrue("media actor did not become idle", harness.awaitActorIdle())
            val displayed = reverseIndexes.last()
            val retained = harness.request(displayed)
            assertTrue("published target was not retained", retained.result.cacheHit)
            latest = retained.diagnostics
        }
        writeValidationReport(
            context = context,
            fileName = CACHE_REPORT_FILE,
            kind = "representative-cache-pressure",
            status = if (outcome.isSuccess) "PASS" else "FAIL",
            body = JSONObject()
                .put("cacheHistory", history)
                .put("decoder", diagnosticsJson(latest))
                .put("generationTransition", JSONObject()
                    .put("after720pOpen", diagnosticsJson(opened720Diagnostics))
                    .put("after1080pOpen", diagnosticsJson(opened1080Diagnostics))
                    .put("textureBalanceChecked", true))
                .put("expected720pPrefetchLimit", 12)
                .put("expected1080pPrefetchLimit", 4)
                .put("expectedProductCacheBudgetBytes", PRODUCT_CACHE_BUDGET_BYTES)
                .put("directionReversalPrefetchCancellationDelta", reversalCancellationDelta)
                .put("immediateThrashDefinition", "cacheThrashCount = prefetch evicted before first use + prefetch cache rejection")
                .put("performanceGateApplied", false),
            failure = outcome.exceptionOrNull(),
        )
        harness.close()
        outcome.getOrThrow()
    }
}

@RunWith(AndroidJUnit4::class)
class RepresentativeMemoryEnduranceTest {
    @Test
    fun single1080pCachePressureWhenRequested() {
        requireS24Ultra()
        val args = InstrumentationRegistry.getArguments()
        val minutes = args.getString(ARG_MEMORY_MINUTES)?.toIntOrNull() ?: 0
        assumeTrue("pass -e $ARG_MEMORY_MINUTES 15", minutes > 0)
        runNavigationEndurance("single-1080p-cache-pressure", minutes)
    }

    @Test
    fun codecSwitchWhenRequested() {
        requireS24Ultra()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val iterations = InstrumentationRegistry.getArguments().getString(ARG_SWITCH_ITERATIONS)?.toIntOrNull() ?: 0
        assumeTrue("pass -e $ARG_SWITCH_ITERATIONS 500", iterations > 0)
        val context = instrumentation.targetContext
        val harness = RepresentativeHarness(context)
        val samples = JSONArray()
        val codecComponents = linkedSetOf<String>()
        var latest = DecoderDiagnostics()
        val outcome = runCatching {
            harness.start()
            repeat(iterations) { iteration ->
                val hevc = iteration % 2 == 0
                val observed = harness.open(
                    if (hevc) SWITCH_HEVC else SWITCH_H264,
                    if (hevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC,
                )
                codecComponents += observed.metadata.codecComponent
                latest = observed.diagnostics
                if (iteration % RESOURCE_SAMPLE_EVERY_SWITCH == 0) {
                    samples.put(runtimeSample(context, latest).put("iteration", iteration))
                }
                assertHealthy(latest)
            }
        }
        writeValidationReport(
            context,
            CODEC_SWITCH_REPORT_FILE,
            "representative-codec-switch",
            if (outcome.isSuccess) "INCONCLUSIVE" else "FAIL",
            JSONObject()
                .put("iterations", iterations)
                .put("samples", samples)
                .put("codecComponents", JSONArray(codecComponents.toList()))
                .put("decoder", diagnosticsJson(latest))
                .put("resourceRecoveryAssessment", resourceRecoveryAssessment(latest)),
            outcome.exceptionOrNull(),
        )
        harness.close()
        outcome.getOrThrow()
    }

    @Test
    fun idleActivityRemainsZeroWhenRequested() {
        requireS24Ultra()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val minutes = InstrumentationRegistry.getArguments().getString(ARG_IDLE_MINUTES)?.toIntOrNull() ?: 0
        assumeTrue("pass -e $ARG_IDLE_MINUTES 10", minutes > 0)
        val context = instrumentation.targetContext
        val harness = RepresentativeHarness(context)
        var before = DecoderDiagnostics()
        var after = DecoderDiagnostics()
        val outcome = runCatching {
            harness.start()
            harness.open(H264_1080, MediaFormat.MIMETYPE_VIDEO_AVC)
            assertTrue("media actor did not become idle", harness.awaitActorIdle())
            harness.drainActivity()
            before = harness.diagnosticsSnapshot()
            SystemClock.sleep(TimeUnit.MINUTES.toMillis(minutes.toLong()))
            after = harness.diagnosticsSnapshot()
            assertFalse("idle publication occurred", harness.hasPublicationEvent())
            assertFalse("idle frame result occurred", harness.hasFrameResult())
            assertEquals(before.decodeOrdinal, after.decodeOrdinal)
            assertEquals(before.prefetchStarted, after.prefetchStarted)
            assertEquals(before.prefetchCompleted, after.prefetchCompleted)
            assertEquals(before.publishedSwapCount, after.publishedSwapCount)
        }
        writeValidationReport(
            context,
            IDLE_REPORT_FILE,
            "representative-idle",
            if (outcome.isSuccess) "PASS" else "FAIL",
            JSONObject()
                .put("durationMinutes", minutes)
                .put("before", diagnosticsJson(before))
                .put("after", diagnosticsJson(after)),
            outcome.exceptionOrNull(),
        )
        harness.close()
        outcome.getOrThrow()
    }

    private fun runNavigationEndurance(kind: String, minutes: Int) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val harness = RepresentativeHarness(context)
        val samples = JSONArray()
        var latest = DecoderDiagnostics()
        var codecComponent: String? = null
        var operations = 0
        val outcome = runCatching {
            harness.start()
            val opened = harness.open(H264_1080, MediaFormat.MIMETYPE_VIDEO_AVC)
            latest = opened.diagnostics
            codecComponent = opened.metadata.codecComponent
            val deadline = SystemClock.elapsedRealtime() + TimeUnit.MINUTES.toMillis(minutes.toLong())
            var nextSample = 0L
            var index = 0
            var delta = 5
            while (SystemClock.elapsedRealtime() < deadline) {
                val next = index + delta
                if (next !in 0 until opened.metadata.frameCount) {
                    delta = -delta
                } else {
                    index = next
                    latest = harness.request(index).diagnostics
                    assertTrue(latest.cacheBytes <= latest.cacheBudgetBytes)
                    assertHealthy(latest)
                    operations += 1
                }
                val now = SystemClock.elapsedRealtime()
                if (now >= nextSample) {
                    samples.put(runtimeSample(context, latest).put("operation", operations))
                    nextSample = now + SAMPLE_INTERVAL_MS
                }
            }
            assertTrue("media actor did not become idle", harness.awaitActorIdle())
            latest = harness.diagnosticsSnapshot()
            samples.put(runtimeSample(context, latest).put("operation", operations).put("sample", "final"))
        }
        writeValidationReport(
            context,
            MEMORY_REPORT_FILE,
            kind,
            if (outcome.isSuccess) "INCONCLUSIVE" else "FAIL",
            JSONObject()
                .put("durationMinutes", minutes)
                .put("operations", operations)
                .put("samples", samples)
                .put("codecComponent", codecComponent ?: JSONObject.NULL)
                .put("decoder", diagnosticsJson(latest))
                .put("plateauAssessment", "INCONCLUSIVE_UNTIL_SAMPLE_ANALYSIS")
                .put("graphicsMemoryMeaning", "Debug.MemoryInfo summary.graphics PSS proxy; not physical GPU allocation"),
            outcome.exceptionOrNull(),
        )
        harness.close()
        outcome.getOrThrow()
    }
}

@RunWith(AndroidJUnit4::class)
class RepresentativeBatteryValidationTest {
    @Test
    fun unpluggedThirtyMinuteMeasurementWhenRequested() {
        requireS24Ultra()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        val scenarioName = args.getString(ARG_BATTERY_SCENARIO) ?: ""
        val minutes = args.getString(ARG_BATTERY_MINUTES)?.toIntOrNull() ?: 0
        assumeTrue("battery scenario must be idle or navigation", scenarioName in setOf("idle", "navigation"))
        assumeTrue("pass -e $ARG_BATTERY_MINUTES 30", minutes > 0)
        val context = instrumentation.targetContext
        val harness = RepresentativeHarness(context)
        val samples = JSONArray()
        var operations = 0
        var status = "NOT_EVALUABLE"
        var reason = "USB_OR_CHARGING"
        var startBattery: Int? = null
        var endBattery: Int? = null
        var startDiagnostics = DecoderDiagnostics()
        var endDiagnostics = DecoderDiagnostics()
        var codecComponent: String? = null
        var hardwareAccelerated: Boolean? = null
        var everPluggedDuringMeasurement = false
        var pluggedAtEnd = true
        val outcome = runCatching {
            harness.start(brightness = FIXED_BRIGHTNESS)
            val opened = harness.open(H264_1080, MediaFormat.MIMETYPE_VIDEO_AVC)
            codecComponent = opened.metadata.codecComponent
            hardwareAccelerated = opened.metadata.hardwareAccelerated
            startDiagnostics = opened.diagnostics
            endDiagnostics = opened.diagnostics
            val unplugDeadline = SystemClock.elapsedRealtime() + UNPLUG_GRACE_MS
            while (plugged(context) && SystemClock.elapsedRealtime() < unplugDeadline) {
                SystemClock.sleep(1_000)
            }
            val measuredStartBattery = batteryPercent(context)
            startBattery = measuredStartBattery
            if (plugged(context) || measuredStartBattery !in 80..90) {
                reason = if (plugged(context)) "USB_OR_CHARGING" else "START_BATTERY_OUTSIDE_80_90"
                endBattery = startBattery
                pluggedAtEnd = plugged(context)
                return@runCatching
            }
            samples.put(batterySample(context, endDiagnostics).put("operations", operations).put("sample", "start"))
            val deadline = SystemClock.elapsedRealtime() + TimeUnit.MINUTES.toMillis(minutes.toLong())
            var nextSample = SystemClock.elapsedRealtime() + BATTERY_SAMPLE_INTERVAL_MS
            var nextConnectionCheck = 0L
            var index = 0
            var pattern = 0
            while (SystemClock.elapsedRealtime() < deadline) {
                if (scenarioName == "navigation") {
                    val delta = BATTERY_NAVIGATION_PATTERN[pattern++ % BATTERY_NAVIGATION_PATTERN.size]
                    index = (index + delta).coerceIn(0, opened.metadata.frameCount - 1)
                    endDiagnostics = harness.request(index).diagnostics
                    operations += 1
                    SystemClock.sleep(50)
                } else {
                    SystemClock.sleep(250)
                }
                val now = SystemClock.elapsedRealtime()
                if (now >= nextConnectionCheck) {
                    everPluggedDuringMeasurement = everPluggedDuringMeasurement || plugged(context)
                    nextConnectionCheck = now + CONNECTION_POLL_INTERVAL_MS
                }
                if (now >= nextSample) {
                    val sample = batterySample(context, endDiagnostics).put("operations", operations)
                    samples.put(sample)
                    nextSample = now + BATTERY_SAMPLE_INTERVAL_MS
                }
            }
            assertTrue("media actor did not become idle", harness.awaitActorIdle())
            endDiagnostics = harness.diagnosticsSnapshot()
            endBattery = batteryPercent(context)
            pluggedAtEnd = plugged(context)
            everPluggedDuringMeasurement = everPluggedDuringMeasurement || pluggedAtEnd
            samples.put(batterySample(context, endDiagnostics).put("operations", operations).put("sample", "end"))
            status = if (!everPluggedDuringMeasurement && !pluggedAtEnd) "EVALUABLE" else "NOT_EVALUABLE"
            reason = if (status == "EVALUABLE") "MEASUREMENT_COMPLETE_NO_DRAIN_THRESHOLD" else "USB_OR_CHARGING"
        }
        writeValidationReport(
            context,
            "representative-battery-$scenarioName-report.json",
            "representative-battery-$scenarioName",
            if (outcome.isFailure) "FAIL" else status,
            JSONObject()
                .put("reason", reason)
                .put("durationMinutes", minutes)
                .put("fixedWindowBrightness", FIXED_BRIGHTNESS)
                .put("refreshRate", harness.refreshRate())
                .put("startBatteryPercent", startBattery ?: JSONObject.NULL)
                .put("endBatteryPercent", endBattery ?: JSONObject.NULL)
                .put("batteryDeltaPercent", if (startBattery != null && endBattery != null) startBattery - endBattery else JSONObject.NULL)
                .put("everPluggedDuringMeasurement", everPluggedDuringMeasurement)
                .put("pluggedAtEnd", pluggedAtEnd)
                .put("operations", operations)
                .put("samples", samples)
                .put("codecComponent", codecComponent ?: JSONObject.NULL)
                .put("hardwareAccelerated", hardwareAccelerated ?: JSONObject.NULL)
                .put("activityBefore", diagnosticsJson(startDiagnostics))
                .put("activityAfter", diagnosticsJson(endDiagnostics))
                .put("drainPassClaimed", false),
            outcome.exceptionOrNull(),
        )
        harness.close()
        outcome.getOrThrow()
    }
}

private data class RepresentativeObservation(
    val result: FrameResult.Published,
    val metadata: ContainerMetadata,
    val diagnostics: DecoderDiagnostics,
)

private class RepresentativeHarness(private val context: Context) {
    private var scenario: ActivityScenario<GateActivity>? = null
    private lateinit var activity: GateActivity
    private var metadata: ContainerMetadata? = null

    fun start(brightness: Float? = null) {
        val launched = ActivityScenario.launch<GateActivity>(
            Intent(context, GateActivity::class.java).putExtra(GateActivity.EXTRA_PILOT_MODE, true),
        )
        scenario = launched
        val latch = CountDownLatch(1)
        launched.onActivity {
            activity = it
            brightness?.let(it::configureValidationDisplay)
            latch.countDown()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
        assertTrue(activity.awaitSurface())
    }

    fun open(fixture: String, expectedMime: String): RepresentativeObservation {
        onMain { activity.openFixture(uri(fixture)) }
        requireNotNull(activity.awaitIndex(30)) { "INDEX_TIMEOUT" }
        val opened = requireNotNull(activity.awaitMetadata(30)) { "METADATA_TIMEOUT" }
        assertEquals(expectedMime, opened.mime)
        assertTrue(opened.hardwareAccelerated)
        metadata = opened
        return awaitPublished(0)
    }

    fun request(index: Int): RepresentativeObservation {
        activity.clearResults()
        onMain { activity.requestDirectionalFrame(index) }
        return awaitPublished(index)
    }

    private fun awaitPublished(expectedIndex: Int): RepresentativeObservation {
        val deadline = SystemClock.elapsedRealtime() + RESULT_TIMEOUT_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            val observed = activity.awaitResult(2) ?: continue
            when (val result = observed.result) {
                is FrameResult.Published -> if (result.request.requestedFrameIndex == expectedIndex) {
                    return RepresentativeObservation(result, requireNotNull(metadata), observed.diagnostics)
                }
                is FrameResult.Error -> error(result.code)
                is FrameResult.Unsupported -> error(result.reason)
                is FrameResult.DiscardedStale -> Unit
            }
        }
        error("PUBLISH_TIMEOUT")
    }

    fun awaitActorIdle(): Boolean = activity.awaitActorIdle(10_000)
    fun diagnosticsSnapshot(): DecoderDiagnostics = activity.diagnosticsSnapshot()
    fun drainActivity() {
        activity.clearResults()
    }
    fun hasPublicationEvent(): Boolean = activity.drainPublicationEvents().isNotEmpty()
    fun hasFrameResult(): Boolean = activity.drainResults().isNotEmpty()
    fun refreshRate(): Float? = if (::activity.isInitialized) activity.display?.mode?.refreshRate else null
    fun close() {
        scenario?.close()
        scenario = null
    }

    private fun uri(fixture: String): Uri = Uri.parse("content://${context.packageName}.fixture/$fixture")
    private fun onMain(action: () -> Unit) {
        val latch = CountDownLatch(1)
        activity.runOnUiThread {
            try {
                action()
            } finally {
                latch.countDown()
            }
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))
    }
}

private fun requireS24Ultra() {
    assumeTrue(
        "S24 Ultra validation requires Samsung SM-S928*",
        Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
    )
}

private fun assertHealthy(value: DecoderDiagnostics) {
    assertEquals(0L, value.fullFrameReadbackCount)
    assertEquals(0L, value.swapFailureCount)
    assertEquals(0L, value.surfaceInvalidCount)
    assertEquals(0L, value.publicationInvariantViolationCount)
    assertEquals(0L, value.textureDoubleReleaseCount)
    assertTrue(value.cacheBytes <= value.cacheBudgetBytes)
    assertTrue(value.cacheEntryCount <= value.peakCacheEntryCount)
    assertEquals(value.cacheEntryCount, value.liveTextureCount)
    assertEquals(value.liveTextureCount.toLong(), value.textureCreatedCount - value.textureReleasedCount)
    assertTrue(value.liveTextureCount <= value.peakLiveTextureCount)
    assertTrue(value.cacheThrashCount >= value.prefetchEvictedBeforeUse)
    assertTrue(value.cacheThrashCount <= value.prefetchEvictedBeforeUse + value.cacheRejectionCount)
}

private fun cacheSample(index: Int, value: DecoderDiagnostics): JSONObject = JSONObject()
    .put("frameIndex", index)
    .put("cacheBytes", value.cacheBytes)
    .put("cacheBudgetBytes", value.cacheBudgetBytes)
    .put("cacheEntryCount", value.cacheEntryCount)
    .put("peakCacheEntryCount", value.peakCacheEntryCount)
    .put("cacheEvictionCount", value.cacheEvictionCount)
    .put("cacheRejectionCount", value.cacheRejectionCount)
    .put("cacheThrashCount", value.cacheThrashCount)
    .put("effectivePrefetchLimit", value.effectivePrefetchLimit)
    .put("prefetchEvictedBeforeUse", value.prefetchEvictedBeforeUse)
    .put("textureCreatedCount", value.textureCreatedCount)
    .put("textureReleasedCount", value.textureReleasedCount)
    .put("liveTextureCount", value.liveTextureCount)
    .put("peakLiveTextureCount", value.peakLiveTextureCount)
    .put("textureDoubleReleaseCount", value.textureDoubleReleaseCount)

private fun runtimeSample(context: Context, value: DecoderDiagnostics): JSONObject {
    val memoryInfo = Debug.MemoryInfo()
    Debug.getMemoryInfo(memoryInfo)
    return JSONObject()
        .put("elapsedRealtimeMs", SystemClock.elapsedRealtime())
        .put("javaUsedBytes", Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory())
        .put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
        .put("pssKb", memoryInfo.totalPss)
        .put("graphicsPssKb", memoryInfo.getMemoryStat("summary.graphics")?.toLongOrNull())
        .put("cacheBytes", value.cacheBytes)
        .put("cacheBudgetBytes", value.cacheBudgetBytes)
        .put("cacheEntryCount", value.cacheEntryCount)
        .put("peakCacheEntryCount", value.peakCacheEntryCount)
        .put("cacheEvictionCount", value.cacheEvictionCount)
        .put("cacheRejectionCount", value.cacheRejectionCount)
        .put("cacheThrashCount", value.cacheThrashCount)
        .put("textureCreatedCount", value.textureCreatedCount)
        .put("textureReleasedCount", value.textureReleasedCount)
        .put("liveTextureCount", value.liveTextureCount)
        .put("peakLiveTextureCount", value.peakLiveTextureCount)
        .put("textureDoubleReleaseCount", value.textureDoubleReleaseCount)
        .put("thermalStatus", context.getSystemService(PowerManager::class.java).currentThermalStatus)
}

private fun batterySample(context: Context, diagnostics: DecoderDiagnostics): JSONObject = JSONObject()
    .put("elapsedRealtimeMs", SystemClock.elapsedRealtime())
    .put("batteryPercent", batteryPercent(context))
    .put("plugged", plugged(context))
    .put("thermalStatus", context.getSystemService(PowerManager::class.java).currentThermalStatus)
    .put("foregroundDecoded", diagnostics.foregroundDecodedFrameCount)
    .put("prefetchStarted", diagnostics.prefetchStarted)
    .put("prefetchCompleted", diagnostics.prefetchCompleted)
    .put("prefetchCancelled", diagnostics.prefetchCancelled)
    .put("prefetchWasted", diagnostics.prefetchWasted)
    .put("published", diagnostics.publishedSwapCount)

private fun plugged(context: Context): Boolean {
    val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
    val charging = context.getSystemService(BatteryManager::class.java).isCharging
    return plugged != 0 || charging
}

private fun batteryPercent(context: Context): Int =
    context.getSystemService(BatteryManager::class.java)
        .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

private fun diagnosticsJson(value: DecoderDiagnostics): JSONObject = JSONObject()
    .put("decoded", value.decodeOrdinal)
    .put("foregroundDecoded", value.foregroundDecodedFrameCount)
    .put("requestCoalesced", value.requestCoalescedCount)
    .put("cacheBytes", value.cacheBytes)
    .put("cacheBudgetBytes", value.cacheBudgetBytes)
    .put("cacheHits", value.cacheHitCount)
    .put("cacheMisses", value.cacheMissCount)
    .put("cacheEntryCount", value.cacheEntryCount)
    .put("peakCacheEntryCount", value.peakCacheEntryCount)
    .put("cacheEvictionCount", value.cacheEvictionCount)
    .put("cacheRejectionCount", value.cacheRejectionCount)
    .put("cacheThrashCount", value.cacheThrashCount)
    .put("textureCreatedCount", value.textureCreatedCount)
    .put("textureReleasedCount", value.textureReleasedCount)
    .put("liveTextureCount", value.liveTextureCount)
    .put("peakLiveTextureCount", value.peakLiveTextureCount)
    .put("textureDoubleReleaseCount", value.textureDoubleReleaseCount)
    .put("effectivePrefetchLimit", value.effectivePrefetchLimit)
    .put("prefetchStarted", value.prefetchStarted)
    .put("prefetchCompleted", value.prefetchCompleted)
    .put("prefetchCacheHit", value.prefetchCacheHit)
    .put("prefetchCancelled", value.prefetchCancelled)
    .put("prefetchEvictedBeforeUse", value.prefetchEvictedBeforeUse)
    .put("prefetchWasted", value.prefetchWasted)
    .put("published", value.publishedSwapCount)
    .put("swapFailure", value.swapFailureCount)
    .put("stale", value.staleDiscardCount)
    .put("decoderRecreate", value.decoderRecreateCount)

private fun resourceRecoveryAssessment(value: DecoderDiagnostics): JSONObject {
    val allocationBalance = value.textureCreatedCount - value.textureReleasedCount
    val passed = value.textureDoubleReleaseCount == 0L &&
        allocationBalance == value.liveTextureCount.toLong() &&
        value.liveTextureCount == value.cacheEntryCount
    return JSONObject()
        .put("textureScopeStatus", if (passed) "PASS" else "FAIL")
        .put("overallStatus", if (passed) "INCONCLUSIVE_CODEC_LIVE_COUNT_UNAVAILABLE" else "FAIL")
        .put("scope", "RGBA cache textures; codec switches also require every open to publish with a hardware decoder")
        .put("createdMinusReleased", allocationBalance)
        .put("liveTextureCount", value.liveTextureCount)
        .put("cacheEntryCount", value.cacheEntryCount)
        .put("textureDoubleReleaseCount", value.textureDoubleReleaseCount)
        .put("decoderRecreateCount", value.decoderRecreateCount)
}

private fun writeValidationReport(
    context: Context,
    fileName: String,
    kind: String,
    status: String,
    body: JSONObject,
    failure: Throwable?,
) {
    val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
    val report = JSONObject()
        .put("schemaVersion", 1)
        .put("kind", kind)
        .put("status", status)
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
        .put("body", body)
    failure?.let {
        report.put("failure", JSONObject()
            .put("type", it.javaClass.simpleName)
            .put("code", it.message?.takeIf { message -> message.matches(ERROR_PATTERN) } ?: "UNCLASSIFIED"))
    }
    File(context.filesDir, fileName).writeText(report.toString(2))
}

private const val H264_720 = "720p-h264-bframes.mp4"
private const val H264_1080 = "1080p-h264-bframes.mp4"
private const val SWITCH_H264 = "1080p-switch-a.mp4"
private const val SWITCH_HEVC = "1080p-switch-b.mp4"
private const val ARG_MEMORY_MINUTES = "representativeMemoryMinutes"
private const val ARG_SWITCH_ITERATIONS = "representativeSwitchIterations"
private const val ARG_IDLE_MINUTES = "representativeIdleMinutes"
private const val ARG_BATTERY_SCENARIO = "batteryScenario"
private const val ARG_BATTERY_MINUTES = "batteryMinutes"
private const val CACHE_REPORT_FILE = "representative-cache-pressure-report.json"
private const val MEMORY_REPORT_FILE = "representative-memory-report.json"
private const val CODEC_SWITCH_REPORT_FILE = "representative-codec-switch-report.json"
private const val IDLE_REPORT_FILE = "representative-idle-report.json"
private const val RESULT_TIMEOUT_MS = 30_000L
private const val PRODUCT_CACHE_BUDGET_BYTES = 64L * 1024L * 1024L
private const val SAMPLE_INTERVAL_MS = 5_000L
private const val BATTERY_SAMPLE_INTERVAL_MS = 30_000L
private const val CONNECTION_POLL_INTERVAL_MS = 250L
private const val UNPLUG_GRACE_MS = 5 * 60_000L
private const val RESOURCE_SAMPLE_EVERY_SWITCH = 10
private const val FIXED_BRIGHTNESS = 0.5f
private val BATTERY_NAVIGATION_PATTERN = intArrayOf(1, 1, 5, -1, -5)
private val ERROR_PATTERN = Regex("[A-Za-z0-9_.:-]{1,160}")
