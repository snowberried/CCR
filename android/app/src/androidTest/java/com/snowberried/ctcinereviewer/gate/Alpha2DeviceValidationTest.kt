package com.snowberried.ctcinereviewer.gate

import android.content.Context
import android.content.Intent
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
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil

@RunWith(AndroidJUnit4::class)
class Alpha2FileSwitchMatrixTest {
    @Test
    fun sixWaySyntheticFileSwitchMatrix() {
        requireS24Ultra()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val iterations = InstrumentationRegistry.getArguments()
            .getString(ARG_SWITCH_ITERATIONS)
            ?.toIntOrNull()
            ?.coerceIn(1, REQUIRED_SWITCH_ITERATIONS)
            ?: REQUIRED_SWITCH_ITERATIONS
        val counts = linkedMapOf(
            "h264ToH264" to 0,
            "h264ToHevc" to 0,
            "hevcToH264" to 0,
            "hevcToHevc" to 0,
            "sameFileReopen" to 0,
            "rapidAbc" to 0,
        )
        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val harness = PilotHarness(context)
        var latest = DecoderDiagnostics()
        val outcome = runCatching {
            harness.start()

            harness.open(H264_A, MediaFormat.MIMETYPE_VIDEO_AVC)
            repeat(iterations) { iteration ->
                latest = harness.open(
                    if (iteration % 2 == 0) H264_B else H264_A,
                    MediaFormat.MIMETYPE_VIDEO_AVC,
                ).diagnostics
                counts.increment("h264ToH264")
            }

            harness.open(H264_A, MediaFormat.MIMETYPE_VIDEO_AVC)
            repeat(iterations) {
                latest = harness.open(HEVC_A, MediaFormat.MIMETYPE_VIDEO_HEVC).diagnostics
                counts.increment("h264ToHevc")
                latest = harness.open(H264_A, MediaFormat.MIMETYPE_VIDEO_AVC).diagnostics
                counts.increment("hevcToH264")
            }

            harness.open(HEVC_A, MediaFormat.MIMETYPE_VIDEO_HEVC)
            repeat(iterations) {
                latest = harness.open(HEVC_A, MediaFormat.MIMETYPE_VIDEO_HEVC).diagnostics
                counts.increment("hevcToHevc")
            }

            harness.open(H264_BURST, MediaFormat.MIMETYPE_VIDEO_AVC)
            repeat(iterations) {
                latest = harness.open(H264_BURST, MediaFormat.MIMETYPE_VIDEO_AVC).diagnostics
                counts.increment("sameFileReopen")
            }

            repeat(iterations) {
                latest = harness.rapidOpen(
                    listOf(H264_A, HEVC_A, H264_B),
                    MediaFormat.MIMETYPE_VIDEO_AVC,
                ).diagnostics
                counts.increment("rapidAbc")
            }

            counts.values.forEach { assertEquals(iterations, it) }
            assertEquals(0, ReadOnlyFixtureProvider.writeOpenCount.get())
            assertHealthy(latest)
        }
        writeMatrixReport(context, outcome, iterations, counts, latest)
        harness.close()
        outcome.getOrThrow()
    }

    private fun MutableMap<String, Int>.increment(key: String) {
        this[key] = requireNotNull(this[key]) + 1
    }

    private fun writeMatrixReport(
        context: Context,
        outcome: Result<Unit>,
        iterations: Int,
        counts: Map<String, Int>,
        diagnostics: DecoderDiagnostics,
    ) {
        val report = baseReport(context, "file-switch-matrix")
            .put("status", if (outcome.isSuccess) "PASS" else "FAIL")
            .put("requestedIterations", iterations)
            .put("transitions", JSONObject(counts))
            .put("decoder", diagnosticsJson(diagnostics))
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
            .put("performanceGateApplied", false)
        outcome.exceptionOrNull()?.let { report.put("failure", sanitizedFailure(it)) }
        File(context.filesDir, MATRIX_REPORT_FILE).writeText(report.toString(2))
    }
}

