package com.snowberried.ctcinereviewer

import android.net.Uri
import android.view.ViewConfiguration
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
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
    fun holdPlusOneAdvancesRequestedIndexAndSettlesOnRelease() {
        val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
        compose.waitUntil(timeoutMillis = 20_000) { viewer.uiState.surfaceAvailable }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.runOnUiThread {
            viewer.openVideo(Uri.parse("content://${context.packageName}.fixture/burst.mp4"))
        }
        compose.waitUntil(timeoutMillis = 20_000) {
            viewer.uiState.metadata?.frameCount == 48 &&
                viewer.uiState.displayedFrame?.displayFrameIndex == 0
        }

        val button = compose.onNodeWithText("+1")
        button.performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(
            ViewConfiguration.getLongPressTimeout().toLong() +
                NAVIGATION_REPEAT_INTERVAL_MS * 3 + 32,
        )
        val requestedBeforeRelease = viewer.uiState.requestedFrameIndex
        button.performTouchInput { up() }
        compose.waitForIdle()

        assertTrue("actual viewer did not advance: $requestedBeforeRelease", requestedBeforeRelease >= 3)
        assertEquals("release added a frame", requestedBeforeRelease, viewer.uiState.requestedFrameIndex)
        compose.mainClock.advanceTimeBy(NAVIGATION_REPEAT_INTERVAL_MS * 3)
        assertEquals("actual viewer continued after release", requestedBeforeRelease, viewer.uiState.requestedFrameIndex)
        compose.waitUntil(timeoutMillis = 20_000) {
            viewer.uiState.displayedFrame?.displayFrameIndex == requestedBeforeRelease
        }
        assertEquals(0L, viewer.uiState.diagnostics.publicationInvariantViolationCount)
    }
}
