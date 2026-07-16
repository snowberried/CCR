package com.snowberried.ctcinereviewer

import android.content.pm.ActivityInfo
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import org.junit.Rule
import org.junit.Test

class AdaptiveLayoutTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun phoneWindowUsesSinglePaneInPortraitAndTwoPaneWhenWidthExpands() {
        compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithTag("viewer-single-pane").fetchSemanticsNodes().isNotEmpty()
        }
        compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        compose.waitUntil(timeoutMillis = 20_000) {
            compose.onAllNodesWithTag("viewer-two-pane").fetchSemanticsNodes().isNotEmpty()
        }
    }
}