@RunWith(AndroidJUnit4::class)
class Alpha2EnduranceTest {
    @Test
    fun productPilotEnduranceWhenExplicitlyRequested() {
        requireS24Ultra()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val durationMinutes = InstrumentationRegistry.getArguments()
            .getString(ARG_ENDURANCE_MINUTES)
            ?.toIntOrNull()
            ?: 0
        assumeTrue("pass -e $ARG_ENDURANCE_MINUTES 30 to run endurance", durationMinutes > 0)

        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val harness = PilotHarness(context)
        val samples = JSONArray()
        val latenciesMs = mutableListOf<Double>()
        val errors = linkedSetOf<String>()
        var latest = DecoderDiagnostics()
        var operations = 0
        val outcome = runCatching {
            harness.start()
            var opened = harness.open(H264_BURST, MediaFormat.MIMETYPE_VIDEO_AVC)
            latest = opened.diagnostics
            val deadline = SystemClock.elapsedRealtime() + TimeUnit.MINUTES.toMillis(durationMinutes.toLong())
            var nextSampleAt = 0L
            var usingHevc = false
            while (SystemClock.elapsedRealtime() < deadline) {
                if (operations > 0 && operations % FILE_SWITCH_EVERY_OPERATIONS == 0) {
                    usingHevc = !usingHevc
                    opened = harness.open(
                        if (usingHevc) HEVC_A else H264_BURST,
                        if (usingHevc) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC,
                    )
                    latest = opened.diagnostics
                }
                val frameCount = opened.metadata.frameCount
                val target = NAVIGATION_PATTERN[operations % NAVIGATION_PATTERN.size].coerceAtMost(frameCount - 1)
                val observed = harness.request(target)
                latenciesMs += observed.latencyMs
                latest = observed.diagnostics
                assertHealthy(latest)
                operations++

                val now = SystemClock.elapsedRealtime()
                if (now >= nextSampleAt) {
                    samples.put(runtimeSample(context, now, latest))
                    nextSampleAt = now + SAMPLE_INTERVAL_MS
                }
                SystemClock.sleep(PRODUCT_NAVIGATION_INTERVAL_MS)
            }
            samples.put(runtimeSample(context, SystemClock.elapsedRealtime(), latest))
            assertEquals(0, ReadOnlyFixtureProvider.writeOpenCount.get())
            Unit
        }
        outcome.exceptionOrNull()?.let { errors += sanitizedErrorCode(it) }
        writeEnduranceReport(
            context = context,
            outcome = outcome,
            durationMinutes = durationMinutes,
            operations = operations,
            samples = samples,
            latenciesMs = latenciesMs,
            diagnostics = latest,
            errors = errors,
        )
        harness.close()
        outcome.getOrThrow()
    }

    private fun writeEnduranceReport(
        context: Context,
        outcome: Result<Unit>,
        durationMinutes: Int,
        operations: Int,
        samples: JSONArray,
        latenciesMs: List<Double>,
        diagnostics: DecoderDiagnostics,
        errors: Set<String>,
    ) {
        val cacheSamples = List(samples.length()) { samples.getJSONObject(it).getLong("cacheBytes") }
        val pssSamples = List(samples.length()) { samples.getJSONObject(it).getLong("pssKb") }
        val report = baseReport(context, "product-pilot-endurance")
            .put("status", if (outcome.isSuccess) "PASS" else "FAIL")
            .put("requestedDurationMinutes", durationMinutes)
            .put("operations", operations)
            .put("samples", samples)
            .put("latencyMs", latencyJson(latenciesMs))
            .put("decoder", diagnosticsJson(diagnostics))
            .put("errors", JSONArray(errors.toList()))
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
            .put("cachePlateauObserved", plateauObserved(cacheSamples))
            .put("pssMonotonicGrowthAfterWarmup", monotonicGrowthAfterWarmup(pssSamples))
            .put("visualFrameReadbackPerformed", false)
            .put("blankOrGreenFrameAssessment", "not-measured-in-product-no-readback-mode")
            .put("performanceGateApplied", false)
        outcome.exceptionOrNull()?.let { report.put("failure", sanitizedFailure(it)) }
        File(context.filesDir, ENDURANCE_REPORT_FILE).writeText(report.toString(2))
    }
}

