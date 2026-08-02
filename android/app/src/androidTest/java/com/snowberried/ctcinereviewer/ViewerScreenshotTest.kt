package com.snowberried.ctcinereviewer

import android.net.Uri
import android.os.SystemClock
import android.view.WindowInsets
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import java.io.FileInputStream

class ViewerScreenshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    @Test
    fun captureCollapsedExpandedAndAdjustedCollapsedStates() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val viewer = ViewModelProvider(compose.activity)[ViewerViewModel::class.java]
        compose.runOnUiThread {
            viewer.openVideo(Uri.parse("content://${context.packageName}.fixture/burst.mp4"))
        }
        compose.waitUntil(timeoutMillis = 20_000) {
            viewer.uiState.metadata?.frameCount == 48 && viewer.uiState.displayedFrameIndex == 0
        }

        capture("01-correction-collapsed-default.png")

        compose.onNodeWithTag("correction-row").performTouchInput { click(center) }
        compose.waitUntil(timeoutMillis = 5_000) {
            compose.onAllNodesWithTag("correction-panel").fetchSemanticsNodes().isNotEmpty()
        }
        capture("02-correction-expanded.png")

        compose.onNodeWithTag("correction-level-slider").performSemanticsAction(
            SemanticsActions.SetProgress,
        ) { setProgress ->
            check(setProgress(0.75f))
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            compose.onAllNodesWithTag(
                "correction-status-dot",
                useUnmergedTree = true,
            ).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("correction-row").performTouchInput { click(center) }
        compose.waitUntil(timeoutMillis = 5_000) {
            compose.onAllNodesWithTag("correction-panel").fetchSemanticsNodes().isEmpty()
        }
        capture("03-correction-collapsed-adjusted.png")
    }

    private fun capture(fileName: String) {
        compose.waitForIdle()
        SystemClock.sleep(1_000)
        compose.runOnUiThread {
            val insets = requireNotNull(compose.activity.window.decorView.rootWindowInsets)
            check(insets.isVisible(WindowInsets.Type.statusBars()))
            check(insets.getInsets(WindowInsets.Type.statusBars()).top > 0)
            check(insets.isVisible(WindowInsets.Type.navigationBars()))
            check(insets.getInsets(WindowInsets.Type.navigationBars()).bottom > 0)
        }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = "/sdcard/Download/ccr-ui-redesign-screenshots"
        fun execute(command: String) {
            instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
                FileInputStream(descriptor.fileDescriptor).use { it.readBytes() }
            }
        }
        execute("mkdir -p $directory")
        execute("screencap -p $directory/$fileName")
    }
}
