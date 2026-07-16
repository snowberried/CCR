package com.snowberried.ctcinereviewer.gate

import android.content.Context
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.BuildConfig
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecodedOutputMetadata
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.Random
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.ceil

@RunWith(AndroidJUnit4::class)
class S24RepresentativeResolutionAccuracyTest {
    private data class GoldenFrame(
        val displayFrameIndex: Int,
        val ptsUs: Long,
        val duplicateOrdinal: Int,
        val sampleOrdinal: Int,
        val embeddedFrameId: Int,
        val sync: Boolean,
        val imageSignature: List<Int>,
    )

    private data class Golden(
        val fixture: String,
        val sourceSha256: String,
        val codec: String,
        val codedWidth: Int,
        val codedHeight: Int,
        val cropLeft: Int,
        val cropTop: Int,
        val cropRight: Int,
        val cropBottom: Int,
        val rotationDegrees: Int,
        val pixelAspectRatioNumerator: Int,
        val pixelAspectRatioDenominator: Int,
        val frames: List<GoldenFrame>,
    )

    private data class SelectionPlan(
        val selected: Set<Int>,
        val consecutive: List<Int>,
        val plusFive: List<Int>,
        val reasonCounts: Map<String, Int>,
    )

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private var mismatchCount = 0
    private var writeOpenCount = 0