private data class PublishedObservation(
    val metadata: ContainerMetadata,
    val diagnostics: DecoderDiagnostics,
    val latencyMs: Double,
)

private class PilotHarness(private val context: Context) {
    private var scenario: ActivityScenario<GateActivity>? = null
    private lateinit var activity: GateActivity

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
        assertTrue("EGL Surface unavailable", activity.awaitSurface())
    }

    fun open(fixture: String, expectedMime: String): PublishedObservation {
        val startedAt = SystemClock.elapsedRealtimeNanos()
        onMain { activity.openFixture(uri(fixture)) }
        return awaitOpen(expectedMime, startedAt)
    }

    fun rapidOpen(fixtures: List<String>, expectedMime: String): PublishedObservation {
        val startedAt = SystemClock.elapsedRealtimeNanos()
        onMain { fixtures.forEach { activity.openFixture(uri(it)) } }
        return awaitOpen(expectedMime, startedAt)
    }

    fun request(index: Int): PublishedObservation {
        activity.clearResults()
        val startedAt = SystemClock.elapsedRealtimeNanos()
        val acceptance = AtomicReference<com.snowberried.ctcinereviewer.media.RequestAcceptance?>()
        onMain { acceptance.set(activity.requestFrame(index)) }
        val expected = requireNotNull(acceptance.get()).request
        val deadline = SystemClock.elapsedRealtime() + RESULT_TIMEOUT_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            val observed = activity.awaitResult(2) ?: continue
            when (val result = observed.result) {
                is FrameResult.Published -> if (result.request.token == expected.token) {
                    assertEquals(index, result.request.requestedFrameIndex)
                    assertEquals(null, result.imageProbe)
                    return PublishedObservation(
                        metadata = requireNotNull(lastMetadata),
                        diagnostics = observed.diagnostics,
                        latencyMs = elapsedMs(startedAt),
                    )
                }
                is FrameResult.Error -> if (result.request.token == expected.token) error(result.code)
                is FrameResult.Unsupported -> if (result.request.token == expected.token) error("UNSUPPORTED")
                is FrameResult.DiscardedStale -> Unit
            }
        }
        error("PUBLISH_TIMEOUT")
    }

    private var lastMetadata: ContainerMetadata? = null

    private fun awaitOpen(expectedMime: String, startedAt: Long): PublishedObservation {
        val index = requireNotNull(activity.awaitIndex(20)) { "INDEX_TIMEOUT" }
        val metadata = requireNotNull(activity.awaitMetadata(20)) { "METADATA_TIMEOUT" }
        assertEquals(index.fileGeneration, metadata.fileGeneration)
        assertEquals(expectedMime, metadata.mime)
        assertTrue("software decoder is forbidden", metadata.hardwareAccelerated)
        lastMetadata = metadata
        val deadline = SystemClock.elapsedRealtime() + RESULT_TIMEOUT_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            val observed = activity.awaitResult(2) ?: continue
            when (val result = observed.result) {
                is FrameResult.Published -> if (result.request.token.fileGeneration == metadata.fileGeneration) {
                    assertEquals(0, result.request.requestedFrameIndex)
                    assertEquals(null, result.imageProbe)
                    assertHealthy(observed.diagnostics)
                    return PublishedObservation(metadata, observed.diagnostics, elapsedMs(startedAt))
                }
                is FrameResult.Error -> if (result.request.token.fileGeneration == metadata.fileGeneration) error(result.code)
                is FrameResult.Unsupported -> if (result.request.token.fileGeneration == metadata.fileGeneration) error("UNSUPPORTED")
                is FrameResult.DiscardedStale -> Unit
            }
        }
        error("FIRST_PUBLISH_TIMEOUT")
    }

    fun close() {
        scenario?.close()
        scenario = null
    }

    private fun uri(fixture: String): Uri = Uri.parse("content://${context.packageName}.fixture/$fixture")

    private fun onMain(action: () -> Unit) {
        val complete = CountDownLatch(1)
        activity.runOnUiThread {
            try {
                action()
            } finally {
                complete.countDown()
            }
        }
        assertTrue("main action timeout", complete.await(5, TimeUnit.SECONDS))
    }
}

