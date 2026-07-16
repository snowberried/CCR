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

    private companion object {
        const val HOLD_SETTLE_MS = 150L
        const val RELEASE_CANCEL_GRACE_MS = 250L
        const val RELEASE_CANCEL_REPORT_FILE = "s24-release-cancel-grace-report.json"
    }
}
