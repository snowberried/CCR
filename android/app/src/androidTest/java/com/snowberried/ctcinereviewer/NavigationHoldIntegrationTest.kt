package com.snowberried.ctcinereviewer

import android.net.Uri
import android.content.pm.ActivityInfo
import android.view.ViewConfiguration
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

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
    }
}