private fun requireS24Ultra() {
    assumeTrue(
        "S24 Ultra validation requires Samsung SM-S928*",
        Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
    )
}

private fun assertHealthy(diagnostics: DecoderDiagnostics) {
    assertEquals(0L, diagnostics.fullFrameReadbackCount)
    assertEquals(0L, diagnostics.swapFailureCount)
    assertEquals(0L, diagnostics.surfaceInvalidCount)
    assertEquals(0L, diagnostics.publicationInvariantViolationCount)
}

private fun baseReport(context: Context, kind: String): JSONObject {
    val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
    val runNonce = InstrumentationRegistry.getArguments()
        .getString(ARG_RUN_NONCE)
        ?.takeIf { it.matches(RUN_NONCE_PATTERN) }
        ?: error("RUN_NONCE_REQUIRED")
    return JSONObject()
        .put("schemaVersion", 1)
        .put("kind", kind)
        .put("runNonce", runNonce)
        .put("appVersionName", packageInfo.versionName)
        .put("appVersionCode", packageInfo.longVersionCode)
        .put("appCommitSha", BuildConfig.COMMIT_SHA)
        .put("appApkSha256", sha256(File(context.applicationInfo.sourceDir)))
        .put("device", JSONObject()
            .put("manufacturer", Build.MANUFACTURER)
            .put("model", Build.MODEL)
            .put("sdk", Build.VERSION.SDK_INT))
        .put("renderMode", "PILOT_PRODUCT_NO_READBACK")
        .put("privacyMarker", PRIVACY_MARKER)
        .put("containsRealMediaMetadata", false)
}

private fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}

private fun diagnosticsJson(value: DecoderDiagnostics): JSONObject = JSONObject()
    .put("decodedOutputs", value.decodeOrdinal)
    .put("cacheHits", value.cacheHitCount)
    .put("cacheMisses", value.cacheMissCount)
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
    .put("prefetchRequested", value.prefetchRequested)
    .put("prefetchStarted", value.prefetchStarted)
    .put("prefetchCompleted", value.prefetchCompleted)
    .put("prefetchCacheHit", value.prefetchCacheHit)
    .put("prefetchCancelled", value.prefetchCancelled)
    .put("prefetchEvictedBeforeUse", value.prefetchEvictedBeforeUse)
    .put("prefetchWasted", value.prefetchWasted)
    .put("effectivePrefetchLimit", value.effectivePrefetchLimit)
    .put("publishedSwaps", value.publishedSwapCount)
    .put("staleDiscard", value.staleDiscardCount)
    .put("staleBeforeSwap", value.staleBeforeSwapCount)
    .put("swapFailures", value.swapFailureCount)
    .put("surfaceInvalid", value.surfaceInvalidCount)
    .put("publicationInvariantViolations", value.publicationInvariantViolationCount)
    .put("decoderRecreate", value.decoderRecreateCount)
    .put("surfaceRecreate", JSONObject.NULL)
    .put("surfaceRecreateMeasurement", "covered-by-separate-lifecycle-regression")
    .put("fullFrameReadbacks", value.fullFrameReadbackCount)

