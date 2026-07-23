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
import androidx.lifecycle.Lifecycle
import com.snowberried.ctcinereviewer.BuildConfig
import com.snowberried.ctcinereviewer.media.DecoderDiagnostics
import com.snowberried.ctcinereviewer.media.ContainerMetadata
import com.snowberried.ctcinereviewer.media.DecodedOutputMetadata
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.media.IndexedVideo
import com.snowberried.ctcinereviewer.media.PublicationEvent
import com.snowberried.ctcinereviewer.media.PublicationResult
import com.snowberried.ctcinereviewer.media.RequestAcceptance
import com.snowberried.ctcinereviewer.validation.ValidationHarnessIdentity
import com.snowberried.ctcinereviewer.validation.ValidationHarnessV2
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

private fun decodedOutputJson(metadata: DecodedOutputMetadata): JSONObject = JSONObject()
    .put("width", metadata.width)
    .put("height", metadata.height)
    .put("cropLeft", metadata.cropLeft)
    .put("cropTop", metadata.cropTop)
    .put("cropRight", metadata.cropRight)
    .put("cropBottom", metadata.cropBottom)
    .put("colorStandard", metadata.colorStandard)
    .put("colorRange", metadata.colorRange)
    .put("colorTransfer", metadata.colorTransfer)
    .put("mime", metadata.mime)
    .put("profile", metadata.profile)
    .put("colorFormat", metadata.colorFormat)
    .put("hdrStaticInfoPresent", metadata.hdrStaticInfoPresent)

private fun frameKeyJson(key: FrameKey): JSONObject = JSONObject()
    .put("displayFrameIndex", key.displayFrameIndex)
    .put("ptsUs", key.ptsUs)
    .put("duplicateOrdinal", key.duplicateOrdinal)

