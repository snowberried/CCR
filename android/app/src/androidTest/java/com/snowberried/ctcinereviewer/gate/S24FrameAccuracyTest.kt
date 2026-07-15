package com.snowberried.ctcinereviewer.gate

import android.content.Context
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import com.snowberried.ctcinereviewer.media.VideoMetadata
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
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
class S24FrameAccuracyTest {
    data class GoldenFrame(
        val displayFrameIndex: Int,
        val ptsUs: Long,
        val duplicateOrdinal: Int,
        val sampleOrdinal: Int,
        val embeddedFrameId: Int,
        val sync: Boolean,
        val imageSignature: List<Int>,
    )

    data class Golden(
        val fixture: String,
        val sourceSha256: String,
        val codec: String,
        val profile: String,
        val codedWidth: Int,
        val codedHeight: Int,
        val cropLeft: Int,
        val cropTop: Int,
        val cropRight: Int,
        val cropBottom: Int,
        val rotationDegrees: Int,
        val parWidth: Int,
        val parHeight: Int,
        val frames: List<GoldenFrame>,
    )

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val targetContext = instrumentation.targetContext
    private val report = Report(targetContext)
    private val latencyMs = mutableListOf<Double>()
    private var lastDiagnostics = DecoderDiagnostics()
    private var mismatchCount = 0