private fun runtimeSample(context: Context, elapsedRealtimeMs: Long, diagnostics: DecoderDiagnostics): JSONObject {
    val power = context.getSystemService(PowerManager::class.java)
    val battery = context.getSystemService(BatteryManager::class.java)
    return JSONObject()
        .put("elapsedRealtimeMs", elapsedRealtimeMs)
        .put("javaUsedBytes", Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory())
        .put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
        .put("pssKb", Debug.getPss())
        .put("cacheBytes", diagnostics.cacheBytes)
        .put("cacheBudgetBytes", diagnostics.cacheBudgetBytes)
        .put("cacheEntryCount", diagnostics.cacheEntryCount)
        .put("liveTextureCount", diagnostics.liveTextureCount)
        .put("prefetchCompleted", diagnostics.prefetchCompleted)
        .put("prefetchCacheHit", diagnostics.prefetchCacheHit)
        .put("prefetchWasted", diagnostics.prefetchWasted)
        .put("publishedSwaps", diagnostics.publishedSwapCount)
        .put("swapFailures", diagnostics.swapFailureCount)
        .put("staleDiscard", diagnostics.staleDiscardCount)
        .put("staleBeforeSwap", diagnostics.staleBeforeSwapCount)
        .put("surfaceInvalid", diagnostics.surfaceInvalidCount)
        .put("thermalStatus", power.currentThermalStatus)
        .put("batteryPercent", battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
}

private fun latencyJson(values: List<Double>): JSONObject {
    val sorted = values.sorted()
    fun percentile(fraction: Double): Double? = sorted.takeIf { it.isNotEmpty() }
        ?.get((ceil(sorted.size * fraction).toInt() - 1).coerceIn(0, sorted.lastIndex))
    return JSONObject()
        .put("count", sorted.size)
        .put("p50", percentile(0.50))
        .put("p95", percentile(0.95))
        .put("max", sorted.maxOrNull())
}

private fun plateauObserved(values: List<Long>): Boolean {
    val tail = values.takeLast(5)
    return tail.size == 5 && tail.distinct().size <= 2
}

private fun monotonicGrowthAfterWarmup(values: List<Long>): Boolean {
    val warm = values.drop((values.size / 5).coerceAtLeast(1))
    return warm.size >= 3 && warm.zipWithNext().all { (left, right) -> right > left }
}

private fun sanitizedFailure(error: Throwable): JSONObject = JSONObject()
    .put("type", error.javaClass.simpleName)
    .put("code", sanitizedErrorCode(error))

private fun sanitizedErrorCode(error: Throwable): String =
    error.message
        ?.takeIf { it.matches(Regex("[A-Z0-9_:-]{1,80}")) }
        ?: error.javaClass.simpleName.uppercase()

private fun elapsedMs(startedAtNs: Long): Double =
    (SystemClock.elapsedRealtimeNanos() - startedAtNs) / 1_000_000.0

private const val ARG_SWITCH_ITERATIONS = "switchIterations"
private const val ARG_ENDURANCE_MINUTES = "enduranceMinutes"
private const val ARG_RUN_NONCE = "runNonce"
private const val REQUIRED_SWITCH_ITERATIONS = 20
private const val RESULT_TIMEOUT_MS = 30_000L
private const val SAMPLE_INTERVAL_MS = 10_000L
private const val PRODUCT_NAVIGATION_INTERVAL_MS = 50L
private const val FILE_SWITCH_EVERY_OPERATIONS = 200
private const val MATRIX_REPORT_FILE = "alpha2-file-switch-report.json"
private const val ENDURANCE_REPORT_FILE = "alpha2-endurance-report.json"
private const val H264_A = "switch-a.mp4"
private const val H264_B = "switch-b.mp4"
private const val H264_BURST = "burst.mp4"
private const val HEVC_A = "hevc-main8.mp4"
private const val PRIVACY_MARKER = "SYNTHETIC_FIXTURES_ONLY_NO_SOURCE_IDENTIFIERS"
private val RUN_NONCE_PATTERN = Regex("[a-f0-9]{32}")
private val NAVIGATION_PATTERN = intArrayOf(1, 2, 3, 4, 5, 10, 11, 6, 1, 0)