private fun publicationEventJson(event: PublicationEvent): JSONObject = JSONObject()
    .put("eventSequence", event.eventSequence)
    .put("elapsedRealtimeNanos", event.elapsedRealtimeNanos)
    .put("fileGeneration", event.fileGeneration)
    .put("requestGeneration", event.requestGeneration)
    .put("requestedFrameIndex", event.requestedFrameIndex)
    .put("expectedKey", frameKeyJson(event.expectedKey))
    .put("currentFileGeneration", event.currentFileGeneration)
    .put("currentRequestGeneration", event.currentRequestGeneration)
    .put("textureTimestampNs", event.textureTimestampNs)
    .put("swapAttempted", event.swapAttempted)
    .put("eglSwapBuffersResult", event.eglSwapBuffersResult ?: JSONObject.NULL)
    .put("result", event.result.name)

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
        report.bind(ValidationHarnessV2.requireIdentity(targetContext, instrumentation.context))
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
                val metadata = exerciseEveryFrame(gate, golden)
                report.fixtures += JSONObject()
                    .put("fixture", golden.fixture)
                    .put("sourceSha256", golden.sourceSha256)
                    .put("codec", golden.codec)
                    .put("profile", golden.profile)
                    .put("frameCount", golden.frames.size)
                    .put("codecComponent", metadata.codecComponent)
                    .put("hardwareAccelerated", metadata.hardwareAccelerated)
                    .put(
                        "configuredOutputMetadata",
                        lastDiagnostics.configuredOutputMetadata?.let(::decodedOutputJson) ?: JSONObject.NULL,
                    )
                    .put(
                        "decodedOutputFormatHistory",
                        JSONArray(lastDiagnostics.decodedOutputFormatHistory.map(::decodedOutputJson)),
                    )
            }
            exerciseNavigation(gate, loadGolden("burst"))
            exercisePrefetchContract(gate, loadGolden("burst"), loadGolden("switch-a"), loadGolden("switch-b"))
            exerciseBurst(gate, loadGolden("burst"))
            exerciseFileSwitch(gate, loadGolden("switch-a"), loadGolden("switch-b"))
            assertEquals("unexpected stale discard", 0L, report.unexpectedStaleViolationCount())
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
                mismatchCount = mismatchCount,
            )
        }
        scenario.close()
        outcome.exceptionOrNull()?.let { failure ->
            reportOutcome.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
        reportOutcome.getOrThrow()
    }

    @Test
    fun forwardSequentialStrideOneAndFiveRemainExactOnS24Ultra() {
        assumeTrue(
            "S24 Ultra Gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        report.bind(ValidationHarnessV2.requireIdentity(targetContext, instrumentation.context))
        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val scenario = ActivityScenario.launch(GateActivity::class.java)
        val activity = AtomicReference<GateActivity>()
        val ready = CountDownLatch(1)
        scenario.onActivity {
            activity.set(it)
            ready.countDown()
        }
        assertTrue("GateActivity unavailable", ready.await(5, TimeUnit.SECONDS))
        val gate = activity.get()
        assertTrue("EGL Surface was not created", gate.awaitSurface())
        gate.display.mode.let { report.captureDisplay(it.physicalWidth, it.physicalHeight, it.refreshRate) }

        val outcome = runCatching {
            SEQUENTIAL_FIXTURES.forEach { name ->
                val golden = loadGolden(name)
                assertEquals(golden.sourceSha256, assetSha256(golden.fixture))
                exerciseForwardSequential(gate, golden, stride = 1)
                exerciseForwardSequential(gate, golden, stride = 5)
            }
            assertEquals("source was opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
            assertEquals("exactness mismatch", 0, mismatchCount)
        }
        val reportOutcome = runCatching {
            report.finish(
                status = if (outcome.isSuccess) "PASS" else "FAIL",
                failure = outcome.exceptionOrNull(),
                latencyMs = emptyList(),
                diagnostics = lastDiagnostics,
                writeOpenCount = ReadOnlyFixtureProvider.writeOpenCount.get(),
                mismatchCount = mismatchCount,
                fileName = SEQUENTIAL_REPORT_FILE,
            )
        }
        scenario.close()
        outcome.exceptionOrNull()?.let { failure ->
            reportOutcome.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
        reportOutcome.getOrThrow()
    }

    @Test
    fun reverseWindowStrideMinusOneAndFiveRemainExactOnS24Ultra() {
        assumeTrue(
            "S24 Ultra Gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        report.bind(ValidationHarnessV2.requireIdentity(targetContext, instrumentation.context))
        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val scenario = ActivityScenario.launch(GateActivity::class.java)
        val activity = AtomicReference<GateActivity>()
        val ready = CountDownLatch(1)
        scenario.onActivity {
            activity.set(it)
            ready.countDown()
        }
        assertTrue("GateActivity unavailable", ready.await(5, TimeUnit.SECONDS))
        val gate = activity.get()
        assertTrue("EGL Surface was not created", gate.awaitSurface())

        val outcome = runCatching {
            SEQUENTIAL_FIXTURES.forEach { name ->
                val golden = loadGolden(name)
                assertEquals(golden.sourceSha256, assetSha256(golden.fixture))
                exerciseReverseSequential(gate, golden, stride = -1)
                exerciseReverseSequential(gate, golden, stride = -5)
            }
            assertEquals("source was opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
            assertEquals("exactness mismatch", 0, mismatchCount)
        }
        val reportOutcome = runCatching {
            report.finish(
                status = if (outcome.isSuccess) "PASS" else "FAIL",
                failure = outcome.exceptionOrNull(),
                latencyMs = emptyList(),
                diagnostics = lastDiagnostics,
                writeOpenCount = ReadOnlyFixtureProvider.writeOpenCount.get(),
                mismatchCount = mismatchCount,
                fileName = REVERSE_REPORT_FILE,
            )
        }
        scenario.close()
        outcome.exceptionOrNull()?.let { failure ->
            reportOutcome.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
        reportOutcome.getOrThrow()
    }

    @Test
    fun directionReversalAndGenerationInvalidationRemainExactOnS24Ultra() {
        assumeTrue(
            "S24 Ultra Gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        report.bind(ValidationHarnessV2.requireIdentity(targetContext, instrumentation.context))
        ReadOnlyFixtureProvider.writeOpenCount.set(0)
        val scenario = ActivityScenario.launch(GateActivity::class.java)
        val activity = AtomicReference<GateActivity>()
        val ready = CountDownLatch(1)
        scenario.onActivity {
            activity.set(it)
            ready.countDown()
        }
        assertTrue("GateActivity unavailable", ready.await(5, TimeUnit.SECONDS))
        val gate = activity.get()
        assertTrue("EGL Surface was not created", gate.awaitSurface())

        val outcome = runCatching {
            val h264 = loadGolden("h264-bframes")
            val hevc = loadGolden("hevc-main8")
            openAndAwait(gate, h264)
            val anchor = minOf(20, h264.frames.lastIndex)
            requestAndValidate(gate, h264, anchor)

            val firstGesture = AtomicReference<Long>()
            onMain(gate) {
                firstGesture.set(gate.beginHoldGesture())
                checkNotNull(gate.requestReverseSequentialFrame(anchor - 1, -1, firstGesture.get()))
            }
            awaitPublished(gate, h264, anchor - 1)
            val reversePlanCountBeforeDirect = lastDiagnostics.randomSeekReverseWindowPlanCount
            requestAndValidate(gate, h264, anchor - 2)
            assertTrue(
                "direct seek did not reuse an exact reverse-window texture",
                lastDiagnostics.randomSeekReverseWindowPlanCount > reversePlanCountBeforeDirect,
            )

            onMain(gate) {
                gate.endHoldGesture(firstGesture.get())
                checkNotNull(gate.requestForwardSequentialFrame(anchor - 1, 1))
            }
            awaitPublished(gate, h264, anchor - 1)

            // Reopen to clear generic/reverse textures, then stop the actor at the first
            // cache-only reverse-window output. This makes the Surface-generation race
            // deterministic instead of merely replacing the Surface near a build.
            openAndAwait(gate, h264)
            requestAndValidate(gate, h264, anchor)
            val replacementReady = AtomicReference<CountDownLatch>()
            val surfaceInvalidationAcceptance = AtomicReference<RequestAcceptance>()
            assertTrue("reverse build barrier was already armed", gate.armReverseWindowBuildBarrier())
            try {
                onMain(gate) {
                    val gesture = gate.beginHoldGesture()
                    surfaceInvalidationAcceptance.set(
                        checkNotNull(gate.requestReverseSequentialFrame(anchor - 1, -1, gesture)),
                    )
                }
                report.expectGenerationInvalidationDiscard(
                    phase = "surface-generation-supersede",
                    fixture = h264.fixture,
                    acceptance = surfaceInvalidationAcceptance.get(),
                )
                assertTrue(
                    "reverse window did not enter cache-only build",
                    gate.awaitReverseWindowBuildBarrierEntry(5_000),
                )
                onMain(gate) { replacementReady.set(gate.replaceSurfaceForTest()) }
                assertTrue(
                    "replacement Surface was not ready",
                    replacementReady.get().await(10, TimeUnit.SECONDS),
                )
            } finally {
                gate.releaseReverseWindowBuildBarrier()
            }
            assertTrue("actor did not settle after Surface replacement", gate.awaitActorIdle(10_000))
            assertTrue("main callbacks did not settle after Surface replacement", gate.awaitMainCallbacks(10_000))
            val surfaceInvalidationResults = gate.drainResults()
            surfaceInvalidationResults.forEach(report::observeResult)
            val oldGenerationPublications = surfaceInvalidationResults.count { it.result is FrameResult.Published }
            assertEquals("old Surface generation published a frame", 0, oldGenerationPublications)
            report.endSupersedePhase("surface-generation-supersede")
            gate.clearResults()
            requestAndValidate(gate, h264, anchor - 3)

            // Prove lifecycle stop invalidation with the exactness renderer. The UI
            // lifecycle test verifies requested/displayed state restoration; this
            // companion also verifies the restored texture timestamp, embedded ID,
            // and canonical signature against the frozen golden vector.
            openAndAwait(gate, h264)
            requestAndValidate(gate, h264, anchor)
            gate.clearResults()
            val surfaceGenerationBeforeStop = gate.surfaceAvailabilityGeneration()
            val lifecycleInvalidationAcceptance = AtomicReference<RequestAcceptance>()
            assertTrue("lifecycle reverse build barrier was already armed", gate.armReverseWindowBuildBarrier())
            try {
                onMain(gate) {
                    val gesture = gate.beginHoldGesture()
                    lifecycleInvalidationAcceptance.set(
                        checkNotNull(gate.requestReverseSequentialFrame(anchor - 1, -1, gesture)),
                    )
                }
                report.expectGenerationInvalidationDiscard(
                    phase = "lifecycle-stop-supersede",
                    fixture = h264.fixture,
                    acceptance = lifecycleInvalidationAcceptance.get(),
                )
                assertTrue(
                    "lifecycle reverse window did not enter cache-only build",
                    gate.awaitReverseWindowBuildBarrierEntry(5_000),
                )
                scenario.moveToState(Lifecycle.State.CREATED)
                assertTrue(
                    "lifecycle stop did not invalidate the decoder Surface",
                    gate.awaitSurfaceAvailabilityAfter(surfaceGenerationBeforeStop, false, 10_000),
                )
            } finally {
                gate.releaseReverseWindowBuildBarrier()
            }
            assertTrue("actor did not settle after lifecycle stop", gate.awaitActorIdle(10_000))
            assertTrue("main callbacks did not settle after lifecycle stop", gate.awaitMainCallbacks(10_000))
            val lifecycleInvalidationResults = gate.drainResults()
            lifecycleInvalidationResults.forEach(report::observeResult)
            assertEquals(
                "stopped lifecycle published an in-flight reverse frame",
                0,
                lifecycleInvalidationResults.count { it.result is FrameResult.Published },
            )
            report.endSupersedePhase("lifecycle-stop-supersede")
            val surfaceGenerationBeforeResume = gate.surfaceAvailabilityGeneration()
            scenario.moveToState(Lifecycle.State.RESUMED)
            assertTrue(
                "resumed exactness Surface was not ready",
                gate.awaitSurfaceAvailabilityAfter(surfaceGenerationBeforeResume, true, 10_000),
            )
            gate.clearResults()
            requestAndValidate(gate, h264, anchor - 1)

            openAndAwait(gate, hevc)
            requestAndValidate(gate, hevc, minOf(hevc.frames.lastIndex, 8))
            openAndAwait(gate, h264)
            requestAndValidate(gate, h264, minOf(h264.frames.lastIndex, 8))

            assertEquals("source was opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
            assertEquals("exactness mismatch", 0, mismatchCount)
            assertEquals("generation invalidation stale evidence", 2L, report.expectedStaleDiscardCount())
            assertEquals("unexpected stale discard", 0L, report.unexpectedStaleViolationCount())
            assertEquals(0L, lastDiagnostics.staleBeforeSwapCount)
            assertEquals(0L, lastDiagnostics.swapFailureCount)
            assertEquals(0L, lastDiagnostics.surfaceInvalidCount)
            assertEquals(0L, lastDiagnostics.publicationInvariantViolationCount)
            assertTrue(lastDiagnostics.peakCacheBytes <= lastDiagnostics.cacheBudgetBytes)
            assertEquals(0L, lastDiagnostics.textureDoubleReleaseCount)
        }
        val reportOutcome = runCatching {
            report.finish(
                status = if (outcome.isSuccess) "PASS" else "FAIL",
                failure = outcome.exceptionOrNull(),
                latencyMs = emptyList(),
                diagnostics = lastDiagnostics,
                writeOpenCount = ReadOnlyFixtureProvider.writeOpenCount.get(),
                mismatchCount = mismatchCount,
                fileName = DIRECTION_REPORT_FILE,
            )
        }
        scenario.close()
        outcome.exceptionOrNull()?.let { failure ->
            reportOutcome.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
        reportOutcome.getOrThrow()
    }

    private fun exerciseEveryFrame(activity: GateActivity, golden: Golden): ContainerMetadata {
        report.currentPhase = "every-frame"
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
        return metadata
    }

    private fun exerciseNavigation(activity: GateActivity, golden: Golden) {
        report.currentPhase = "navigation"
        report.currentFixture = golden.fixture
        openAndAwait(activity, golden)
        val middle = golden.frames.size / 2
        val sequence = listOf(golden.frames.lastIndex, 0, middle, middle - 1, middle + 4, 1, golden.frames.lastIndex - 1)
        sequence.forEach { requestAndValidate(activity, golden, it) }
    }

    private fun exerciseForwardSequential(activity: GateActivity, golden: Golden, stride: Int) {
        report.currentPhase = "forward-sequential"
        report.currentFixture = golden.fixture
        val mismatchBefore = mismatchCount
        val metadata = openAndAwait(activity, golden)
        var diagnostics = lastDiagnostics
        var requestCount = 0
        for (index in stride..golden.frames.lastIndex step stride) {
            report.currentFrameIndex = index
            activity.clearResults()
            val acceptance = AtomicReference<RequestAcceptance>()
            onMain(activity) {
                activity.requestForwardSequentialFrame(index, stride)?.let(acceptance::set)
            }
            assertNotNull("${golden.fixture}[$index]: sequential request was not accepted", acceptance.get())
            diagnostics = awaitPublished(activity, golden, index).diagnostics
            lastDiagnostics = diagnostics
            requestCount += 1
        }
        assertEquals("${golden.fixture}: stride $stride exactness mismatch", mismatchBefore, mismatchCount)
        assertTrue("${golden.fixture}: stride $stride never entered sequential decode", diagnostics.sequentialEntryCount > 0)
        assertTrue("${golden.fixture}: stride $stride emitted no sequential output", diagnostics.sequentialOutputCount > 0)
        assertEquals("${golden.fixture}: stride $stride stale result", 0L, diagnostics.staleDiscardCount)
        assertEquals("${golden.fixture}: stride $stride stale swap", 0L, diagnostics.staleBeforeSwapCount)
        assertEquals("${golden.fixture}: stride $stride swap failure", 0L, diagnostics.swapFailureCount)
        assertEquals("${golden.fixture}: stride $stride invalid surface", 0L, diagnostics.surfaceInvalidCount)
        assertEquals(
            "${golden.fixture}: stride $stride publication invariant",
            0L,
            diagnostics.publicationInvariantViolationCount,
        )
        assertEquals("${golden.fixture}: stride $stride cache rejection", 0L, diagnostics.cacheRejectionCount)
        assertEquals("${golden.fixture}: stride $stride cache thrash", 0L, diagnostics.cacheThrashCount)
        assertEquals("${golden.fixture}: stride $stride texture double release", 0L, diagnostics.textureDoubleReleaseCount)
        assertTrue(
            "${golden.fixture}: stride $stride cache exceeded byte budget",
            diagnostics.cacheBytes <= diagnostics.cacheBudgetBytes,
        )
        assertEquals("${golden.fixture}: stride $stride unexpectedly started prefetch", 0L, diagnostics.prefetchStarted)
        if (stride == 1) {
            report.fixtures += JSONObject()
                .put("fixture", golden.fixture)
                .put("sourceSha256", golden.sourceSha256)
                .put("codec", golden.codec)
                .put("profile", golden.profile)
                .put("frameCount", golden.frames.size)
                .put("codecComponent", metadata.codecComponent)
                .put("hardwareAccelerated", metadata.hardwareAccelerated)
        }
        report.codecComponents += metadata.codecComponent
        report.sequentialRuns += JSONObject()
            .put("fixture", golden.fixture)
            .put("sourceSha256", golden.sourceSha256)
            .put("codec", golden.codec)
            .put("profile", golden.profile)
            .put("frameCount", golden.frames.size)
            .put("codecComponent", metadata.codecComponent)
            .put("hardwareAccelerated", metadata.hardwareAccelerated)
            .put("stride", stride)
            .put("requestCount", requestCount)
            .put("mismatchCount", mismatchCount - mismatchBefore)
            .put("sequentialEntryCount", diagnostics.sequentialEntryCount)
            .put("sequentialFallbackCount", diagnostics.sequentialFallbackCount)
            .put("sequentialOutputCount", diagnostics.sequentialOutputCount)
    }

    private fun exerciseReverseSequential(activity: GateActivity, golden: Golden, stride: Int) {
        report.currentPhase = "reverse-sequential"
        report.currentFixture = golden.fixture
        val mismatchBefore = mismatchCount
        openAndAwait(activity, golden)
        requestAndValidate(activity, golden, golden.frames.lastIndex)
        val gesture = activity.beginHoldGesture()
        var diagnostics = lastDiagnostics
        var requestCount = 0
        var index = golden.frames.lastIndex + stride
        while (index >= 0) {
            report.currentFrameIndex = index
            activity.clearResults()
            val acceptance = AtomicReference<RequestAcceptance>()
            onMain(activity) {
                activity.requestReverseSequentialFrame(index, stride, gesture)?.let(acceptance::set)
            }
            assertNotNull("${golden.fixture}[$index]: reverse request was not accepted", acceptance.get())
            diagnostics = awaitPublished(activity, golden, index).diagnostics
            lastDiagnostics = diagnostics
            requestCount += 1
            index += stride
        }
        onMain(activity) { activity.endHoldGesture(gesture) }
        assertEquals("${golden.fixture}: stride $stride exactness mismatch", mismatchBefore, mismatchCount)
        assertTrue("${golden.fixture}: stride $stride built no reverse window", diagnostics.reverseWindowBuildCount > 0)
        assertTrue(
            "${golden.fixture}: stride $stride repeated exact seek per target",
            diagnostics.reverseWindowSeekCount < requestCount,
        )
        assertTrue(
            "${golden.fixture}: stride $stride cached navigation never bypassed the actor",
            diagnostics.cachedNavigationActorBypassCount > 0,
        )
        assertTrue(
            "${golden.fixture}: stride $stride refill generation sought more than once",
            diagnostics.reverseRefillMaxSeekPerGeneration <= 1,
        )
        assertTrue(
            "${golden.fixture}: stride $stride refill generation flushed more than once",
            diagnostics.reverseRefillMaxFlushPerGeneration <= 1,
        )
        assertEquals(
            "${golden.fixture}: stride $stride refill restarted",
            0L,
            diagnostics.reverseRefillRestartCount,
        )
        assertEquals("${golden.fixture}: stride $stride stale result", 0L, diagnostics.staleDiscardCount)
        assertEquals("${golden.fixture}: stride $stride stale swap", 0L, diagnostics.staleBeforeSwapCount)
        assertEquals("${golden.fixture}: stride $stride swap failure", 0L, diagnostics.swapFailureCount)
        assertEquals("${golden.fixture}: stride $stride invalid surface", 0L, diagnostics.surfaceInvalidCount)
        assertEquals(
            "${golden.fixture}: stride $stride publication invariant",
            0L,
            diagnostics.publicationInvariantViolationCount,
        )
        assertEquals("${golden.fixture}: stride $stride texture double release", 0L, diagnostics.textureDoubleReleaseCount)
        assertTrue(
            "${golden.fixture}: stride $stride cache exceeded byte budget",
            diagnostics.cacheBytes <= diagnostics.cacheBudgetBytes,
        )
        assertEquals("${golden.fixture}: stride $stride unexpectedly started prefetch", 0L, diagnostics.prefetchStarted)
        report.sequentialRuns += JSONObject()
            .put("fixture", golden.fixture)
            .put("sourceSha256", golden.sourceSha256)
            .put("stride", stride)
            .put("requestCount", requestCount)
            .put("mismatchCount", mismatchCount - mismatchBefore)
            .put("reverseWindowBuildCount", diagnostics.reverseWindowBuildCount)
            .put("reverseWindowRefillCount", diagnostics.reverseWindowRefillCount)
            .put("reverseWindowInitialReadyCount", diagnostics.reverseWindowInitialReadyCount)
            .put("reverseWindowRollingAppendRefillCount", diagnostics.reverseWindowRollingAppendRefillCount)
            .put("reverseWindowRefillNeeded", diagnostics.reverseWindowRefillNeeded)
            .put("reverseWindowSeekCount", diagnostics.reverseWindowSeekCount)
            .put("reverseWindowHitCount", diagnostics.reverseWindowHitCount)
            .put("cachedNavigationAttemptCount", diagnostics.cachedNavigationAttemptCount)
            .put("cachedNavigationActorBypassCount", diagnostics.cachedNavigationActorBypassCount)
            .put("cachedNavigationMissFallbackCount", diagnostics.cachedNavigationMissFallbackCount)
            .put("cachedNavigationQueueWaitMaxUs", diagnostics.cachedNavigationQueueWaitMaxUs)
            .put("reverseRefillGenerationCount", diagnostics.reverseRefillGenerationCount)
            .put("reverseRefillInitialSeekCount", diagnostics.reverseRefillInitialSeekCount)
            .put("reverseRefillInitialFlushCount", diagnostics.reverseRefillInitialFlushCount)
            .put("reverseRefillResumedSliceCount", diagnostics.reverseRefillResumedSliceCount)
            .put("reverseRefillRestartCount", diagnostics.reverseRefillRestartCount)
            .put("reverseRefillMaxSeekPerGeneration", diagnostics.reverseRefillMaxSeekPerGeneration)
            .put("reverseRefillMaxFlushPerGeneration", diagnostics.reverseRefillMaxFlushPerGeneration)
            .put("reverseLowWaterTriggerCount", diagnostics.reverseLowWaterTriggerCount)
            .put("reversePartialAppendCount", diagnostics.reversePartialAppendCount)
            .put("reverseDepletionBeforeRefillCount", diagnostics.reverseDepletionBeforeRefillCount)
            .put("reverseRefillAssociatedGapCount", diagnostics.reverseRefillAssociatedGapCount)
    }

    private fun exerciseBurst(activity: GateActivity, golden: Golden) {
        report.currentPhase = "burst-supersede"
        report.currentFixture = golden.fixture
        openAndAwait(activity, golden)
        activity.clearResults()
        val sequence = listOf(1, 6, 12, 24, golden.frames.lastIndex)
        val acceptances = mutableListOf<RequestAcceptance>()
        onMain(activity) {
            sequence.forEach { index -> activity.requestFrame(index)?.let(acceptances::add) }
        }
        assertEquals("burst accepted request count", sequence.size, acceptances.size)
        val accepted = requireNotNull(acceptances.lastOrNull()) { "burst final request was not accepted" }
        assertEquals("burst final accepted target", sequence.last(), accepted.request.requestedFrameIndex)
        acceptances.dropLast(1).forEach { acceptance ->
            report.expectSupersededDiscard(
                phase = "burst-supersede",
                fixture = golden.fixture,
                acceptance = acceptance,
                supersedingAcceptance = accepted,
            )
        }
        var finalPublished = false
        val deadline = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < deadline && !finalPublished) {
            val observed = activity.awaitResult(2) ?: continue
            lastDiagnostics = observed.diagnostics
            report.observeResult(observed)
            assertEquals(
                "${golden.fixture}: cache budget changed",
                REQUIRED_CACHE_BUDGET_BYTES,
                observed.diagnostics.cacheBudgetBytes,
            )
            assertTrue(
                "${golden.fixture}: cache bytes exceeded the hard cap",
                observed.diagnostics.cacheBytes in 0L..observed.diagnostics.cacheBudgetBytes,
            )
            assertTrue(
                "${golden.fixture}: peak cache bytes exceeded the hard cap",
                observed.diagnostics.peakCacheBytes in
                    observed.diagnostics.cacheBytes..observed.diagnostics.cacheBudgetBytes,
            )
            when (val result = observed.result) {
                is FrameResult.Published -> {
                    validatePublished(golden, result)
                    if (result.request.requestedFrameIndex == golden.frames.lastIndex) {
                        assertEquals("burst final publication acceptance", accepted.request, result.request)
                        finalPublished = true
                    }
                }
                is FrameResult.DiscardedStale -> Unit
                is FrameResult.Error -> error("burst error: ${result.code}")
                is FrameResult.Unsupported -> error("burst unsupported: ${result.reason}")
            }
        }
        assertTrue("burst final frame was not published", finalPublished)
        Thread.sleep(100)
        assertTrue("burst actor did not settle", activity.awaitActorIdle())
        assertTrue("burst main callbacks did not settle", activity.awaitMainCallbacks())
        val invalidSuccessfulSwap = activity.drainPublicationEvents().any { event ->
            event.eventSequence > accepted.eventSequence &&
                event.result == PublicationResult.PUBLISHED &&
                (event.fileGeneration != accepted.request.token.fileGeneration ||
                    event.requestGeneration != accepted.request.token.requestGeneration)
        }
        assertEquals("old generation swapped after final request acceptance", false, invalidSuccessfulSwap)
        assertEquals("publication invariant violation", 0L, lastDiagnostics.publicationInvariantViolationCount)
        activity.drainResults().forEach(report::observeResult)
        report.endSupersedePhase("burst-supersede")
    }

    private fun exercisePrefetchContract(
        activity: GateActivity,
        golden: Golden,
        first: Golden,
        second: Golden,
    ) {
        report.currentPhase = "prefetch-contract"
        report.currentFixture = golden.fixture
        openAndAwait(activity, golden)
        assertTrue("initial frame actor did not become idle", activity.awaitActorIdle())
        assertEquals("initial open started speculative prefetch", 0L, lastDiagnostics.prefetchStarted)
        assertEquals("initial open completed speculative prefetch", 0L, lastDiagnostics.prefetchCompleted)
        activity.clearResults()
        val activationIndex = minOf(1, golden.frames.lastIndex)
        onMain(activity) { activity.requestDirectionalFrame(activationIndex) }
        val activation = awaitPublished(activity, golden, activationIndex)
        assertEquals("first directional request unexpectedly hit initial prefetch", false, (activation.result as FrameResult.Published).cacheHit)
        activity.drainPublicationEvents()
        assertTrue("directional prefetch actor did not become idle", activity.awaitActorIdle())
        assertTrue("cache-only prefetch emitted a publication event", activity.drainPublicationEvents().isEmpty())

        val prefetchedIndex = minOf(activationIndex + DISCRETE_PREFETCH_PROBE_DEPTH, golden.frames.lastIndex)
        onMain(activity) { activity.requestFrame(prefetchedIndex) }
        val prefetched = awaitPublished(activity, golden, prefetchedIndex)
        val published = prefetched.result as FrameResult.Published
        assertTrue("look-ahead frame was not served from cache", published.cacheHit)
        assertTrue("prefetch diagnostics did not advance", prefetched.diagnostics.prefetchedFrameCount > 0)

        report.currentFixture = first.fixture
        openAndAwait(activity, first)
        activity.clearResults()
        val firstActivationIndex = minOf(1, first.frames.lastIndex)
        onMain(activity) { activity.requestDirectionalFrame(firstActivationIndex) }
        awaitPublished(activity, first, firstActivationIndex)
        activity.drainPublicationEvents()
        assertTrue("file A directional prefetch actor did not become idle", activity.awaitActorIdle())
        assertTrue("file A prefetch emitted a publication event", activity.drainPublicationEvents().isEmpty())

        report.currentFixture = second.fixture
        open(activity, second.fixture)
        requireNotNull(activity.awaitIndex()) { "${second.fixture}: index timeout" }
        val secondMetadata = requireNotNull(activity.awaitMetadata()) { "${second.fixture}: metadata timeout" }
        val secondFirst = awaitPublished(activity, second, 0)
        assertEquals(secondMetadata.fileGeneration, secondFirst.result.request.token.fileGeneration)
        assertEquals("file A texture survived file B generation", false, (secondFirst.result as FrameResult.Published).cacheHit)
    }

    private fun exerciseFileSwitch(activity: GateActivity, first: Golden, second: Golden) {
        report.currentPhase = "file-switch-supersede"
        report.currentFixture = first.fixture
        openAndAwait(activity, first)
        activity.clearResults()
        val superseded = AtomicReference<RequestAcceptance>()
        onMain(activity) {
            activity.requestFrame(first.frames.lastIndex)?.let(superseded::set)
            report.currentFixture = second.fixture
            report.currentFrameIndex = 0
            activity.openFixture(uri(second.fixture))
        }
        val secondIndex = requireNotNull(activity.awaitIndex()) { "switch B index timeout" }
        val secondMetadata = requireNotNull(activity.awaitMetadata()) { "switch B metadata timeout" }
        report.expectSupersededDiscard(
            phase = "file-switch-supersede",
            fixture = first.fixture,
            acceptance = requireNotNull(superseded.get()) { "switch A request was not accepted" },
            supersedingFileGeneration = secondMetadata.fileGeneration,
        )
        validateIndex(second, secondIndex)
        validateMetadata(second, secondMetadata)
        val published = awaitPublished(activity, second, 0)
        val secondPublished = published.result as FrameResult.Published
        assertEquals(secondMetadata.fileGeneration, secondPublished.request.token.fileGeneration)
        report.bindFileSwitchPublicationBoundary(secondPublished)
        Thread.sleep(500)
        assertTrue("file switch actor did not settle", activity.awaitActorIdle())
        assertTrue("file switch main callbacks did not settle", activity.awaitMainCallbacks())
        val stalePublication = activity.drainPublicationEvents().any { event ->
            event.result == PublicationResult.PUBLISHED &&
                event.fileGeneration != secondMetadata.fileGeneration &&
                event.currentFileGeneration == secondMetadata.fileGeneration
        }
        assertEquals("A frame swapped after B file generation", false, stalePublication)
        val lateResults = activity.drainResults()
        lateResults.forEach(report::observeResult)
        report.endSupersedePhase("file-switch-supersede")
        val lateA = lateResults.map(GateActivity.ObservedResult::result).filterIsInstance<FrameResult.Published>()
            .count { it.request.token.fileGeneration != secondMetadata.fileGeneration }
        assertEquals("A frame published after B file generation", 0, lateA)
    }

    private fun openAndAwait(activity: GateActivity, golden: Golden): ContainerMetadata {
        open(activity, golden.fixture)
        validateIndex(golden, requireNotNull(activity.awaitIndex()) { "${golden.fixture}: index timeout" })
        val metadata = requireNotNull(activity.awaitMetadata()) { "${golden.fixture}: metadata timeout" }
        validateMetadata(golden, metadata)
        awaitPublished(activity, golden, 0)
        return metadata
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
        val expected = golden.frames[expectedIndex]
        report.expect(
            fixture = golden.fixture,
            frameIndex = expected.displayFrameIndex,
            key = FrameKey(expected.displayFrameIndex, expected.ptsUs, expected.duplicateOrdinal),
        )
        val deadline = SystemClock.elapsedRealtime() + 20_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val observed = activity.awaitResult(2) ?: continue
            lastDiagnostics = observed.diagnostics
            report.observeResult(observed)
            assertEquals(
                "${golden.fixture}: cache budget changed",
                REQUIRED_CACHE_BUDGET_BYTES,
                observed.diagnostics.cacheBudgetBytes,
            )
            assertTrue(
                "${golden.fixture}: cache bytes exceeded the hard cap",
                observed.diagnostics.cacheBytes in 0L..observed.diagnostics.cacheBudgetBytes,
            )
            assertTrue(
                "${golden.fixture}: peak cache bytes exceeded the hard cap",
                observed.diagnostics.peakCacheBytes in
                    observed.diagnostics.cacheBytes..observed.diagnostics.cacheBudgetBytes,
            )
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
        report.observe(actual.request.expectedKey, actual.textureTimestampNs)
        mismatchCount += if (actual.request.expectedKey.displayFrameIndex != expected.displayFrameIndex) 1 else 0
        mismatchCount += if (actual.request.expectedKey.ptsUs != expected.ptsUs) 1 else 0
        mismatchCount += if (actual.request.expectedKey.duplicateOrdinal != expected.duplicateOrdinal) 1 else 0
        mismatchCount += if (actual.textureTimestampNs != expected.ptsUs * 1_000L) 1 else 0
        val imageProbe = requireNotNull(actual.imageProbe) { "${golden.fixture}: exactness probe missing" }
        mismatchCount += if (imageProbe.embeddedFrameId != expected.embeddedFrameId) 1 else 0
        assertEquals(
            "${golden.fixture}: signature length",
            expected.imageSignature.size,
            imageProbe.imageSignature.size,
        )
        val errors = imageProbe.imageSignature.zip(expected.imageSignature) { left, right -> kotlin.math.abs(left - right) }.sorted()
        val mean = errors.average()
        val p99 = errors[(ceil(errors.size * 0.99).toInt() - 1).coerceAtLeast(0)]
        val maximum = errors.last()
        if (mean > 6.0 || p99 > 16 || maximum > 40) mismatchCount += 1
        assertEquals("${golden.fixture}: FrameKey index", expected.displayFrameIndex, actual.request.expectedKey.displayFrameIndex)
        assertEquals("${golden.fixture}: FrameKey PTS", expected.ptsUs, actual.request.expectedKey.ptsUs)
        assertEquals("${golden.fixture}: duplicate ordinal", expected.duplicateOrdinal, actual.request.expectedKey.duplicateOrdinal)
        assertEquals("${golden.fixture}: texture timestamp", expected.ptsUs * 1_000L, actual.textureTimestampNs)
        assertEquals("${golden.fixture}: embedded ID", expected.embeddedFrameId, imageProbe.embeddedFrameId)
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

    private fun validateMetadata(golden: Golden, actual: ContainerMetadata) {
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
        val sequentialRuns = mutableListOf<JSONObject>()
        val codecComponents = linkedSetOf<String>()
        var currentPhase = "unclassified"
        var currentFixture: String? = null
        var currentFrameIndex: Int? = null
        private var expectedFrameKey: FrameKey? = null
        private var actualFrameKey: FrameKey? = null
        private var textureTimestampNs: Long? = null
        private var displayWidth: Int? = null
        private var displayHeight: Int? = null
        private var refreshRate: Float? = null
        private var staleDiscardCount = 0L
        private var staleBeforeSwapCount = 0L
        private var swapFailureCount = 0L
        private var surfaceInvalidCount = 0L
        private var publicationInvariantViolationCount = 0L
        private var cacheRejectionCount = 0L
        private var cacheThrashCount = 0L
        private var textureDoubleReleaseCount = 0L
        private val expectedSupersededDiscards = mutableMapOf<Pair<Long, Long>, ExpectedSupersededDiscard>()
        private val staleDiscardEvents = mutableListOf<JSONObject>()
        private var expectedSupersededDiscardCount = 0L
        private var observedUnexpectedStaleCount = 0L
        private lateinit var identity: ValidationHarnessIdentity
        private var startedAtElapsedRealtimeNs = 0L

        fun bind(identity: ValidationHarnessIdentity) {
            this.identity = identity
            startedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos()
        }

        fun captureDisplay(width: Int, height: Int, refreshRate: Float) {
            displayWidth = width
            displayHeight = height
            this.refreshRate = refreshRate
        }

        fun expect(fixture: String, frameIndex: Int, key: FrameKey) {
            currentFixture = fixture
            currentFrameIndex = frameIndex
            expectedFrameKey = key
            actualFrameKey = null
            textureTimestampNs = null
        }

        fun observe(key: FrameKey, timestampNs: Long) {
            actualFrameKey = key
            textureTimestampNs = timestampNs
        }

        fun expectSupersededDiscard(
            phase: String,
            fixture: String,
            acceptance: RequestAcceptance,
            supersedingAcceptance: RequestAcceptance? = null,
            supersedingFileGeneration: Long? = null,
        ) {
            check(phase == "burst-supersede" || phase == "file-switch-supersede") {
                "unsupported expected stale phase: $phase"
            }
            val token = acceptance.request.token
            if (phase == "file-switch-supersede") {
                check(supersedingAcceptance == null) { "file switch must not bind a request boundary" }
                checkNotNull(supersedingFileGeneration) { "file switch boundary generation is required" }
                check(supersedingFileGeneration == token.fileGeneration + 1L) {
                    "file switch boundary did not advance: $token -> $supersedingFileGeneration"
                }
            } else {
                val supersedingRequest = checkNotNull(supersedingAcceptance) {
                    "burst final acceptance boundary is required"
                }.request
                check(supersedingRequest.token.fileGeneration == token.fileGeneration &&
                    supersedingRequest.token.requestGeneration > token.requestGeneration) {
                    "burst acceptance boundary did not advance: $token -> ${supersedingRequest.token}"
                }
                check(supersedingFileGeneration == null) { "burst must not bind a file generation boundary" }
            }
            check(
                expectedSupersededDiscards.put(
                    token.fileGeneration to token.requestGeneration,
                    ExpectedSupersededDiscard(
                        phase,
                        fixture,
                        acceptance,
                        supersedingAcceptance?.request?.token?.requestGeneration,
                        supersedingAcceptance?.request?.token?.fileGeneration ?: supersedingFileGeneration,
                    ),
                ) == null,
            ) { "duplicate expected stale token: $token" }
        }

        fun expectGenerationInvalidationDiscard(
            phase: String,
            fixture: String,
            acceptance: RequestAcceptance,
        ) {
            check(phase == "surface-generation-supersede" || phase == "lifecycle-stop-supersede") {
                "unsupported generation invalidation phase: $phase"
            }
            val token = acceptance.request.token
            check(
                expectedSupersededDiscards.put(
                    token.fileGeneration to token.requestGeneration,
                    ExpectedSupersededDiscard(phase, fixture, acceptance, null, null),
                ) == null,
            ) { "duplicate expected stale token: $token" }
        }

        fun observeResult(observed: GateActivity.ObservedResult) {
            observeDiagnostics(observed.diagnostics)
            val result = observed.result as? FrameResult.DiscardedStale ?: return
            val token = result.request.token
            val expected = expectedSupersededDiscards.remove(token.fileGeneration to token.requestGeneration)
            val expectedStage = when (expected?.phase) {
                "surface-generation-supersede", "lifecycle-stop-supersede" ->
                    result.stage == "reverse-window-build"
                else -> result.stage in EXPECTED_SUPERSEDED_STAGES
            }
            val expectedMatch = expected?.acceptance?.request == result.request &&
                expectedStage
            val classification = if (expectedMatch) "EXPECTED_SUPERSEDED" else "UNEXPECTED"
            if (expectedMatch) expectedSupersededDiscardCount += 1 else observedUnexpectedStaleCount += 1
            staleDiscardEvents += JSONObject()
                .put("phase", expected?.phase ?: currentPhase)
                .put("fixture", expected?.fixture ?: currentFixture ?: "unknown")
                .put("observedWhileFixture", currentFixture ?: JSONObject.NULL)
                .put("fileGeneration", token.fileGeneration)
                .put("requestGeneration", token.requestGeneration)
                .put("requestedFrameIndex", result.request.requestedFrameIndex)
                .put("stage", result.stage)
                .put("supersedingRequestGeneration", expected?.supersedingRequestGeneration ?: JSONObject.NULL)
                .put("supersedingFileGeneration", expected?.supersedingFileGeneration ?: JSONObject.NULL)
                .put("classification", classification)
        }

        fun endSupersedePhase(phase: String) {
            expectedSupersededDiscards.entries.removeAll { (_, expected) -> expected.phase == phase }
        }

        fun bindFileSwitchPublicationBoundary(published: FrameResult.Published) {
            val token = published.request.token
            expectedSupersededDiscards.entries.forEach { entry ->
                val expected = entry.value
                if (expected.phase != "file-switch-supersede") return@forEach
                check(token.fileGeneration == expected.supersedingFileGeneration &&
                    token.requestGeneration > expected.acceptance.request.token.requestGeneration) {
                    "file switch publication boundary did not advance: ${expected.acceptance.request.token} -> $token"
                }
                entry.setValue(expected.copy(supersedingRequestGeneration = token.requestGeneration))
            }
            staleDiscardEvents.forEach { event ->
                if (event.optString("phase") == "file-switch-supersede") {
                    check(token.fileGeneration == event.getLong("supersedingFileGeneration") &&
                        token.requestGeneration > event.getLong("requestGeneration")) {
                        "observed file switch publication boundary did not advance"
                    }
                    event.put("supersedingRequestGeneration", token.requestGeneration)
                }
            }
        }

        private fun observeDiagnostics(value: DecoderDiagnostics) {
            staleDiscardCount = maxOf(staleDiscardCount, value.staleDiscardCount)
            staleBeforeSwapCount = maxOf(staleBeforeSwapCount, value.staleBeforeSwapCount)
            swapFailureCount = maxOf(swapFailureCount, value.swapFailureCount)
            surfaceInvalidCount = maxOf(surfaceInvalidCount, value.surfaceInvalidCount)
            publicationInvariantViolationCount = maxOf(
                publicationInvariantViolationCount,
                value.publicationInvariantViolationCount,
            )
            cacheRejectionCount = maxOf(cacheRejectionCount, value.cacheRejectionCount)
            cacheThrashCount = maxOf(cacheThrashCount, value.cacheThrashCount)
            textureDoubleReleaseCount = maxOf(textureDoubleReleaseCount, value.textureDoubleReleaseCount)
        }

        fun unexpectedStaleViolationCount(): Long = observedUnexpectedStaleCount

        fun expectedStaleDiscardCount(): Long = expectedSupersededDiscardCount

        fun finish(
            status: String,
            failure: Throwable?,
            latencyMs: List<Double>,
            diagnostics: DecoderDiagnostics,
            writeOpenCount: Int,
            mismatchCount: Int,
            fileName: String = REPORT_FILE,
        ) {
            val sorted = latencyMs.sorted()
            fun percentile(value: Double): Double? = sorted.takeIf { it.isNotEmpty() }
                ?.get((ceil(sorted.size * value).toInt() - 1).coerceIn(0, sorted.lastIndex))
            val power = context.getSystemService(PowerManager::class.java)
            val battery = context.getSystemService(BatteryManager::class.java)
            val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            val kind = when (fileName) {
                SEQUENTIAL_REPORT_FILE -> "forward-sequential-exact"
                REVERSE_REPORT_FILE -> "reverse-window-exact"
                DIRECTION_REPORT_FILE -> "bidirectional-transition-exact"
                else -> "frame-accuracy-exact"
            }
            val json = JSONObject()
                .put("schemaVersion", 2)
                .put("kind", kind)
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
                .put("appVersionName", packageInfo.versionName)
                .put("appVersionCode", packageInfo.longVersionCode)
                .put("appCommitSha", BuildConfig.COMMIT_SHA)
                .put("codecComponents", JSONArray(codecComponents.toList()))
                .put("fixtures", JSONArray(fixtures))
                .put("forwardSequentialRuns", JSONArray(sequentialRuns))
                .put("latencyMs", JSONObject()
                    .put("count", sorted.size)
                    .put("p50", percentile(0.50))
                    .put("p95", percentile(0.95))
                    .put("max", sorted.maxOrNull()))
                .put("decoder", JSONObject()
                    .put("cacheHits", diagnostics.cacheHitCount)
                    .put("cacheMisses", diagnostics.cacheMissCount)
                    .put("prefetchedFrames", diagnostics.prefetchedFrameCount)
                    .put("cacheBytes", diagnostics.cacheBytes)
                    .put("peakCacheBytes", diagnostics.peakCacheBytes)
                    .put("cacheEntryCount", diagnostics.cacheEntryCount)
                    .put("peakCacheEntryCount", diagnostics.peakCacheEntryCount)
                    .put("cacheEvictionCount", diagnostics.cacheEvictionCount)
                    .put("cacheRejectionCount", diagnostics.cacheRejectionCount)
                    .put("cacheThrashCount", diagnostics.cacheThrashCount)
                    .put("textureCreatedCount", diagnostics.textureCreatedCount)
                    .put("textureReleasedCount", diagnostics.textureReleasedCount)
                    .put("liveTextureCount", diagnostics.liveTextureCount)
                    .put("peakLiveTextureCount", diagnostics.peakLiveTextureCount)
                    .put("textureDoubleReleaseCount", diagnostics.textureDoubleReleaseCount)
                    .put("reverseWindowBuildCount", diagnostics.reverseWindowBuildCount)
                    .put("reverseWindowHitCount", diagnostics.reverseWindowHitCount)
                    .put("reverseWindowSeekCount", diagnostics.reverseWindowSeekCount)
                    .put("reverseWindowRefillCount", diagnostics.reverseWindowRefillCount)
                    .put("reverseWindowInitialReadyCount", diagnostics.reverseWindowInitialReadyCount)
                    .put(
                        "reverseWindowRollingAppendRefillCount",
                        diagnostics.reverseWindowRollingAppendRefillCount,
                    )
                    .put("reverseWindowRefillNeeded", diagnostics.reverseWindowRefillNeeded)
                    .put("reverseWindowRefillStallCount", diagnostics.reverseWindowRefillStallCount)
                    .put("reverseWindowRefillStallMaxUs", diagnostics.reverseWindowRefillStallMaxUs)
                    .put(
                        "reverseWindowRefillStallOver250MsCount",
                        diagnostics.reverseWindowRefillStallOver250MsCount,
                    )
                    .put("decodedOutputs", diagnostics.decodeOrdinal)
                    .put("staleDiscard", diagnostics.staleDiscardCount)
                    .put("publishedSwaps", diagnostics.publishedSwapCount)
                    .put("staleBeforeSwap", diagnostics.staleBeforeSwapCount)
                    .put("swapFailures", diagnostics.swapFailureCount)
                    .put("surfaceInvalid", diagnostics.surfaceInvalidCount)
                    .put("publicationInvariantViolations", diagnostics.publicationInvariantViolationCount)
                    .put("fullFrameReadbacks", diagnostics.fullFrameReadbackCount)
                    .put("outputFormatChanges", diagnostics.outputFormatChangeCount)
                    .put("configuredOutputMetadata", diagnostics.configuredOutputMetadata?.let(::decodedOutputJson))
                    .put("decodedOutputFormatHistory", JSONArray(diagnostics.decodedOutputFormatHistory.map(::decodedOutputJson)))
                    .put(
                        "publicationEventHistory",
                        JSONArray(diagnostics.publicationEventHistory.map(::publicationEventJson)),
                    )
                    .put("recreate", diagnostics.decoderRecreateCount))
                .put("memory", JSONObject()
                    .put("javaUsedBytes", Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory())
                    .put("javaMaxBytes", Runtime.getRuntime().maxMemory())
                    .put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
                    .put("pssKb", Debug.getPss()))
                .put("thermalStatus", power.currentThermalStatus)
                .put("batteryPercent", battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                .put("mismatchCount", mismatchCount)
                .put("writeOpenCount", writeOpenCount)
                .put("staleDiscardAssessmentVersion", 1)
                .put("staleDiscardEvents", JSONArray(staleDiscardEvents))
                .put("gateCounters", JSONObject()
                    .put("staleDiscard", staleDiscardCount)
                    .put("staleDiscardEventCount", staleDiscardEvents.size)
                    .put("expectedSupersededDiscardCount", expectedSupersededDiscardCount)
                    .put("unexpectedStaleViolationCount", unexpectedStaleViolationCount())
                    .put("staleBeforeSwap", staleBeforeSwapCount)
                    .put("swapFailures", swapFailureCount)
                    .put("surfaceInvalid", surfaceInvalidCount)
                    .put("publicationInvariantViolations", publicationInvariantViolationCount)
                    .put("cacheRejectionCount", cacheRejectionCount)
                    .put("cacheThrashCount", cacheThrashCount)
                    .put("textureDoubleReleaseCount", textureDoubleReleaseCount))
                .put("performanceGateApplied", false)
                .put("syntheticOnly", true)
                .put("containsRealMediaMetadata", false)
            ValidationHarnessV2.putReportIdentity(
                report = json,
                identity = identity,
                startedAtElapsedRealtimeNs = startedAtElapsedRealtimeNs,
                finishedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
                testCount = 1,
                instrumentationExpectedTestCount = 1,
            )
            if (failure != null) {
                json.put("failure", JSONObject()
                    .put("type", failure.javaClass.simpleName)
                    .put("message", failure.message ?: "unknown")
                    .put("fixture", currentFixture)
                    .put("frameIndex", currentFrameIndex)
                    .put("expectedFrameKey", expectedFrameKey?.let(::frameKeyJson) ?: JSONObject.NULL)
                    .put("actualFrameKey", actualFrameKey?.let(::frameKeyJson) ?: JSONObject.NULL)
                    .put("textureTimestampNs", textureTimestampNs ?: JSONObject.NULL)
                    .put("minimalReproduction", "run-s24-gate.ps1 with only the reported synthetic fixture")
                    .put("suspectedCause", "undetermined; inspect FrameKey, texture timestamp, embedded ID and signature in that order")
                    .put("nextMinimalChange", "isolate the failing fixture and change only the first disproved decode/render hypothesis"))
            }
            File(context.filesDir, fileName).writeText(json.toString(2))
        }

        private data class ExpectedSupersededDiscard(
            val phase: String,
            val fixture: String,
            val acceptance: RequestAcceptance,
            val supersedingRequestGeneration: Long?,
            val supersedingFileGeneration: Long?,
        )

        companion object {
            private val EXPECTED_SUPERSEDED_STAGES = setOf(
                "before-decode",
                "after-test-hook",
                "decode-loop",
                "input-batch",
                "output-batch",
                "TEXTURE_GENERATION_STALE",
            )
        }
    }

    companion object {
        const val REPORT_FILE = "s24-frame-accuracy-report.json"
        const val SEQUENTIAL_REPORT_FILE = "s24-forward-sequential-report.json"
        const val REVERSE_REPORT_FILE = "s24-reverse-window-report.json"
        const val DIRECTION_REPORT_FILE = "s24-alpha5-direction-reversal-report.json"
        private const val REQUIRED_CACHE_BUDGET_BYTES = 64L * 1024L * 1024L
        private const val DISCRETE_PREFETCH_PROBE_DEPTH = 2
        val REQUIRED_FIXTURES = listOf(
            "h264-ip", "h264-bframes", "vfr", "long-gop", "nonzero-pts", "one-frame", "two-frame",
            "short-last-gop", "rotation-90", "rotation-180", "rotation-270", "hevc-main8", "burst",
            "switch-a", "switch-b", "par-8-9", "duplicate-pts",
        )
        private val SEQUENTIAL_FIXTURES = listOf("h264-bframes", "long-gop", "vfr", "hevc-main8")
    }
}
