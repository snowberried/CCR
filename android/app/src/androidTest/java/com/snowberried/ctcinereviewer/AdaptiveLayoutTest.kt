package com.snowberried.ctcinereviewer

import android.content.ComponentName
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class AdaptiveLayoutTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun manifestAndLayoutUsePortraitSinglePaneWithSafeDrawingBounds() {
        val activity = compose.activity
        val info = activity.packageManager.getActivityInfo(
            ComponentName(activity, MainActivity::class.java),
            PackageManager.ComponentInfoFlags.of(0),
        )
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, info.screenOrientation)

        compose.onNodeWithTag("safe-drawing-content").fetchSemanticsNode()
        compose.onAllNodesWithTag("viewer-two-pane").assertCountEquals(0)

        val window = compose.onNodeWithTag("window-root").fetchSemanticsNode().boundsInRoot
        val safe = compose.onNodeWithTag("safe-drawing-content").fetchSemanticsNode().boundsInRoot
        assertTrue("safe content starts above the window", safe.top >= window.top)
        assertTrue("safe content extends below the window", safe.bottom <= window.bottom)
        assertTrue("safeDrawing did not reserve the status bar", safe.top > window.top)
    }
}