    @Test
    fun allGoldenVectorsRemainExactOnS24Ultra() {
        assumeTrue("S24 Ultra Gate requires Samsung SM-S928*", Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"))
        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val scenario = ActivityScenario.launch(GateActivity::class.java)
        val activity = AtomicReference<GateActivity>()
        val ready = CountDownLatch(1)
        scenario.onActivity {
            activity.set(it)
            ready.countDown()
        }
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        val gate = activity.get()
        assertTrue("EGL Surface was not created", gate.awaitSurface())
        gate.display.mode.let { report.captureDisplay(it.physicalWidth, it.physicalHeight, it.refreshRate) }

        val outcome = runCatching {
            val names = REQUIRED_FIXTURES
            for (name in names) {
                val golden = loadGolden(name)
                assertEquals(golden.sourceSha256, assetSha256(golden.fixture))
                exerciseEveryFrame(gate, golden)
                report.fixtures += JSONObject()
                    .put("fixture", golden.fixture)
                    .put("sourceSha256", golden.sourceSha256)
                    .put("codec", golden.codec)
                    .put("profile", golden.profile)
                    .put("frameCount", golden.frames.size)
            }
            exerciseNavigation(gate, loadGolden("burst"))
            exerciseBurst(gate, loadGolden("burst"))
            exerciseFileSwitch(gate, loadGolden("switch-a"), loadGolden("switch-b"))
            assertEquals("source was opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
            assertEquals("exactness mismatch", 0, mismatchCount)
        }

        val reportOutcome = runCatching {
            report.finish(
                status = if (outcome.isSuccess) "PASS" else "FAIL",
                failure = outcome.exceptionOrNull(),
                latencyMs = latencyMs,
                diagnostics = lastDiagnostics,
                writeOpenCount = ReadOnlyFixtureProvider.writeOpenCount.get(),
            )
        }
        scenario.close()
        outcome.exceptionOrNull()?.let { failure ->
            reportOutcome.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
        reportOutcome.getOrThrow()
    }

    private fun exerciseEveryFrame(activity: GateActivity, golden: Golden) {
        report.currentFixture = golden.fixture
        report.currentFrameIndex = 0
        val openedAt = SystemClock.elapsedRealtimeNanos()
        open(activity, golden.fixture)
        val indexed = requireNotNull(activity.awaitIndex()) {
            "${golden.fixture}: index timeout ${activity.drainStatuses()}"
        }
        val metadata = requireNotNull(activity.awaitMetadata()) { "${golden.fixture}: metadata timeout ${activity.drainStatuses()}" }
        validateIndex(golden, indexed)
        validateMetadata(golden, metadata)
        report.codecComponents += metadata.codecComponent
        val first = awaitPublished(activity, golden, 0)
        latencyMs += elapsedMs(openedAt)
        lastDiagnostics = first.diagnostics
        for (index in 1 until golden.frames.size) requestAndValidate(activity, golden, index)
    }

    private fun exerciseNavigation(activity: GateActivity, golden: Golden) {
        report.currentFixture = golden.fixture
        openAndAwait(activity, golden)
        val middle = golden.frames.size / 2
        val sequence = listOf(golden.frames.lastIndex, 0, middle, middle - 1, middle + 4, 1, golden.frames.lastIndex - 1)
        sequence.forEach { requestAndValidate(activity, golden, it) }
    }

    private fun exerciseBurst(activity: GateActivity, golden: Golden) {
        report.currentFixture = golden.fixture
        openAndAwait(activity, golden)
        activity.clearResults()
        val sequence = listOf(1, 6, 12, 24, golden.frames.lastIndex)
        onMain(activity) { sequence.forEach(activity::requestFrame) }
        var finalPublished = false
        val deadline = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < deadline && !finalPublished) {
            val observed = activity.awaitResult(2) ?: continue
            lastDiagnostics = observed.diagnostics
            when (val result = observed.result) {
                is FrameResult.Published -> {
                    validatePublished(golden, result)
                    finalPublished = result.request.requestedFrameIndex == golden.frames.lastIndex
                }
                is FrameResult.DiscardedStale -> Unit
                is FrameResult.Error -> error("burst error: ${result.code}")
                is FrameResult.Unsupported -> error("burst unsupported: ${result.reason}")
            }
        }
        assertTrue("burst final frame was not published", finalPublished)
        assertEquals("stale frame was published", 0, lastDiagnostics.stalePublishCount)
    }

    private fun exerciseFileSwitch(activity: GateActivity, first: Golden, second: Golden) {
        report.currentFixture = first.fixture
        openAndAwait(activity, first)
        activity.clearResults()
        onMain(activity) {
            activity.requestFrame(first.frames.lastIndex)
            report.currentFixture = second.fixture
            report.currentFrameIndex = 0
            activity.openFixture(uri(second.fixture))
        }
        val secondIndex = requireNotNull(activity.awaitIndex()) { "switch B index timeout" }
        val secondMetadata = requireNotNull(activity.awaitMetadata()) { "switch B metadata timeout" }
        validateIndex(second, secondIndex)
        validateMetadata(second, secondMetadata)
        val published = awaitPublished(activity, second, 0)
        assertEquals(secondMetadata.fileGeneration, (published.result as FrameResult.Published).request.token.fileGeneration)
        Thread.sleep(500)
        val lateA = activity.drainResults().map(GateActivity.ObservedResult::result).filterIsInstance<FrameResult.Published>()
            .count { it.request.token.fileGeneration != secondMetadata.fileGeneration }
        assertEquals("A frame published after B file generation", 0, lateA)
    }

    private fun openAndAwait(activity: GateActivity, golden: Golden) {
        open(activity, golden.fixture)
        validateIndex(golden, requireNotNull(activity.awaitIndex()) { "${golden.fixture}: index timeout" })
        validateMetadata(golden, requireNotNull(activity.awaitMetadata()) { "${golden.fixture}: metadata timeout" })
        awaitPublished(activity, golden, 0)
    }

    private fun open(activity: GateActivity, fixture: String) = onMain(activity) { activity.openFixture(uri(fixture)) }

    private fun requestAndValidate(activity: GateActivity, golden: Golden, index: Int) {
        report.currentFixture = golden.fixture
        report.currentFrameIndex = index
        val startedAt = SystemClock.elapsedRealtimeNanos()
        onMain(activity) { activity.requestFrame(index) }
        val observed = awaitPublished(activity, golden, index)
        latencyMs += elapsedMs(startedAt)
        lastDiagnostics = observed.diagnostics
    }

    private fun awaitPublished(activity: GateActivity, golden: Golden, expectedIndex: Int): GateActivity.ObservedResult {
        val deadline = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val observed = activity.awaitResult(2) ?: continue
            lastDiagnostics = observed.diagnostics
            when (val result = observed.result) {
                is FrameResult.Published -> {
                    validatePublished(golden, result)
                    if (result.request.requestedFrameIndex == expectedIndex) return observed
                }
                is FrameResult.DiscardedStale -> Unit
                is FrameResult.Error -> error("${golden.fixture}[$expectedIndex]: ${result.code}")
                is FrameResult.Unsupported -> error("${golden.fixture}[$expectedIndex]: ${result.reason}")
            }
        }
        error("${golden.fixture}[$expectedIndex]: publish timeout")
    }

    private fun validatePublished(golden: Golden, actual: FrameResult.Published) {
        val expected = golden.frames[actual.request.requestedFrameIndex]
        report.currentFixture = golden.fixture
        report.currentFrameIndex = expected.displayFrameIndex
        mismatchCount += if (actual.request.expectedKey.displayFrameIndex != expected.displayFrameIndex) 1 else 0
        mismatchCount += if (actual.request.expectedKey.ptsUs != expected.ptsUs) 1 else 0
        mismatchCount += if (actual.request.expectedKey.duplicateOrdinal != expected.duplicateOrdinal) 1 else 0
        mismatchCount += if (actual.textureTimestampNs != expected.ptsUs * 1_000L) 1 else 0
        mismatchCount += if (actual.imageProbe.embeddedFrameId != expected.embeddedFrameId) 1 else 0
        val errors = actual.imageProbe.imageSignature.zip(expected.imageSignature) { left, right -> kotlin.math.abs(left - right) }.sorted()
        val mean = errors.average()
        val p99 = errors[(ceil(errors.size * 0.99).toInt() - 1).coerceAtLeast(0)]
        val maximum = errors.last()
        if (mean > 6.0 || p99 > 16 || maximum > 40) mismatchCount += 1
        assertEquals("${golden.fixture}: FrameKey index", expected.displayFrameIndex, actual.request.expectedKey.displayFrameIndex)
        assertEquals("${golden.fixture}: FrameKey PTS", expected.ptsUs, actual.request.expectedKey.ptsUs)
        assertEquals("${golden.fixture}: duplicate ordinal", expected.duplicateOrdinal, actual.request.expectedKey.duplicateOrdinal)
        assertEquals("${golden.fixture}: texture timestamp", expected.ptsUs * 1_000L, actual.textureTimestampNs)
        assertEquals("${golden.fixture}: embedded ID", expected.embeddedFrameId, actual.imageProbe.embeddedFrameId)
        assertTrue("${golden.fixture}: signature MAE $mean", mean <= 6.0)
        assertTrue("${golden.fixture}: signature p99 $p99", p99 <= 16)
        assertTrue("${golden.fixture}: signature max $maximum", maximum <= 40)
    }

    private fun validateIndex(golden: Golden, actual: IndexedVideo) {
        assertEquals(golden.frames.size, actual.frameCount)
        golden.frames.forEachIndexed { index, expected ->
            val frame = actual.frames[index]
            assertEquals(expected.displayFrameIndex, frame.key.displayFrameIndex)
            assertEquals(expected.ptsUs, frame.key.ptsUs)
            assertEquals(expected.duplicateOrdinal, frame.key.duplicateOrdinal)
            assertEquals(expected.sampleOrdinal, frame.sampleOrdinal)
            assertEquals(expected.sync, frame.sync)
        }
    }

    private fun validateMetadata(golden: Golden, actual: VideoMetadata) {
        assertEquals(if (golden.codec == "h264") "video/avc" else "video/hevc", actual.mime)
        assertEquals(golden.codedWidth, actual.codedWidth)
        assertEquals(golden.codedHeight, actual.codedHeight)
        assertEquals(golden.cropLeft, actual.cropLeft)
        assertEquals(golden.cropTop, actual.cropTop)
        assertEquals(golden.cropRight, actual.cropRight)
        assertEquals(golden.cropBottom, actual.cropBottom)
        assertEquals(golden.rotationDegrees, actual.rotationDegrees)
        assertEquals(golden.parWidth, actual.pixelAspectRatioWidth)
        assertEquals(golden.parHeight, actual.pixelAspectRatioHeight)
        assertTrue("software decoder is forbidden", actual.hardwareAccelerated)
        assertTrue(actual.codecComponent.isNotBlank())
    }

    private fun loadGolden(name: String): Golden {
        val json = targetContext.assets.open("frame-accuracy/$name.json").bufferedReader().use { JSONObject(it.readText()) }
        val crop = json.getJSONObject("crop")
        val par = json.getJSONObject("pixelAspectRatio")
        val framesJson = json.getJSONArray("frames")
        val frames = List(framesJson.length()) { index ->
            val frame = framesJson.getJSONObject(index)
            GoldenFrame(
                displayFrameIndex = frame.getInt("displayFrameIndex"),
                ptsUs = frame.getLong("ptsUs"),
                duplicateOrdinal = frame.getInt("duplicateOrdinal"),
                sampleOrdinal = frame.getInt("sampleOrdinal"),
                embeddedFrameId = frame.getInt("embeddedFrameId"),
                sync = frame.getBoolean("sync"),
                imageSignature = frame.getJSONArray("imageSignature").toIntList(),
            )
        }
        return Golden(
            fixture = json.getString("fixture"),
            sourceSha256 = json.getString("sourceSha256"),
            codec = json.getString("codec"),
            profile = json.getString("profile"),
            codedWidth = json.getInt("codedWidth"),
            codedHeight = json.getInt("codedHeight"),
            cropLeft = crop.getInt("left"),
            cropTop = crop.getInt("top"),
            cropRight = crop.getInt("right"),
            cropBottom = crop.getInt("bottom"),
            rotationDegrees = json.getInt("rotationDegrees"),
            parWidth = par.getInt("numerator"),
            parHeight = par.getInt("denominator"),
            frames = frames,
        )
    }

    private fun assetSha256(name: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        targetContext.assets.open("frame-accuracy/$name").use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun uri(fixture: String): Uri = Uri.parse("content://${targetContext.packageName}.fixture/$fixture")

    private fun onMain(activity: GateActivity, action: () -> Unit) {
        val complete = CountDownLatch(1)
        activity.runOnUiThread {
            action()
            complete.countDown()
        }
        assertTrue(complete.await(5, TimeUnit.SECONDS))
    }

    private fun elapsedMs(startedAtNs: Long): Double = (SystemClock.elapsedRealtimeNanos() - startedAtNs) / 1_000_000.0

    private fun JSONArray.toIntList(): List<Int> = List(length()) { getInt(it) }

    private class Report(private val context: Context) {
        val fixtures = mutableListOf<JSONObject>()
        val codecComponents = linkedSetOf<String>()
        var currentFixture: String? = null
        var currentFrameIndex: Int? = null
        private var displayWidth: Int? = null
        private var displayHeight: Int? = null
        private var refreshRate: Float? = null

        fun captureDisplay(width: Int, height: Int, refreshRate: Float) {
            displayWidth = width
            displayHeight = height
            this.refreshRate = refreshRate
        }

        fun finish(
            status: String,
            failure: Throwable?,
            latencyMs: List<Double>,
            diagnostics: DecoderDiagnostics,
            writeOpenCount: Int,
        ) {
            val sorted = latencyMs.sorted()
            fun percentile(value: Double): Double? = sorted.takeIf { it.isNotEmpty() }
                ?.get((ceil(sorted.size * value).toInt() - 1).coerceIn(0, sorted.lastIndex))
            val power = context.getSystemService(PowerManager::class.java)
            val battery = context.getSystemService(BatteryManager::class.java)
            val json = JSONObject()
                .put("schemaVersion", 1)
                .put("status", status)
                .put("gate", "Samsung SM-S928* S24 Ultra")
                .put("device", JSONObject()
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("fingerprint", Build.FINGERPRINT)
                    .put("build", Build.DISPLAY)
                    .put("securityPatch", Build.VERSION.SECURITY_PATCH)
                    .put("sdk", Build.VERSION.SDK_INT)
                    .put("displayWidth", displayWidth)
                    .put("displayHeight", displayHeight)
                    .put("refreshRate", refreshRate))
                .put("appSha256", sha256(File(context.applicationInfo.sourceDir)))
                .put("codecComponents", JSONArray(codecComponents.toList()))
                .put("fixtures", JSONArray(fixtures))
                .put("latencyMs", JSONObject()
                    .put("count", sorted.size)
                    .put("p50", percentile(0.50))
                    .put("p95", percentile(0.95))
                    .put("max", sorted.maxOrNull()))
                .put("decoder", JSONObject()
                    .put("cacheHits", diagnostics.cacheHitCount)
                    .put("cacheMisses", diagnostics.cacheMissCount)
                    .put("cacheBytes", diagnostics.cacheBytes)
                    .put("decodedOutputs", diagnostics.decodeOrdinal)
                    .put("staleDiscard", diagnostics.staleDiscardCount)
                    .put("stalePublish", diagnostics.stalePublishCount)
                    .put("recreate", diagnostics.decoderRecreateCount))
                .put("memory", JSONObject()
                    .put("javaUsedBytes", Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory())
                    .put("javaMaxBytes", Runtime.getRuntime().maxMemory())
                    .put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
                    .put("pssKb", Debug.getPss()))
                .put("thermalStatus", power.currentThermalStatus)
                .put("batteryPercent", battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                .put("writeOpenCount", writeOpenCount)
                .put("performanceGateApplied", false)
            if (failure != null) {
                json.put("failure", JSONObject()
                    .put("type", failure.javaClass.simpleName)
                    .put("message", failure.message ?: "unknown")
                    .put("fixture", currentFixture)
                    .put("frameIndex", currentFrameIndex)
                    .put("minimalReproduction", "run-s24-gate.ps1 with only the reported synthetic fixture")
                    .put("suspectedCause", "undetermined; inspect FrameKey, texture timestamp, embedded ID and signature in that order")
                    .put("nextMinimalChange", "isolate the failing fixture and change only the first disproved decode/render hypothesis"))
            }
            File(context.filesDir, REPORT_FILE).writeText(json.toString(2))
        }

        private fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }

    companion object {
        const val REPORT_FILE = "s24-frame-accuracy-report.json"
        val REQUIRED_FIXTURES = listOf(
            "h264-ip", "h264-bframes", "vfr", "long-gop", "nonzero-pts", "one-frame", "two-frame",
            "short-last-gop", "rotation-90", "rotation-180", "rotation-270", "hevc-main8", "burst",
            "switch-a", "switch-b", "par-8-9",
        )
    }
}
