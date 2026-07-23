package com.snowberried.ctcinereviewer.gate

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Debug
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.BuildConfig
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.PublicationEvent
import com.snowberried.ctcinereviewer.media.PublicationResult
import com.snowberried.ctcinereviewer.media.RequestAcceptance
import com.snowberried.ctcinereviewer.validation.ValidationHarnessIdentity
import com.snowberried.ctcinereviewer.validation.ValidationHarnessV2
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class Alpha6RandomSeekPerformanceTest {
    private data class FixtureSpec(val privateAssetId: String, val publicId: String, val seed: Long)

    private data class GoldenFrame(
        val index: Int,
        val ptsUs: Long,
        val duplicateOrdinal: Int,
        val sampleOrdinal: Int,
        val sync: Boolean,
    )

    private data class Golden(
        val privateFixtureName: String,
        val sourceSha256: String,
        val frames: List<GoldenFrame>,
    )

    private data class ObservedPublication(
        val published: FrameResult.Published,
        val diagnostics: DecoderDiagnostics,
        val event: PublicationEvent,
        val nonTargetPublishedCount: Int,
        val staleDiscardCount: Int,
    )

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private lateinit var identity: ValidationHarnessIdentity
    private var startedAtNs = 0L
    private var mismatchCount = 0

    @Test
    fun deterministicCostAwareRandomSeekAlpha6() {
        assumeTrue(
            "Alpha 6 random performance gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        identity = ValidationHarnessV2.requireIdentity(context, instrumentation.context)
        startedAtNs = SystemClock.elapsedRealtimeNanos()
        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val fixtures = JSONArray()
        val outcome = runCatching {
            val intent = Intent(context, GateActivity::class.java)
                .putExtra(GateActivity.EXTRA_PILOT_MODE, true)
            ActivityScenario.launch<GateActivity>(intent).use { scenario ->
                val activity = AtomicReference<GateActivity>()
                val ready = CountDownLatch(1)
                scenario.onActivity {
                    activity.set(it)
                    ready.countDown()
                }
                assertTrue("GateActivity unavailable", ready.await(5, TimeUnit.SECONDS))
                assertTrue("EGL Surface unavailable", activity.get().awaitSurface())
                FIXTURES.forEach { fixtures.put(exerciseFixture(activity.get(), it)) }
            }
            assertEquals("source opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
            assertEquals("exactness mismatch", 0, mismatchCount)
        }
        writeReport(outcome, fixtures)
        outcome.getOrThrow()
    }

    private fun exerciseFixture(activity: GateActivity, spec: FixtureSpec): JSONObject {
        val fixtureMismatchStart = mismatchCount
        val golden = loadGolden(spec.privateAssetId)
        assertEquals(golden.sourceSha256, assetSha256(golden.privateFixtureName))
        activity.clearResults()
        onMain(activity) { activity.openFixture(uri(golden.privateFixtureName)) }
        val index = requireNotNull(activity.awaitIndex(30)) { "INDEX_TIMEOUT" }
        val metadata = requireNotNull(activity.awaitMetadata(30)) { "METADATA_TIMEOUT" }
        assertEquals(golden.frames.size, index.frameCount)
        assertTrue("software decoder forbidden", metadata.hardwareAccelerated)
        awaitPublished(activity, golden, 0)

        val syncIndices = golden.frames.filter(GoldenFrame::sync).map(GoldenFrame::index)
        val plan = Alpha4RandomSeekBaselinePlan.create(golden.frames.size, syncIndices, spec.seed)
        val observations = JSONArray()
        plan.forEach { target ->
            val setupPublication = requestAndAwait(activity, golden, target.setupFrameIndex)
            val acceptedDisplayedFrameIndex =
                setupPublication.published.request.expectedKey.displayFrameIndex
            assertEquals("setup publication drift", target.setupFrameIndex, acceptedDisplayedFrameIndex)
            val before = activity.diagnosticsSnapshot()
            activity.clearResults()
            val acceptance = submit(activity, target.targetFrameIndex)
            val observed = awaitPublished(
                activity,
                golden,
                target.targetFrameIndex,
                assessmentStartNs = acceptance.elapsedRealtimeNanos,
                assessmentRequestGeneration = acceptance.request.token.requestGeneration,
            )
            assertEquals("random target discarded its accepted generation", 0, observed.staleDiscardCount)
            assertEquals("random target published a different frame", 0, observed.nonTargetPublishedCount)
            val publishedDisplayedFrameIndex = observed.published.request.expectedKey.displayFrameIndex
            val actualDirection = direction(acceptedDisplayedFrameIndex, target.targetFrameIndex)
            assertEquals("planned direction drift", target.direction, actualDirection)
            val acceptedToPublicationUs =
                (observed.event.elapsedRealtimeNanos - acceptance.elapsedRealtimeNanos) / 1_000L
            assertTrue("negative accepted-to-publication latency", acceptedToPublicationUs >= 0L)
            if (target.category == Alpha4SeekCategory.CACHE_OR_HISTORY_HIT) {
                assertTrue("cache baseline target was not retained", observed.published.cacheHit)
            } else {
                assertEquals("non-cache category was contaminated", false, observed.published.cacheHit)
                assertTrue(
                    "non-cache target omitted its seek plan",
                    !observed.diagnostics.lastRandomSeekPlanKind.isNullOrBlank(),
                )
                assertTrue(
                    "non-cache target omitted its attempted seek plan",
                    !observed.diagnostics.lastRandomSeekAttemptedPlanKind.isNullOrBlank(),
                )
                assertTrue(
                    "non-cache target omitted its estimated decode count",
                    requireNotNull(observed.diagnostics.lastRandomSeekEstimatedOutputCount) >= 0,
                )
                assertTrue(
                    "non-cache target omitted its actual decode count",
                    requireNotNull(observed.diagnostics.lastRandomSeekActualOutputCount) >= 0,
                )
            }
            val setupSync = previousSync(golden, target.setupFrameIndex)
            val targetSync = previousSync(golden, target.targetFrameIndex)
            observations.put(
                JSONObject()
                    .put("ordinal", target.ordinal)
                    .put("category", target.category.wireName)
                    .put("requestedCategory", target.category.wireName)
                    .put("direction", target.direction.wireName)
                    .put("setupFrameIndex", target.setupFrameIndex)
                    .put("targetFrameIndex", target.targetFrameIndex)
                    .put("setupSampleOrdinal", golden.frames[target.setupFrameIndex].sampleOrdinal)
                    .put("targetSampleOrdinal", golden.frames[target.targetFrameIndex].sampleOrdinal)
                    .put("targetPtsUs", golden.frames[target.targetFrameIndex].ptsUs)
                    .put("fileGeneration", acceptance.request.token.fileGeneration)
                    .put("requestGeneration", acceptance.request.token.requestGeneration)
                    .put("acceptedElapsedRealtimeNs", acceptance.elapsedRealtimeNanos)
                    .put("publishedElapsedRealtimeNs", observed.event.elapsedRealtimeNanos)
                    .put("setupPreviousSyncFrameIndex", setupSync.first)
                    .put("targetPreviousSyncFrameIndex", targetSync.first)
                    .put("setupSyncOrdinal", setupSync.second)
                    .put("targetSyncOrdinal", targetSync.second)
                    .put("acceptedToFirstDecoderOutputUs", JSONObject.NULL)
                    .put("acceptedToTargetOutputUs", JSONObject.NULL)
                    .put("acceptedToPublicationUs", acceptedToPublicationUs)
                    .put("acceptedDisplayedFrameIndex", acceptedDisplayedFrameIndex)
                    .put("publishedDisplayedFrameIndex", publishedDisplayedFrameIndex)
                    .put("acceptedDisplayedMeasurement", "SETUP_PUBLICATION")
                    .put("acceptedRawFrameLag", abs(target.targetFrameIndex - acceptedDisplayedFrameIndex))
                    .put("publishedRawFrameLag", abs(target.targetFrameIndex - publishedDisplayedFrameIndex))
                    .put("decodedOutputCount", delta(before.decodeOrdinal, observed.diagnostics.decodeOrdinal))
                    .put("seekCount", delta(before.seekCount, observed.diagnostics.seekCount))
                    .put("flushCount", delta(before.flushCount, observed.diagnostics.flushCount))
                    .put("seekPlanKind", observed.diagnostics.lastRandomSeekPlanKind ?: JSONObject.NULL)
                    .put(
                        "attemptedPlan",
                        observed.diagnostics.lastRandomSeekAttemptedPlanKind ?: JSONObject.NULL,
                    )
                    .put("selectedPlan", selectedPlanWire(observed.diagnostics.lastRandomSeekPlanKind))
                    .put("planFallbackReason", observed.diagnostics.lastRandomSeekFallbackReason ?: JSONObject.NULL)
                    .put("fallbackReason", observed.diagnostics.lastRandomSeekFallbackReason ?: JSONObject.NULL)
                    .put(
                        "decoderCursorFrame",
                        observed.diagnostics.lastRandomSeekDecoderCursorFrameIndex ?: JSONObject.NULL,
                    )
                    .put(
                        "actualPreviousSyncFrame",
                        observed.diagnostics.lastRandomSeekPreviousSyncFrameIndex ?: JSONObject.NULL,
                    )
                    .put(
                        "previousSyncFrame",
                        observed.diagnostics.lastRandomSeekPreviousSyncFrameIndex ?: JSONObject.NULL,
                    )
                    .put("auxiliaryUsed", observed.diagnostics.lastRandomSeekAuxiliaryUsed)
                    .put("cacheSource", observed.diagnostics.lastRandomSeekCacheSource ?: JSONObject.NULL)
                    .put(
                        "estimatedDecodeOutputCount",
                        observed.diagnostics.lastRandomSeekEstimatedOutputCount ?: JSONObject.NULL,
                    )
                    .put(
                        "estimatedOutputCount",
                        observed.diagnostics.lastRandomSeekEstimatedOutputCount ?: JSONObject.NULL,
                    )
                    .put(
                        "actualDecodeOutputCount",
                        observed.diagnostics.lastRandomSeekActualOutputCount ?: JSONObject.NULL,
                    )
                    .put(
                        "actualOutputCount",
                        observed.diagnostics.lastRandomSeekActualOutputCount ?: JSONObject.NULL,
                    )
                    .put(
                        "historyHitCount",
                        delta(before.backwardHistoryHitCount, observed.diagnostics.backwardHistoryHitCount),
                    )
                    .put(
                        "reverseWindowHitCount",
                        delta(before.reverseWindowHitCount, observed.diagnostics.reverseWindowHitCount),
                    )
                    .put("cacheOrHistoryHit", observed.published.cacheHit)
                    .put("staleDiscardCount", observed.staleDiscardCount)
                    .put("nonTargetPublishedCount", observed.nonTargetPublishedCount),
            )
        }

        val burstTargets = Alpha4RandomSeekBaselinePlan.burstTargets(golden.frames.size, spec.seed)
        requestAndAwait(activity, golden, burstTargets.first())
        activity.clearResults()
        val burstAcceptances = submitBurst(activity, burstTargets)
        val lastAcceptance = burstAcceptances.last()
        val burst = awaitPublished(
            activity,
            golden,
            burstTargets.last(),
            assessmentStartNs = lastAcceptance.elapsedRealtimeNanos,
            assessmentRequestGeneration = lastAcceptance.request.token.requestGeneration,
        )
        assertEquals("random burst published a superseded target", 0, burst.nonTargetPublishedCount)
        val diagnostics = burst.diagnostics
        assertEquals(0L, diagnostics.staleBeforeSwapCount)
        assertEquals(0L, diagnostics.swapFailureCount)
        assertEquals(0L, diagnostics.surfaceInvalidCount)
        assertEquals(0L, diagnostics.publicationInvariantViolationCount)
        assertEquals("pilot baseline performed full-frame readback", 0L, diagnostics.fullFrameReadbackCount)
        assertEquals("cache budget changed", REQUIRED_CACHE_BUDGET_BYTES, diagnostics.cacheBudgetBytes)
        assertTrue("cache byte cap exceeded", diagnostics.cacheBytes in 0..diagnostics.cacheBudgetBytes)
        assertTrue(
            "peak cache byte cap exceeded",
            diagnostics.peakCacheBytes in diagnostics.cacheBytes..diagnostics.cacheBudgetBytes,
        )
        assertTrue("cache entry peak underflow", diagnostics.cacheEntryCount <= diagnostics.peakCacheEntryCount)
        assertTrue("live texture peak underflow", diagnostics.liveTextureCount <= diagnostics.peakLiveTextureCount)
        assertEquals(0L, diagnostics.textureDoubleReleaseCount)
        val inSessionMemory = memorySnapshot()

        return JSONObject()
            .put("fixtureId", spec.publicId)
            .put("frameCount", golden.frames.size)
            .put("codecComponent", metadata.codecComponent)
            .put("hardwareAccelerated", metadata.hardwareAccelerated)
            .put("targetCount", plan.size)
            .put("mismatchCount", mismatchCount - fixtureMismatchStart)
            .put("deterministicSeed", spec.seed)
            .put("syncFrameIndices", JSONArray(syncIndices))
            .put("syncSamples", JSONArray(golden.frames.filter(GoldenFrame::sync)
                .sortedBy(GoldenFrame::sampleOrdinal)
                .map { JSONObject()
                    .put("displayFrameIndex", it.index)
                    .put("sampleOrdinal", it.sampleOrdinal) }))
            .put(
                "targetSetIdentity",
                Alpha4RandomSeekBaselinePlan.identity(golden.frames.size, syncIndices, spec.seed, plan),
            )
            .put("categoryCounts", categoryCounts(plan))
            .put("containsFirstMiddleLast", containsFirstMiddleLast(plan, golden.frames.size))
            .put("containsGopBoundary", plan.any { it.targetFrameIndex in syncIndices })
            .put("targets", observations)
            .put("burst", JSONObject()
                .put("requestCount", burstTargets.size)
                .put("acceptedRequestCount", burstAcceptances.size)
                .put("acceptedRequestGenerations", JSONArray(
                    burstAcceptances.map { it.request.token.requestGeneration },
                ))
                .put("finalTargetFrameIndex", burstTargets.last())
                .put("fileGeneration", lastAcceptance.request.token.fileGeneration)
                .put("requestGeneration", lastAcceptance.request.token.requestGeneration)
                .put("acceptedElapsedRealtimeNs", lastAcceptance.elapsedRealtimeNanos)
                .put("assessmentWindowStartElapsedRealtimeNs", lastAcceptance.elapsedRealtimeNanos)
                .put("publishedElapsedRealtimeNs", burst.event.elapsedRealtimeNanos)
                .put("acceptedToPublicationUs", (burst.event.elapsedRealtimeNanos - lastAcceptance.elapsedRealtimeNanos) / 1_000L)
                .put("nonTargetPublishedCount", burst.nonTargetPublishedCount)
                .put("nonFinalPublishedAfterFinalAcceptanceCount", burst.nonTargetPublishedCount)
                .put("publicationAssessment", "EVENT_TIMESTAMP_AT_OR_AFTER_FINAL_ACCEPTANCE")
                .put("discardedStaleAssessment", "FINAL_GENERATION_ONLY_NO_CALLBACK_TIMESTAMP")
                .put("staleDiscardCount", burst.staleDiscardCount))
            .put("cacheBudgetBytes", diagnostics.cacheBudgetBytes)
            .put("cacheBytes", diagnostics.cacheBytes)
            .put("peakCacheBytes", diagnostics.peakCacheBytes)
            .put("cacheEntryCount", diagnostics.cacheEntryCount)
            .put("peakCacheEntryCount", diagnostics.peakCacheEntryCount)
            .put("cacheEvictionCount", diagnostics.cacheEvictionCount)
            .put("cacheRejectionCount", diagnostics.cacheRejectionCount)
            .put("cacheThrashCount", diagnostics.cacheThrashCount)
            .put("liveTextureCount", diagnostics.liveTextureCount)
            .put("peakLiveTextureCount", diagnostics.peakLiveTextureCount)
            .put("textureDoubleReleaseCount", diagnostics.textureDoubleReleaseCount)
            .put("staleBeforeSwapCount", diagnostics.staleBeforeSwapCount)
            .put("swapFailureCount", diagnostics.swapFailureCount)
            .put("surfaceInvalidCount", diagnostics.surfaceInvalidCount)
            .put("publicationInvariantViolationCount", diagnostics.publicationInvariantViolationCount)
            .put("fullFrameReadbackCount", diagnostics.fullFrameReadbackCount)
            .put("inSessionMemory", inSessionMemory)
    }

    private fun requestAndAwait(
        activity: GateActivity,
        golden: Golden,
        target: Int,
    ): ObservedPublication {
        activity.clearResults()
        submit(activity, target)
        return awaitPublished(activity, golden, target)
    }

    private fun submit(activity: GateActivity, target: Int): RequestAcceptance {
        val accepted = AtomicReference<RequestAcceptance?>()
        onMain(activity) { accepted.set(activity.requestFrame(target)) }
        return requireNotNull(accepted.get()) { "REQUEST_NOT_ACCEPTED" }
    }

    private fun submitBurst(activity: GateActivity, targets: List<Int>): List<RequestAcceptance> {
        val accepted = AtomicReference<List<RequestAcceptance>>()
        onMain(activity) {
            accepted.set(targets.map { target ->
                requireNotNull(activity.requestFrame(target)) { "BURST_REQUEST_NOT_ACCEPTED" }
            })
        }
        return requireNotNull(accepted.get()).also { acceptances ->
            assertEquals(targets.size, acceptances.size)
            assertEquals(targets, acceptances.map { it.request.requestedFrameIndex })
            assertTrue(
                "burst request generations are not strictly increasing",
                acceptances.zipWithNext().all { (left, right) ->
                    right.request.token.requestGeneration > left.request.token.requestGeneration
                },
            )
        }
    }

    private fun awaitPublished(
        activity: GateActivity,
        golden: Golden,
        expectedIndex: Int,
        assessmentStartNs: Long = Long.MIN_VALUE,
        assessmentRequestGeneration: Long = Long.MIN_VALUE,
    ): ObservedPublication {
        val deadline = SystemClock.elapsedRealtime() + RESULT_TIMEOUT_MS
        var stale = 0
        var nonTarget = 0
        while (SystemClock.elapsedRealtime() < deadline) {
            val observed = activity.awaitResult(2) ?: continue
            when (val result = observed.result) {
                is FrameResult.Published -> {
                    validatePublished(golden, result)
                    val event = observed.diagnostics.publicationEventHistory.lastOrNull {
                        it.requestGeneration == result.request.token.requestGeneration &&
                            it.fileGeneration == result.request.token.fileGeneration &&
                            it.result == PublicationResult.PUBLISHED
                    } ?: error("PUBLICATION_EVENT_MISSING")
                    validatePublicationEvent(result, event)
                    if (result.request.requestedFrameIndex != expectedIndex) {
                        if (event.elapsedRealtimeNanos >= assessmentStartNs) nonTarget += 1
                        continue
                    }
                    assertTrue("publication predates assessment window", event.elapsedRealtimeNanos >= assessmentStartNs)
                    return ObservedPublication(result, observed.diagnostics, event, nonTarget, stale)
                }
                is FrameResult.DiscardedStale -> {
                    if (result.request.token.requestGeneration >= assessmentRequestGeneration) stale += 1
                }
                is FrameResult.Error -> error("FRAME_RESULT_ERROR")
                is FrameResult.Unsupported -> error("FRAME_RESULT_UNSUPPORTED")
            }
        }
        error("PUBLISH_TIMEOUT")
    }

    private fun validatePublished(golden: Golden, actual: FrameResult.Published) {
        val expected = golden.frames[actual.request.requestedFrameIndex]
        mismatchCount += if (actual.request.expectedKey.displayFrameIndex != expected.index) 1 else 0
        mismatchCount += if (actual.request.expectedKey.ptsUs != expected.ptsUs) 1 else 0
        mismatchCount += if (actual.request.expectedKey.duplicateOrdinal != expected.duplicateOrdinal) 1 else 0
        mismatchCount += if (actual.textureTimestampNs != expected.ptsUs * 1_000L) 1 else 0
        assertNull("pilot baseline unexpectedly returned an image probe", actual.imageProbe)
        assertEquals(expected.index, actual.request.expectedKey.displayFrameIndex)
        assertEquals(expected.ptsUs, actual.request.expectedKey.ptsUs)
        assertEquals(expected.duplicateOrdinal, actual.request.expectedKey.duplicateOrdinal)
        assertEquals(expected.ptsUs * 1_000L, actual.textureTimestampNs)
    }

    private fun validatePublicationEvent(
        published: FrameResult.Published,
        event: PublicationEvent,
    ) {
        assertEquals(published.request.token.fileGeneration, event.fileGeneration)
        assertEquals(published.request.token.requestGeneration, event.requestGeneration)
        assertEquals(published.request.requestedFrameIndex, event.requestedFrameIndex)
        assertEquals(published.request.expectedKey, event.expectedKey)
        assertEquals(event.fileGeneration, event.currentFileGeneration)
        assertEquals(event.requestGeneration, event.currentRequestGeneration)
        assertEquals(published.textureTimestampNs, event.textureTimestampNs)
        assertTrue("publication did not attempt swap", event.swapAttempted)
        assertEquals(true, event.eglSwapBuffersResult)
        assertEquals(PublicationResult.PUBLISHED, event.result)
    }

    private fun previousSync(golden: Golden, targetIndex: Int): Pair<Int, Int> {
        val targetSampleOrdinal = golden.frames[targetIndex].sampleOrdinal
        val syncFrames = golden.frames
            .filter { it.sync && it.sampleOrdinal <= targetSampleOrdinal }
            .sortedBy(GoldenFrame::sampleOrdinal)
        val frame = syncFrames.lastOrNull() ?: golden.frames.first()
        return frame.index to (syncFrames.size - 1).coerceAtLeast(0)
    }

    private fun direction(setupFrameIndex: Int, targetFrameIndex: Int): Alpha4SeekDirection = when {
        targetFrameIndex > setupFrameIndex -> Alpha4SeekDirection.FORWARD
        targetFrameIndex < setupFrameIndex -> Alpha4SeekDirection.REVERSE
        else -> Alpha4SeekDirection.STATIONARY
    }

    private fun loadGolden(assetId: String): Golden {
        val json = context.assets.open("$ASSET_DIRECTORY/$assetId.json").bufferedReader().use {
            JSONObject(it.readText())
        }
        val frames = json.getJSONArray("frames")
        return Golden(
            privateFixtureName = json.getString("fixture"),
            sourceSha256 = json.getString("sourceSha256"),
            frames = List(frames.length()) { index ->
                frames.getJSONObject(index).let { frame ->
                    GoldenFrame(
                        index = frame.getInt("displayFrameIndex"),
                        ptsUs = frame.getLong("ptsUs"),
                        duplicateOrdinal = frame.getInt("duplicateOrdinal"),
                        sampleOrdinal = frame.getInt("sampleOrdinal"),
                        sync = frame.getBoolean("sync"),
                    )
                }
            },
        )
    }

    private fun writeReport(outcome: Result<Unit>, fixtures: JSONArray) {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val report = JSONObject()
            .put("schemaVersion", Alpha4RandomSeekBaselinePlan.SCHEMA_VERSION)
            .put("kind", "alpha6-cost-aware-random-performance")
            .put("status", if (outcome.isSuccess) "PASS" else "FAIL")
            .put("baselineCompleteness", "PENDING_TRACE_MERGE")
            .put("renderMode", "PILOT_SOURCE_EQUIVALENT")
            .put("pixelExactnessEvidence", "SEPARATE_FROZEN_GATES")
            .put("applicationId", context.packageName)
            .put("appVersionName", packageInfo.versionName)
            .put("appVersionCode", packageInfo.longVersionCode)
            .put("appCommitSha", BuildConfig.COMMIT_SHA)
            .put("syntheticOnly", true)
            .put("containsRealMediaMetadata", false)
            .put("mediaFileNameIncluded", false)
            .put("mediaUriIncluded", false)
            .put("mediaPathIncluded", false)
            .put("mediaSourceHashIncluded", false)
            .put("metricAvailability", JSONObject()
                .put("acceptedToFirstDecoderOutput", "PENDING_TRACE_MERGE")
                .put("acceptedToTargetOutput", "PENDING_TRACE_MERGE")
                .put("gpu", "UNKNOWN")
                .put("releaseOvershoot", "UNKNOWN"))
            .put("gpuMetrics", JSONObject.NULL)
            .put("memoryMeasurement", "POST_ACTIVITY_CLEANUP_SNAPSHOT")
            .put("memory", memorySnapshot())
            .put("fixtures", fixtures)
            .put("fixtureCount", fixtures.length())
            .put("targetCount", fixtures.length() * Alpha4RandomSeekBaselinePlan.TARGET_COUNT)
            .put("mismatchCount", mismatchCount)
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
        ValidationHarnessV2.putReportIdentity(
            report,
            identity,
            startedAtNs,
            SystemClock.elapsedRealtimeNanos(),
            testCount = 1,
            instrumentationExpectedTestCount = 1,
        )
        outcome.exceptionOrNull()?.let {
            report.put("failure", JSONObject().put("type", it.javaClass.simpleName).put("code", "BASELINE_FAILED"))
        }
        File(context.filesDir, REPORT_FILE).writeText(report.toString(2))
    }

    private fun memorySnapshot(): JSONObject {
        val runtime = Runtime.getRuntime()
        val memory = Debug.MemoryInfo().also(Debug::getMemoryInfo)
        return JSONObject()
            .put("javaUsedBytes", runtime.totalMemory() - runtime.freeMemory())
            .put("nativeAllocatedBytes", Debug.getNativeHeapAllocatedSize())
            .put("totalPssBytes", memory.totalPss.toLong() * 1_024L)
    }

    private fun categoryCounts(plan: List<Alpha4SeekTarget>) = JSONObject().apply {
        Alpha4SeekCategory.entries.forEach { category ->
            put(category.wireName, plan.count { it.category == category })
        }
    }

    private fun containsFirstMiddleLast(plan: List<Alpha4SeekTarget>, frameCount: Int): Boolean {
        val targets = plan.map(Alpha4SeekTarget::targetFrameIndex).toSet()
        return setOf(0, frameCount / 2, frameCount - 1).all(targets::contains)
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

    private fun uri(privateFixtureName: String): Uri =
        Uri.parse("content://${context.packageName}.fixture/$privateFixtureName")

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

    private fun delta(before: Long, after: Long): Long = if (after >= before) after - before else after

    private fun selectedPlanWire(plan: String?): Any = when (plan) {
        null -> JSONObject.NULL
        "CACHE", "HISTORY", "REVERSE_WINDOW" -> "CACHE_HIT"
        else -> plan
    }

    companion object {
        const val REPORT_FILE = "s24-alpha6-random-performance-v1.json"
        private const val ASSET_DIRECTORY = "representative-resolution"
        private const val RESULT_TIMEOUT_MS = 30_000L
        private const val REQUIRED_CACHE_BUDGET_BYTES = 64L * 1024L * 1024L
        private val FIXTURES = listOf(
            FixtureSpec("720p-h264-bframes", "fixture-01", 0x41A4_0001L),
            FixtureSpec("1080p-h264-bframes", "fixture-02", 0x41A4_0002L),
            FixtureSpec("1080p-h264-long-gop", "fixture-03", 0x41A4_0003L),
            FixtureSpec("1080p-vfr", "fixture-04", 0x41A4_0004L),
            FixtureSpec("1080p-hevc-main8", "fixture-05", 0x41A4_0005L),
        )
    }
}
