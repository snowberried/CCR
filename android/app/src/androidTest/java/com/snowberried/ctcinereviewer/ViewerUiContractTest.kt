package com.snowberried.ctcinereviewer

import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ViewerUiContractTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun noFileHidesFrameTimelineAndCorrectionControls() {
        compose.onNodeWithTag("viewer-empty").fetchSemanticsNode()
        compose.onAllNodesWithTag("frame-controls").assertCountEquals(0)
        compose.onAllNodesWithTag("pts-timeline").assertCountEquals(0)
        compose.onAllNodesWithTag("correction-row").assertCountEquals(0)
        compose.onAllNodesWithTag("video-viewport").assertCountEquals(0)
    }

    @Test
    fun loadedFrameCardIsDisplayOnlyAndNormalUiHasNoDiagnosticOrDirectEntryText() {
        val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        compose.runOnUiThread {
            viewer.openVideo(Uri.parse("content://${context.packageName}.fixture/burst.mp4"))
        }
        compose.waitUntil(timeoutMillis = 20_000) {
            viewer.uiState.metadata?.frameCount == 48 && viewer.uiState.displayedFrameIndex == 0
        }

        val frameCard = compose.onNodeWithTag("frame-position-card")
        frameCard.fetchSemanticsNode()
        assertFalse(frameCard.fetchSemanticsNode().config.contains(SemanticsActions.OnClick))
        val root = compose.onNodeWithTag("window-root", useUnmergedTree = true).fetchSemanticsNode()
        assertFalse(root.anyDescendant { it.config.contains(SemanticsActions.SetText) })
        compose.onAllNodesWithTag("correction-status-dot").assertCountEquals(0)

        listOf(
            BuildConfig.VERSION_NAME,
            "Android",
            "alpha",
            "internal",
            "PTS",
            "cache",
            "decoder",
            "codec",
            "FPS",
        ).forEach { forbidden ->
            compose.onAllNodesWithText(forbidden, substring = true, ignoreCase = true)
                .assertCountEquals(0)
        }
        compose.onNodeWithTag("frame-controls").fetchSemanticsNode()
        compose.onNodeWithTag("pts-timeline").fetchSemanticsNode()
        compose.onNodeWithTag("correction-row").fetchSemanticsNode()
        assertTrue(compose.onAllNodesWithTag("viewer-empty").fetchSemanticsNodes().isEmpty())
    }

    private fun SemanticsNode.anyDescendant(predicate: (SemanticsNode) -> Boolean): Boolean =
        predicate(this) || children.any { it.anyDescendant(predicate) }
}