    @Test
    fun representativeResolutionExactSubsetRemainsExact() {
        assumeTrue(
            "representative-resolution Gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val fixtureReports = JSONArray()
        val outcome = runCatching {
            ActivityScenario.launch(GateActivity::class.java).use { scenario ->
                val activity = AtomicReference<GateActivity>()
                val ready = CountDownLatch(1)
                scenario.onActivity {
                    activity.set(it)
                    ready.countDown()
                }
                assertTrue("GateActivity unavailable", ready.await(5, TimeUnit.SECONDS))
                val gate = activity.get()
                assertTrue("EGL Surface unavailable", gate.awaitSurface())
                for (name in REQUIRED_FIXTURES) {
                    val golden = loadGolden(name)
                    assertEquals(golden.sourceSha256, assetSha256(golden.fixture))
                    val plan = selectionPlan(golden)
                    fixtureReports.put(exerciseFixture(gate, golden, plan))
                }
            }
            writeOpenCount = ReadOnlyFixtureProvider.writeOpenCount.get()
            assertEquals("source opened for write", 0, writeOpenCount)
            assertEquals("exactness mismatch", 0, mismatchCount)
        }
        writeReport(outcome, fixtureReports)
        outcome.getOrThrow()
    }

    private fun exerciseFixture(
        activity: GateActivity,
        golden: Golden,
        plan: SelectionPlan,
    ): JSONObject {
        activity.clearResults()
        onMain(activity) { activity.openFixture(uri(golden.fixture)) }
        val indexed = requireNotNull(activity.awaitIndex(30)) { "${golden.fixture}: INDEX_TIMEOUT" }
        val metadata = requireNotNull(activity.awaitMetadata(30)) { "${golden.fixture}: METADATA_TIMEOUT" }
        validateIndex(golden, indexed)
        validateContainerMetadata(golden, metadata)
        var last = awaitPublished(activity, golden, 0)

        plan.selected.sorted().forEach { index -> last = requestAndAwait(activity, golden, index) }
        plan.consecutive.forEach { index -> last = requestAndAwait(activity, golden, index, directional = true) }
        plan.consecutive.asReversed().forEach { index -> last = requestAndAwait(activity, golden, index, directional = true) }
        plan.plusFive.forEach { index -> last = requestAndAwait(activity, golden, index, directional = true) }
        plan.plusFive.asReversed().forEach { index -> last = requestAndAwait(activity, golden, index, directional = true) }

        val diagnostics = last.diagnostics
        assertEquals(0L, diagnostics.staleDiscardCount)
        assertEquals(0L, diagnostics.staleBeforeSwapCount)
        assertEquals(0L, diagnostics.swapFailureCount)
        assertEquals(0L, diagnostics.surfaceInvalidCount)
        assertEquals(0L, diagnostics.publicationInvariantViolationCount)
        val visibleWidth = golden.cropRight - golden.cropLeft + 1
        val visibleHeight = golden.cropBottom - golden.cropTop + 1
        val outputHistory = diagnostics.decodedOutputFormatHistory
        assertTrue("${golden.fixture}: decoded output format missing", outputHistory.isNotEmpty())
        outputHistory.forEach { output ->
            assertEquals(visibleWidth, output.cropRight - output.cropLeft + 1)
            assertEquals(visibleHeight, output.cropBottom - output.cropTop + 1)
            assertEquals(MediaFormat.COLOR_STANDARD_BT709, output.colorStandard)
            assertEquals(MediaFormat.COLOR_RANGE_LIMITED, output.colorRange)
            assertEquals(MediaFormat.COLOR_TRANSFER_SDR_VIDEO, output.colorTransfer)
        }

        return JSONObject()
            .put("fixture", golden.fixture)
            .put("sourceSha256", golden.sourceSha256)
            .put("frameCount", golden.frames.size)
            .put("selectedFrameCount", plan.selected.size)
            .put("reasonCounts", JSONObject(plan.reasonCounts))
            .put("consecutiveSequenceLength", plan.consecutive.size)
            .put("plusFiveSequenceLength", plan.plusFive.size)
            .put("codecComponent", metadata.codecComponent)
            .put("hardwareAccelerated", metadata.hardwareAccelerated)
            .put("goldenCodedSize", "${golden.codedWidth}x${golden.codedHeight}")
            .put("containerReportedSize", "${metadata.codedWidth}x${metadata.codedHeight}")
            .put("canonicalVisibleSize", "${visibleWidth}x${visibleHeight}")
            .put("rotationDegrees", golden.rotationDegrees)
            .put("pixelAspectRatio", JSONObject()
                .put("numerator", golden.pixelAspectRatioNumerator)
                .put("denominator", golden.pixelAspectRatioDenominator))
            .put("configuredOutput", outputJson(diagnostics.configuredOutputMetadata))
            .put("decodedOutputHistory", JSONArray(outputHistory.map(::outputJson)))
            .put("fullFrameReadbacks", diagnostics.fullFrameReadbackCount)
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
    }

    private fun selectionPlan(golden: Golden): SelectionPlan {
        val frames = golden.frames
        require(frames.size >= MINIMUM_FRAME_COUNT) { "${golden.fixture}: FRAME_COUNT_LT_300" }
        val reasons = linkedMapOf<String, MutableSet<Int>>()
        fun add(reason: String, index: Int) {
            if (index in frames.indices) reasons.getOrPut(reason, ::linkedSetOf).add(index)
        }
        fun addBoundary(reason: String, index: Int) {
            add(reason, index - 1)
            add(reason, index)
            add(reason, index + 1)
        }

        add("firstLast", 0)
        add("firstLast", frames.lastIndex)
        frames.forEachIndexed { index, frame -> if (frame.sync) add("gopSync", index) }
        for (index in 1..frames.lastIndex) {
            if (frames[index].sampleOrdinal < frames[index - 1].sampleOrdinal) {
                addBoundary("reorderBoundary", index)
            }
        }
        val ptsDeltas = frames.zipWithNext { left, right -> right.ptsUs - left.ptsUs }
        for (index in 1..ptsDeltas.lastIndex) {
            if (abs(ptsDeltas[index] - ptsDeltas[index - 1]) > PTS_ROUNDING_TOLERANCE_US) {
                addBoundary("vfrChange", index + 1)
            }
        }
        frames.groupBy(GoldenFrame::ptsUs).values
            .filter { it.size > 1 }
            .flatten()
            .forEach { add("duplicatePts", it.displayFrameIndex) }

        val random = Random(java.lang.Long.parseUnsignedLong(golden.sourceSha256.take(16), 16))
        while ((reasons["deterministicRandom"]?.size ?: 0) < DETERMINISTIC_RANDOM_COUNT) {
            add("deterministicRandom", random.nextInt(frames.size))
        }
        val continuousStart = random.nextInt(frames.size - CONSECUTIVE_COUNT + 1)
        val consecutive = (continuousStart until continuousStart + CONSECUTIVE_COUNT).toList()
        consecutive.forEach { add("consecutivePlusMinusOne", it) }
        val plusFiveSpan = 5 * (PLUS_FIVE_COUNT - 1)
        val plusFiveStart = random.nextInt(frames.size - plusFiveSpan)
        val plusFive = generateSequence(plusFiveStart) { previous ->
            (previous + 5).takeIf { it < frames.size }
        }.take(PLUS_FIVE_COUNT).toList()
        plusFive.forEach { add("plusMinusFive", it) }

        return SelectionPlan(
            selected = reasons.values.flatten().toSet(),
            consecutive = consecutive,
            plusFive = plusFive,
            reasonCounts = reasons.mapValues { it.value.size },
        )
    }

    private fun requestAndAwait(
        activity: GateActivity,
        golden: Golden,
        index: Int,
        directional: Boolean = false,
    ): GateActivity.ObservedResult {
        activity.clearResults()
        onMain(activity) {
            if (directional) activity.requestDirectionalFrame(index) else activity.requestFrame(index)
        }
        return awaitPublished(activity, golden, index)
    }

    private fun awaitPublished(
        activity: GateActivity,
        golden: Golden,
        expectedIndex: Int,
    ): GateActivity.ObservedResult {
        val deadline = SystemClock.elapsedRealtime() + RESULT_TIMEOUT_MS
        while (SystemClock.elapsedRealtime() < deadline) {
            val observed = activity.awaitResult(2) ?: continue
            when (val result = observed.result) {
                is FrameResult.Published -> {
                    validatePublished(golden, result)
                    if (result.request.requestedFrameIndex == expectedIndex) return observed
                }
                is FrameResult.DiscardedStale -> Unit
                is FrameResult.Error -> error("${golden.fixture}[$expectedIndex]:${result.code}")
                is FrameResult.Unsupported -> error("${golden.fixture}[$expectedIndex]:${result.reason}")
            }
        }
        error("${golden.fixture}[$expectedIndex]:PUBLISH_TIMEOUT")
    }

    private fun validatePublished(golden: Golden, actual: FrameResult.Published) {
        val expected = golden.frames[actual.request.requestedFrameIndex]
        mismatchCount += if (actual.request.expectedKey.displayFrameIndex != expected.displayFrameIndex) 1 else 0
        mismatchCount += if (actual.request.expectedKey.ptsUs != expected.ptsUs) 1 else 0
        mismatchCount += if (actual.request.expectedKey.duplicateOrdinal != expected.duplicateOrdinal) 1 else 0
        mismatchCount += if (actual.textureTimestampNs != expected.ptsUs * 1_000L) 1 else 0
        val probe = requireNotNull(actual.imageProbe) { "${golden.fixture}:EXACT_PROBE_MISSING" }
        mismatchCount += if (probe.embeddedFrameId != expected.embeddedFrameId) 1 else 0
        assertEquals("signature length", expected.imageSignature.size, probe.imageSignature.size)
        val errors = probe.imageSignature.zip(expected.imageSignature) { left, right -> abs(left - right) }.sorted()
        val mean = errors.average()
        val p99 = errors[(ceil(errors.size * 0.99).toInt() - 1).coerceAtLeast(0)]
        val maximum = errors.last()
        if (mean > 6.0 || p99 > 16 || maximum > 40) mismatchCount += 1
        assertEquals(expected.displayFrameIndex, actual.request.expectedKey.displayFrameIndex)
        assertEquals(expected.ptsUs, actual.request.expectedKey.ptsUs)
        assertEquals(expected.duplicateOrdinal, actual.request.expectedKey.duplicateOrdinal)
        assertEquals(expected.ptsUs * 1_000L, actual.textureTimestampNs)
        assertEquals(expected.embeddedFrameId, probe.embeddedFrameId)
        val signatureContext = "${golden.fixture}[${expected.displayFrameIndex}]"
        assertTrue("$signatureContext signature MAE=$mean p99=$p99 max=$maximum", mean <= 6.0)
        assertTrue("$signatureContext signature p99=$p99 MAE=$mean max=$maximum", p99 <= 16)
        assertTrue("$signatureContext signature max=$maximum MAE=$mean p99=$p99", maximum <= 40)
    }

    private fun validateIndex(golden: Golden, actual: IndexedVideo) {
        assertEquals(golden.frames.size, actual.frameCount)
        golden.frames.forEachIndexed { index, expected ->
            val observed = actual.frames[index]
            assertEquals(expected.displayFrameIndex, observed.key.displayFrameIndex)
            assertEquals(expected.ptsUs, observed.key.ptsUs)
            assertEquals(expected.duplicateOrdinal, observed.key.duplicateOrdinal)
            assertEquals(expected.sampleOrdinal, observed.sampleOrdinal)
            assertEquals(expected.sync, observed.sync)
        }
    }

    private fun validateContainerMetadata(golden: Golden, actual: ContainerMetadata) {
        assertEquals(if (golden.codec == "h264") "video/avc" else "video/hevc", actual.mime)
        assertEquals(golden.frames.size, actual.frameCount)
        assertTrue("software decoder forbidden", actual.hardwareAccelerated)
        assertTrue(actual.codecComponent.isNotBlank())
        assertEquals(golden.rotationDegrees, actual.rotationDegrees)
        assertEquals(golden.pixelAspectRatioNumerator, actual.pixelAspectRatioWidth)
        assertEquals(golden.pixelAspectRatioDenominator, actual.pixelAspectRatioHeight)
        // AVC may expose 1920x1080 at the extractor while ffprobe records the
        // 1920x1088 coded raster. Visible inclusive crop is the stable contract.
        assertEquals(golden.cropRight - golden.cropLeft + 1, actual.cropRight - actual.cropLeft + 1)
        assertEquals(golden.cropBottom - golden.cropTop + 1, actual.cropBottom - actual.cropTop + 1)
    }

    private fun loadGolden(name: String): Golden {
        val json = context.assets.open("$ASSET_DIRECTORY/$name.json").bufferedReader().use {
            JSONObject(it.readText())
        }
        val crop = json.getJSONObject("crop")
        val pixelAspectRatio = json.getJSONObject("pixelAspectRatio")
        val frameJson = json.getJSONArray("frames")
        return Golden(
            fixture = json.getString("fixture"),
            sourceSha256 = json.getString("sourceSha256"),
            codec = json.getString("codec"),
            codedWidth = json.getInt("codedWidth"),
            codedHeight = json.getInt("codedHeight"),
            cropLeft = crop.getInt("left"),
            cropTop = crop.getInt("top"),
            cropRight = crop.getInt("right"),
            cropBottom = crop.getInt("bottom"),
            rotationDegrees = json.getInt("rotationDegrees"),
            pixelAspectRatioNumerator = pixelAspectRatio.getInt("numerator"),
            pixelAspectRatioDenominator = pixelAspectRatio.getInt("denominator"),
            frames = List(frameJson.length()) { index ->
                val frame = frameJson.getJSONObject(index)
                GoldenFrame(
                    displayFrameIndex = frame.getInt("displayFrameIndex"),
                    ptsUs = frame.getLong("ptsUs"),
                    duplicateOrdinal = frame.getInt("duplicateOrdinal"),
                    sampleOrdinal = frame.getInt("sampleOrdinal"),
                    embeddedFrameId = frame.getInt("embeddedFrameId"),
                    sync = frame.getBoolean("sync"),
                    imageSignature = frame.getJSONArray("imageSignature").toIntList(),
                )
            },
        )
    }

    private fun outputJson(value: DecodedOutputMetadata?): Any = value?.let {
        JSONObject()
            .put("codedWidth", it.width)
            .put("codedHeight", it.height)
            .put("cropLeft", it.cropLeft)
            .put("cropTop", it.cropTop)
            .put("cropRight", it.cropRight)
            .put("cropBottom", it.cropBottom)
            .put("visibleWidth", it.cropRight - it.cropLeft + 1)
            .put("visibleHeight", it.cropBottom - it.cropTop + 1)
            .put("colorStandard", it.colorStandard)
            .put("colorRange", it.colorRange)
            .put("colorTransfer", it.colorTransfer)
    } ?: JSONObject.NULL

    private fun writeReport(outcome: Result<Unit>, fixtures: JSONArray) {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val report = JSONObject()
            .put("schemaVersion", 1)
            .put("kind", "representative-resolution-exact-subset")
            .put("status", if (outcome.isSuccess) "PASS" else "FAIL")
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
            .put("selectionContract", JSONArray(listOf(
                "first-last", "all-gop-sync", "reorder-transition", "vfr-delta-change",
                "deterministic-random-50", "plus-minus-one-30", "plus-minus-five", "all-duplicate-pts",
            )))
            .put("fixtures", fixtures)
            .put("mismatchCount", mismatchCount)
            .put("writeOpenCount", writeOpenCount)
            .put("performanceGateApplied", false)
        outcome.exceptionOrNull()?.let {
            report.put("failure", JSONObject()
                .put("type", it.javaClass.simpleName)
                .put("code", it.message?.takeIf { message -> message.matches(ERROR_PATTERN) } ?: "UNCLASSIFIED"))
        }
        File(context.filesDir, REPORT_FILE).writeText(report.toString(2))
    }

    private fun assetSha256(name: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        context.assets.open("$ASSET_DIRECTORY/$name").use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun uri(fixture: String): Uri = Uri.parse("content://${context.packageName}.fixture/$fixture")

    private fun onMain(activity: GateActivity, action: () -> Unit) {
        val latch = CountDownLatch(1)
        activity.runOnUiThread {
            try {
                action()
            } finally {
                latch.countDown()
            }
        }
        assertTrue("main action timeout", latch.await(5, TimeUnit.SECONDS))
    }

    private fun JSONArray.toIntList(): List<Int> = List(length()) { getInt(it) }

    companion object {
        const val REPORT_FILE = "representative-resolution-exact-report.json"
        private const val ASSET_DIRECTORY = "representative-resolution"
        private const val MINIMUM_FRAME_COUNT = 300
        private const val DETERMINISTIC_RANDOM_COUNT = 50
        private const val CONSECUTIVE_COUNT = 30
        private const val PLUS_FIVE_COUNT = 30
        private const val PTS_ROUNDING_TOLERANCE_US = 1L
        private const val RESULT_TIMEOUT_MS = 30_000L
        private val ERROR_PATTERN = Regex("[A-Za-z0-9_.:\\[\\]=,/ -]{1,160}")
        val REQUIRED_FIXTURES = listOf(
            "720p-h264-bframes",
            "1080p-h264-bframes",
            "1080p-h264-long-gop",
            "1080p-hevc-main8",
            "1080p-vfr",
            "1080p-switch-a",
            "1080p-switch-b",
        )
    }
}
