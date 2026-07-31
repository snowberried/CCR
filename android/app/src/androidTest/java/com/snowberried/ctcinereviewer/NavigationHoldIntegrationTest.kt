package com.snowberried.ctcinereviewer

import android.net.Uri
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.SystemClock
import android.view.ViewConfiguration
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.gate.ReadOnlyFixtureProvider
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.validation.ValidationHarnessV2
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

class NavigationHoldIntegrationTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun holdPlusOneRequestsAtMostOneTargetAheadAndSettlesOnRelease() {
        val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
        openBurst(viewer)

        val button = compose.onNodeWithText("+1")
        button.performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(
            ViewConfiguration.getLongPressTimeout().toLong() + 32,
        )
        val requestedBeforeRelease = viewer.uiState.requestedFrameIndex
        button.performTouchInput { up() }
        compose.waitForIdle()
        val requestedAfterRelease = viewer.uiState.requestedFrameIndex

        assertTrue("actual viewer did not advance: $requestedBeforeRelease", requestedBeforeRelease >= 1)
        assertTrue(
            "hold queued more than one target",
            requestedBeforeRelease - (viewer.uiState.displayedFrameIndex ?: 0) <= 1,
        )
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)
        assertEquals("actual viewer continued after release was handled", requestedAfterRelease, viewer.uiState.requestedFrameIndex)
        compose.waitUntil(timeoutMillis = 20_000) {
            viewer.uiState.displayedFrame?.displayFrameIndex == requestedAfterRelease
        }
        assertEquals(0L, viewer.uiState.diagnostics.publicationInvariantViolationCount)
    }

    @Test
    fun orientationChangeDuringHoldStopsWithoutRequestedIndexOvershoot() {
        val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
        openBurst(viewer)
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(2)
        compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithTag("viewer-two-pane").fetchSemanticsNodes().isNotEmpty()
        }
        val afterOrientationStop = viewer.uiState.requestedFrameIndex
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)

        assertEquals(
            "orientation disposal allowed a stale repeat",
            afterOrientationStop,
            viewer.uiState.requestedFrameIndex,
        )
    }

    @Test
    fun backgroundDuringHoldInvalidatesViewModelGeneration() {
        val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
        openBurst(viewer)
        val button = compose.onNodeWithText("+1")

        button.performTouchInput { down(center) }
        advancePastLongPress(2)
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        val afterStop = viewer.uiState.requestedFrameIndex
        compose.mainClock.advanceTimeBy(HOLD_SETTLE_MS)

        assertEquals("background allowed a stale repeat", afterStop, viewer.uiState.requestedFrameIndex)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
    }

    @Test
    fun releaseThenCancelAcceptsNoNewForegroundRequestDuringGracePeriods() {
        assumeTrue(
            "release/cancel Gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val identity = ValidationHarnessV2.requireIdentity(context, instrumentation.context)
        val startedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos()
        var requestedAtRelease = -1
        var requestedAfterReleaseGrace = -1
        var requestedAtCancel = -1
        var requestedAfterCancelGrace = -1
        var acceptedAfterRelease = -1
        var acceptedAfterCancel = -1
        var requestGenerationAtRelease: Long? = null
        var requestGenerationAfterReleaseGrace: Long? = null
        var codecComponent: String? = null
        ReadOnlyFixtureProvider.writeOpenCount.set(0)

        val outcome = runCatching {
            val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
            openBurst(viewer)
            codecComponent = viewer.uiState.metadata?.codecComponent
            assertTrue("hardware decoder required", viewer.uiState.metadata?.hardwareAccelerated == true)

            val button = compose.onNodeWithText("+1")
            button.performTouchInput { down(center) }
            advancePastLongPress(2)
            assertTrue("hold did not accept a foreground target", viewer.uiState.requestedFrameIndex > 0)
            button.performTouchInput { up() }
            compose.waitForIdle()
            requestedAtRelease = viewer.uiState.requestedFrameIndex
            compose.waitUntil(timeoutMillis = 20_000) {
                viewer.uiState.displayedFrameIndex == requestedAtRelease
            }
            assertTrue("actor did not settle after release", viewer.awaitActorIdleForTest(20_000))
            requestGenerationAtRelease = viewer.uiState.activeRequestGeneration

            Thread.sleep(RELEASE_CANCEL_GRACE_MS)
            compose.waitForIdle()
            requestedAfterReleaseGrace = viewer.uiState.requestedFrameIndex
            requestGenerationAfterReleaseGrace = viewer.uiState.activeRequestGeneration
            acceptedAfterRelease = if (
                requestedAfterReleaseGrace != requestedAtRelease ||
                requestGenerationAfterReleaseGrace != requestGenerationAtRelease
            ) 1 else 0
            assertEquals("requestedFrameIndex changed after release", requestedAtRelease, requestedAfterReleaseGrace)
            assertEquals("release accepted a new foreground request", 0, acceptedAfterRelease)

            compose.runOnUiThread(viewer::cancel)
            compose.waitForIdle()
            requestedAtCancel = viewer.uiState.requestedFrameIndex
            assertNull("cancel retained an accepted request generation", viewer.uiState.activeRequestGeneration)
            assertNull("cancel retained a decode target", viewer.uiState.currentDecodeTarget)
            assertNull("cancel retained a pending target", viewer.uiState.latestPendingRequest)
            assertTrue("actor did not settle after cancel", viewer.awaitActorIdleForTest(20_000))

            Thread.sleep(RELEASE_CANCEL_GRACE_MS)
            compose.waitForIdle()
            requestedAfterCancelGrace = viewer.uiState.requestedFrameIndex
            acceptedAfterCancel = if (
                requestedAfterCancelGrace != requestedAtCancel ||
                viewer.uiState.activeRequestGeneration != null ||
                viewer.uiState.currentDecodeTarget != null ||
                viewer.uiState.latestPendingRequest != null
            ) 1 else 0
            assertEquals("requestedFrameIndex changed after cancel", requestedAtCancel, requestedAfterCancelGrace)
            assertEquals("cancel accepted a new foreground request", 0, acceptedAfterCancel)
            assertEquals("source opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
        }

        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val report = JSONObject()
            .put("schemaVersion", 2)
            .put("kind", "release-cancel-grace")
            .put("status", if (outcome.isSuccess) "PASS" else "FAIL")
            .put("gate", "Samsung SM-S928* S24 Ultra")
            .put(
                "device",
                JSONObject()
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("fingerprint", Build.FINGERPRINT)
                    .put("securityPatch", Build.VERSION.SECURITY_PATCH)
                    .put("sdk", Build.VERSION.SDK_INT),
            )
            .put("appVersionName", packageInfo.versionName)
            .put("appVersionCode", packageInfo.longVersionCode)
            .put("appCommitSha", BuildConfig.COMMIT_SHA)
            .put("codecComponent", codecComponent ?: JSONObject.NULL)
            .put("hardwareDecoderRequired", true)
            .put("gracePeriodMs", RELEASE_CANCEL_GRACE_MS)
            .put("requestedFrameIndexAtRelease", requestedAtRelease)
            .put("requestedFrameIndexAfterReleaseGrace", requestedAfterReleaseGrace)
            .put("requestedFrameIndexChangeAfterRelease", requestedAfterReleaseGrace - requestedAtRelease)
            .put("requestGenerationAtRelease", requestGenerationAtRelease ?: JSONObject.NULL)
            .put("requestGenerationAfterReleaseGrace", requestGenerationAfterReleaseGrace ?: JSONObject.NULL)
            .put("acceptedForegroundRequestCountAfterRelease", acceptedAfterRelease)
            .put("requestedFrameIndexAtCancel", requestedAtCancel)
            .put("requestedFrameIndexAfterCancelGrace", requestedAfterCancelGrace)
            .put("requestedFrameIndexChangeAfterCancel", requestedAfterCancelGrace - requestedAtCancel)
            .put("acceptedForegroundRequestCountAfterCancel", acceptedAfterCancel)
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
            .put("syntheticOnly", true)
            .put("containsRealMediaMetadata", false)
        ValidationHarnessV2.putReportIdentity(
            report = report,
            identity = identity,
            startedAtElapsedRealtimeNs = startedAtElapsedRealtimeNs,
            finishedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            testCount = 1,
            instrumentationExpectedTestCount = 1,
        )
        outcome.exceptionOrNull()?.let { failure ->
            report.put(
                "failure",
                JSONObject()
                    .put("type", failure.javaClass.simpleName)
                    .put("message", failure.message ?: "unknown"),
            )
        }
        File(context.filesDir, RELEASE_CANCEL_REPORT_FILE).writeText(report.toString(2))
        outcome.getOrThrow()
    }

    @Test
    fun reverseHoldLifecycleInvalidationRestoresExactFrameOnS24Ultra() {
        assumeTrue(
            "reverse lifecycle Gate requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", true) && Build.MODEL.startsWith("SM-S928"),
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val identity = ValidationHarnessV2.requireIdentity(context, instrumentation.context)
        val startedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos()
        var codecComponent: String? = null
        var forwardAnchor = -1
        var requestedBeforeCreated = -1
        var requestedInCreated = -1
        var requestedAfterCreatedGrace = -1
        var generationBeforeCreated: Long? = null
        var generationInCreated: Long? = null
        var generationAfterResume: Long? = null
        var decodedInCreated = -1L
        var decodedAfterCreatedGrace = -1L
        var publicationsInCreated = -1L
        var publicationsAfterCreatedGrace = -1L
        var publicationEventsInCreated = -1
        var publicationEventsAfterCreatedGrace = -1
        var expectedFrame: FrameKey? = null
        var restoredFrame: FrameKey? = null
        ReadOnlyFixtureProvider.writeOpenCount.set(0)

        val outcome = runCatching {
            val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
            openBurst(viewer)
            codecComponent = viewer.uiState.metadata?.codecComponent
            assertTrue("hardware decoder required", viewer.uiState.metadata?.hardwareAccelerated == true)

            val forward = compose.onNodeWithText("+5")
            repeat(4) {
                forward.performTouchInput {
                    down(center)
                    up()
                }
                compose.waitForIdle()
                val requested = viewer.uiState.requestedFrameIndex
                compose.waitUntil(timeoutMillis = 20_000) {
                    viewer.uiState.displayedFrameIndex == requested
                }
            }
            forwardAnchor = viewer.uiState.displayedFrameIndex ?: -1
            assertTrue("forward setup did not reach frame 20", forwardAnchor >= 20)

            val reverse = compose.onNodeWithText("−1")
            reverse.performTouchInput { down(center) }
            advancePastLongPress(2)
            compose.waitUntil(timeoutMillis = 20_000) {
                viewer.uiState.requestedFrameIndex < forwardAnchor &&
                    viewer.uiState.activeRequestGeneration != null
            }
            requestedBeforeCreated = viewer.uiState.requestedFrameIndex
            generationBeforeCreated = viewer.uiState.activeRequestGeneration

            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            assertTrue("actor did not settle in CREATED", viewer.awaitActorIdleForTest(20_000))
            val createdState = viewer.uiState
            requestedInCreated = createdState.requestedFrameIndex
            generationInCreated = createdState.activeRequestGeneration
            val ptsUs = createdState.framePtsUs[requestedInCreated]
            expectedFrame = FrameKey(
                displayFrameIndex = requestedInCreated,
                ptsUs = ptsUs,
                duplicateOrdinal = createdState.framePtsUs.take(requestedInCreated).count { it == ptsUs },
            )
            val createdDiagnostics = requireNotNull(viewer.diagnosticsSnapshotForTest(20_000))
            decodedInCreated = createdDiagnostics.decodeOrdinal
            publicationsInCreated = createdDiagnostics.publishedSwapCount
            publicationEventsInCreated = createdDiagnostics.publicationEventHistory.size

            SystemClock.sleep(HOLD_SETTLE_MS)
            assertTrue("actor did not remain idle in CREATED", viewer.awaitActorIdleForTest(20_000))
            val afterGraceState = viewer.uiState
            val afterGraceDiagnostics = requireNotNull(viewer.diagnosticsSnapshotForTest(20_000))
            requestedAfterCreatedGrace = afterGraceState.requestedFrameIndex
            decodedAfterCreatedGrace = afterGraceDiagnostics.decodeOrdinal
            publicationsAfterCreatedGrace = afterGraceDiagnostics.publishedSwapCount
            publicationEventsAfterCreatedGrace = afterGraceDiagnostics.publicationEventHistory.size

            assertNull("CREATED retained the reverse request generation", generationInCreated)
            assertNull("CREATED retained a decode target", afterGraceState.currentDecodeTarget)
            assertNull("CREATED retained a pending target", afterGraceState.latestPendingRequest)
            assertEquals("CREATED allowed a stale reverse repeat", requestedInCreated, requestedAfterCreatedGrace)
            assertEquals("CREATED accepted more decode work", decodedInCreated, decodedAfterCreatedGrace)
            assertEquals("CREATED published another frame", publicationsInCreated, publicationsAfterCreatedGrace)
            assertEquals(
                "CREATED recorded another publication event",
                publicationEventsInCreated,
                publicationEventsAfterCreatedGrace,
            )

            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.waitUntil(timeoutMillis = 30_000) {
                viewer.uiState.surfaceAvailable &&
                    viewer.uiState.requestedFrameIndex == requestedInCreated &&
                    viewer.uiState.displayedFrame == expectedFrame &&
                    viewer.uiState.restoreState == ViewerRestoreState.COMPLETE
            }
            assertTrue("actor did not settle after RESUMED", viewer.awaitActorIdleForTest(20_000))
            val restoredState = viewer.uiState
            val finalDiagnostics = requireNotNull(viewer.diagnosticsSnapshotForTest(20_000))
            restoredFrame = restoredState.displayedFrame
            generationAfterResume = restoredState.activeRequestGeneration

            assertTrue("reverse hold did not move before CREATED", requestedBeforeCreated < forwardAnchor)
            assertTrue("reverse generation was not active before CREATED", generationBeforeCreated != null)
            assertTrue(
                "RESUMED reused the invalidated request generation",
                generationAfterResume != null && generationAfterResume != generationBeforeCreated,
            )
            assertEquals("requested/displayed diverged after restore", requestedInCreated, restoredState.displayedFrameIndex)
            assertEquals("RESUMED did not restore the exact FrameKey", expectedFrame, restoredFrame)
            assertEquals("stale decode result", 0L, finalDiagnostics.staleDiscardCount)
            assertEquals("stale before swap", 0L, finalDiagnostics.staleBeforeSwapCount)
            assertEquals("swap failure", 0L, finalDiagnostics.swapFailureCount)
            assertEquals("surface invalid publication", 0L, finalDiagnostics.surfaceInvalidCount)
            assertEquals(
                "publication invariant violation",
                0L,
                finalDiagnostics.publicationInvariantViolationCount,
            )
            assertTrue("cache peak exceeded cap", finalDiagnostics.peakCacheBytes <= finalDiagnostics.cacheBudgetBytes)
            assertEquals("texture double release", 0L, finalDiagnostics.textureDoubleReleaseCount)
            assertEquals("source opened for write", 0, ReadOnlyFixtureProvider.writeOpenCount.get())
        }

        val finalDiagnostics = runCatching {
            ViewModelProvider(compose.activity)[ViewerViewModel::class.java].diagnosticsSnapshotForTest(20_000)
        }.getOrNull()
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val report = JSONObject()
            .put("schemaVersion", 2)
            .put("kind", "alpha5-reverse-lifecycle-exact")
            .put("status", if (outcome.isSuccess) "PASS" else "FAIL")
            .put("gate", "Samsung SM-S928* S24 Ultra")
            .put(
                "device",
                JSONObject()
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("fingerprint", Build.FINGERPRINT)
                    .put("securityPatch", Build.VERSION.SECURITY_PATCH)
                    .put("sdk", Build.VERSION.SDK_INT),
            )
            .put("appVersionName", packageInfo.versionName)
            .put("appVersionCode", packageInfo.longVersionCode)
            .put("appCommitSha", BuildConfig.COMMIT_SHA)
            .put("codecComponent", codecComponent ?: JSONObject.NULL)
            .put("hardwareDecoderRequired", true)
            .put("fixture", "burst")
            .put("forwardAnchor", forwardAnchor)
            .put("requestedBeforeCreated", requestedBeforeCreated)
            .put("requestedInCreated", requestedInCreated)
            .put("requestedAfterCreatedGrace", requestedAfterCreatedGrace)
            .put("generationBeforeCreated", generationBeforeCreated ?: JSONObject.NULL)
            .put("generationInCreated", generationInCreated ?: JSONObject.NULL)
            .put("generationAfterResume", generationAfterResume ?: JSONObject.NULL)
            .put("decodedInCreated", decodedInCreated)
            .put("decodedAfterCreatedGrace", decodedAfterCreatedGrace)
            .put("publicationsInCreated", publicationsInCreated)
            .put("publicationsAfterCreatedGrace", publicationsAfterCreatedGrace)
            .put("publicationEventsInCreated", publicationEventsInCreated)
            .put("publicationEventsAfterCreatedGrace", publicationEventsAfterCreatedGrace)
            .put("expectedFrame", expectedFrame?.let(::frameKeyJson) ?: JSONObject.NULL)
            .put("restoredFrame", restoredFrame?.let(::frameKeyJson) ?: JSONObject.NULL)
            .put(
                "diagnostics",
                finalDiagnostics?.let { diagnostics ->
                    JSONObject()
                        .put("staleDiscardCount", diagnostics.staleDiscardCount)
                        .put("staleBeforeSwapCount", diagnostics.staleBeforeSwapCount)
                        .put("swapFailureCount", diagnostics.swapFailureCount)
                        .put("surfaceInvalidCount", diagnostics.surfaceInvalidCount)
                        .put("publicationInvariantViolationCount", diagnostics.publicationInvariantViolationCount)
                        .put("publishedSwapCount", diagnostics.publishedSwapCount)
                        .put("cacheBudgetBytes", diagnostics.cacheBudgetBytes)
                        .put("peakCacheBytes", diagnostics.peakCacheBytes)
                        .put("textureDoubleReleaseCount", diagnostics.textureDoubleReleaseCount)
                } ?: JSONObject.NULL,
            )
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
            .put("syntheticOnly", true)
            .put("containsRealMediaMetadata", false)
        ValidationHarnessV2.putReportIdentity(
            report = report,
            identity = identity,
            startedAtElapsedRealtimeNs = startedAtElapsedRealtimeNs,
            finishedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            testCount = 1,
            instrumentationExpectedTestCount = 1,
        )
        outcome.exceptionOrNull()?.let { failure ->
            report.put(
                "failure",
                JSONObject()
                    .put("type", failure.javaClass.simpleName)
                    .put("message", failure.message ?: "unknown"),
            )
        }
        File(context.filesDir, REVERSE_LIFECYCLE_REPORT_FILE).writeText(report.toString(2))
        outcome.getOrThrow()
    }

    private fun openBurst(viewer: ViewerViewModel) {
        compose.waitUntil(timeoutMillis = 20_000) { viewer.uiState.surfaceAvailable }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.runOnUiThread {
            viewer.openVideo(Uri.parse("content://${context.packageName}.fixture/burst.mp4"))
        }
        compose.waitUntil(timeoutMillis = 20_000) {
            viewer.uiState.metadata?.frameCount == 48 &&
                viewer.uiState.displayedFrame?.displayFrameIndex == 0
        }
    }

    private fun advancePastLongPress(repeatIntervals: Int) {
        compose.mainClock.advanceTimeBy(
            ViewConfiguration.getLongPressTimeout().toLong() + repeatIntervals.coerceAtLeast(1) * 32L,
        )
    }

    private fun frameKeyJson(value: FrameKey): JSONObject = JSONObject()
        .put("displayFrameIndex", value.displayFrameIndex)
        .put("ptsUs", value.ptsUs)
        .put("duplicateOrdinal", value.duplicateOrdinal)

    private companion object {
        const val HOLD_SETTLE_MS = 150L
        const val RELEASE_CANCEL_GRACE_MS = 250L
        const val RELEASE_CANCEL_REPORT_FILE = "s24-release-cancel-grace-report.json"
        const val REVERSE_LIFECYCLE_REPORT_FILE = "s24-alpha5-reverse-lifecycle-report.json"
    }
}
