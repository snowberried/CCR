package com.snowberried.ctcinereviewer

import android.app.Application
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.MediaFormat
import android.net.Uri
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.gate.ReadOnlyFixtureProvider
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameRequest
import com.snowberried.ctcinereviewer.media.RENDERER_CACHE_HARD_CAP_BYTES
import com.snowberried.ctcinereviewer.media.rendererCacheByteBudget
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class ViewerLifecycleTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test
    fun backgroundSuspendsInFlightPrefetchAndResumeWaitsForDirectionalInput() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            waitState(scenario) { it.surfaceAvailable }
            open(scenario, "burst.mp4")
            waitState(scenario) { it.displayedFrameIndex == 0 }
            val viewer = viewer(scenario)
            assertTrue("initial actor did not become idle", viewer.awaitActorIdleForTest())
            val initialDiagnostics = requireNotNull(viewer.diagnosticsSnapshotForTest())
            assertEquals(0L, initialDiagnostics.prefetchStarted)
            assertEquals(0L, initialDiagnostics.prefetchCompleted)
            assertEquals(
                rendererCacheByteBudget(Runtime.getRuntime().maxMemory()),
                initialDiagnostics.cacheBudgetBytes,
            )
            assertTrue(initialDiagnostics.cacheBudgetBytes <= RENDERER_CACHE_HARD_CAP_BYTES)

            val barrier = OneShotPrefetchBarrier()
            viewer.setBeforePrefetchCacheHookForTest(barrier::block)
            onViewer(scenario) { it.moveBy(1) }
            waitState(scenario) { it.displayedFrameIndex == 1 }
            assertTrue("prefetch did not reach cache boundary", barrier.awaitEntered())
            val completedBeforeStop = state(scenario).diagnostics.prefetchCompleted

            scenario.moveToState(Lifecycle.State.CREATED)
            waitState(scenario) { !it.surfaceAvailable && it.displayedFrame == null }
            barrier.release()
            assertTrue("prefetch actor did not drain after stop", viewer.awaitActorIdleForTest(20_000))
            viewer.setBeforePrefetchCacheHookForTest(null)
            val stoppedDiagnostics = requireNotNull(viewer.diagnosticsSnapshotForTest())
            assertEquals("prefetch completed after lifecycle stop", completedBeforeStop, stoppedDiagnostics.prefetchCompleted)

            scenario.moveToState(Lifecycle.State.RESUMED)
            val restored = waitState(scenario, 30_000) {
                it.surfaceAvailable && it.displayedFrameIndex == 1 && it.restoreState == ViewerRestoreState.COMPLETE
            }
            assertTrue("restore actor did not become idle", viewer.awaitActorIdleForTest())
            assertEquals("resume started speculative prefetch", stoppedDiagnostics.prefetchStarted, restored.diagnostics.prefetchStarted)
            assertEquals("resume completed speculative prefetch", stoppedDiagnostics.prefetchCompleted, restored.diagnostics.prefetchCompleted)
            assertEquals(0L, restored.diagnostics.swapFailureCount)
            assertEquals(0L, restored.diagnostics.publicationInvariantViolationCount)

            val startedBeforeDirection = restored.diagnostics.prefetchStarted
            onViewer(scenario) { it.moveBy(1) }
            waitState(scenario) { it.displayedFrameIndex == 2 }
            assertTrue("directional prefetch actor did not become idle", viewer.awaitActorIdleForTest())
            onViewer(scenario) { it.requestFrame(5) }
            val cached = waitState(scenario) { it.displayedFrameIndex == 5 }
            assertEquals("cache hit", cached.detail)
            assertTrue(cached.diagnostics.prefetchStarted > startedBeforeDirection)
            assertTrue(cached.diagnostics.prefetchCompleted > completedBeforeStop)
        }
    }

    @Test
    fun coalescedDirectionalReversalCountsOnlyPendingOverwritesAndPublishesLatestTarget() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            waitState(scenario) { it.surfaceAvailable }
            open(scenario, "burst.mp4")
            waitState(scenario) { it.displayedFrameIndex == 0 }

            val viewer = viewer(scenario)
            val barrier = OneShotDecodeBarrier()
            viewer.setBeforeDecodeHookForTest(barrier::block)
            try {
                onViewer(scenario) { it.moveBy(5) }
                assertTrue("directional decode did not enter actor", barrier.awaitEntered())
                onViewer(scenario) {
                    it.moveBy(5)
                    it.moveBy(5)
                    it.moveBy(-5)
                    assertEquals(10, it.uiState.requestedFrameIndex)
                }
            } finally {
                barrier.release()
            }

            val final = waitState(scenario, 30_000) { it.displayedFrameIndex == 10 }
            viewer.setBeforeDecodeHookForTest(null)
            assertEquals(2L, final.diagnostics.requestCoalescedCount)
            assertEquals(3L, final.diagnostics.foregroundDecodedFrameCount)
        }
    }

    @Test
    fun rapidNavigationAccumulatesAndFileSwitchDuringDecodeRejectsOldResults() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            waitState(scenario) { it.surfaceAvailable }
            open(scenario, "burst.mp4")
            waitState(scenario) { it.displayedFrame?.displayFrameIndex == 0 }

            onViewer(scenario) { viewer ->
                repeat(3) { viewer.moveBy(1) }
                viewer.moveBy(5)
                assertEquals(8, viewer.uiState.requestedFrameIndex)
                assertEquals(0, viewer.uiState.displayedFrame?.displayFrameIndex)
            }
            waitState(scenario) { it.displayedFrame?.displayFrameIndex == 8 }

            val firstGeneration = state(scenario).activeFileGeneration
            val viewer = viewer(scenario)
            val barrier = OneShotDecodeBarrier()
            viewer.setBeforeDecodeHookForTest(barrier::block)
            try {
                onViewer(scenario) { current ->
                    current.requestFrame(requireNotNull(current.uiState.metadata).frameCount - 1)
                }
                assertTrue("file A decode did not enter actor", barrier.awaitEntered())
                onViewer(scenario) { it.openVideo(uri("switch-b.mp4")) }
            } finally {
                barrier.release()
            }
            assertTrue("media actor did not drain after A→B", viewer.awaitActorIdleForTest(20_000))
            viewer.setBeforeDecodeHookForTest(null)

            val switched = waitState(scenario) { state ->
                state.activeFileGeneration != null &&
                    state.activeFileGeneration != firstGeneration &&
                    state.displayedFrame?.displayFrameIndex == 0
            }
            assertNotEquals(firstGeneration, switched.activeFileGeneration)
            assertEquals(switched.activeFileGeneration, state(scenario).activeFileGeneration)
            assertEquals(0, state(scenario).displayedFrame?.displayFrameIndex)
            assertEquals(0L, state(scenario).diagnostics.publicationInvariantViolationCount)
        }
    }

    @Test
    fun h264ToHevcSwitchWhileSurfaceDetachedPublishesFrameZero() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            waitState(scenario) { it.surfaceAvailable }
            open(scenario, "switch-a.mp4")
            val first = waitState(scenario) {
                it.metadata?.mime == MediaFormat.MIMETYPE_VIDEO_AVC &&
                    it.displayedFrame?.displayFrameIndex == 0
            }
            val firstGeneration = requireNotNull(first.activeFileGeneration)
            val viewer = viewer(scenario)

            scenario.moveToState(Lifecycle.State.CREATED)
            waitState(scenario) { !it.surfaceAvailable && it.displayedFrame == null }
            instrumentation.runOnMainSync {
                viewer.openVideo(uri("hevc-main8.mp4"))
            }
            assertEquals(ViewerRestoreState.WAITING_FOR_SURFACE, viewer.uiState.restoreState)

            scenario.moveToState(Lifecycle.State.RESUMED)
            val second = waitState(scenario, 30_000) {
                it.metadata?.mime == MediaFormat.MIMETYPE_VIDEO_HEVC &&
                    it.displayedFrame?.displayFrameIndex == 0 &&
                    it.restoreState == ViewerRestoreState.COMPLETE
            }

            assertNotEquals(firstGeneration, second.activeFileGeneration)
            assertEquals("ready", second.status)
            assertEquals(0L, second.diagnostics.swapFailureCount)
            assertEquals(0L, second.diagnostics.surfaceInvalidCount)
            assertEquals(0L, second.diagnostics.publicationInvariantViolationCount)
        }
    }

    @Test
    fun decodeDuringRotationAndRepeatedBackgroundRestorePublishRequestedFrame() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            waitState(scenario) { it.surfaceAvailable }
            var activity = ensureOrientation(scenario, Configuration.ORIENTATION_PORTRAIT)
            open(scenario, "burst.mp4")
            waitState(scenario) { it.displayedFrame?.displayFrameIndex == 0 }

            val viewer = activity.viewer
            val beforeLandscapeSwap = state(scenario).diagnostics.publishedSwapCount
            val barrier = OneShotDecodeBarrier()
            viewer.setBeforeDecodeHookForTest(barrier::block)
            try {
                onViewer(scenario) { it.requestFrame(12) }
                assertTrue("decode did not enter before rotation", barrier.awaitEntered())
                activity = rotateAndWait(
                    scenario,
                    ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
                    Configuration.ORIENTATION_LANDSCAPE,
                    activity,
                )
                assertSame(viewer, activity.viewer)
            } finally {
                barrier.release()
            }
            val landscape = waitState(scenario, 30_000) {
                it.surfaceAvailable &&
                    it.requestedFrameIndex == 12 &&
                    it.displayedFrame?.displayFrameIndex == 12 &&
                    it.restoreState == ViewerRestoreState.COMPLETE &&
                    it.diagnostics.publishedSwapCount > beforeLandscapeSwap
            }
            viewer.setBeforeDecodeHookForTest(null)
            assertEquals(0L, landscape.diagnostics.publicationInvariantViolationCount)

            val beforePortraitSwap = landscape.diagnostics.publishedSwapCount
            activity = rotateAndWait(
                scenario,
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
                Configuration.ORIENTATION_PORTRAIT,
                activity,
            )
            assertSame(viewer, activity.viewer)
            waitState(scenario, 30_000) {
                it.surfaceAvailable &&
                    it.requestedFrameIndex == 12 &&
                    it.displayedFrame?.displayFrameIndex == 12 &&
                    it.diagnostics.publishedSwapCount > beforePortraitSwap
            }

            repeat(3) {
                val beforeBackgroundSwap = state(scenario).diagnostics.publishedSwapCount
                scenario.moveToState(Lifecycle.State.CREATED)
                waitState(scenario) {
                    !it.surfaceAvailable &&
                        it.displayedFrame == null &&
                        it.restoreState == ViewerRestoreState.WAITING_FOR_SURFACE
                }
                scenario.moveToState(Lifecycle.State.RESUMED)
                waitState(scenario, 30_000) {
                    it.surfaceAvailable &&
                        it.requestedFrameIndex == 12 &&
                        it.displayedFrame?.displayFrameIndex == 12 &&
                        it.diagnostics.publishedSwapCount > beforeBackgroundSwap
                }
            }
            assertEquals(0L, state(scenario).diagnostics.publicationInvariantViolationCount)
        }
    }

    @Test
    fun restoreDuringDecodeCanBeCancelledAndMissingPermissionRequiresReselection() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            waitState(scenario) { it.surfaceAvailable }
            open(scenario, "one-frame.mp4")
            waitState(scenario) { it.displayedFrame?.displayFrameIndex == 0 }
            scenario.moveToState(Lifecycle.State.CREATED)
            waitState(scenario) { !it.surfaceAvailable && it.displayedFrame == null }

            val viewer = viewer(scenario)
            val beforeRestoreSwap = viewer.uiState.diagnostics.publishedSwapCount
            val barrier = OneShotDecodeBarrier()
            viewer.setBeforeDecodeHookForTest(barrier::block)
            scenario.moveToState(Lifecycle.State.RESUMED)
            assertTrue("restore decode did not enter actor", barrier.awaitEntered())
            try {
                onViewer(scenario, ViewerViewModel::cancel)
            } finally {
                barrier.release()
            }
            assertTrue("media actor did not drain after cancel", viewer.awaitActorIdleForTest(20_000))
            viewer.setBeforeDecodeHookForTest(null)
            instrumentation.waitForIdleSync()
            assertCancelledWithoutSwap(scenario, beforeRestoreSwap)

            scenario.moveToState(Lifecycle.State.CREATED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            waitState(scenario) { it.surfaceAvailable }
            assertTrue("media actor did not remain idle after cancel", viewer.awaitActorIdleForTest())
            instrumentation.waitForIdleSync()
            assertCancelledWithoutSwap(scenario, beforeRestoreSwap)
        }

        ReadOnlyFixtureProvider.readOpenCount.set(0)
        val store = ViewModelStore()
        val owner = object : ViewModelStoreOwner {
            override val viewModelStore: ViewModelStore = store
        }
        val savedState = SavedStateHandle(
            mapOf(
                "viewer.uri" to uri("one-frame.mp4").toString(),
                "viewer.requested-frame" to 0,
            ),
        )
        val factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T =
                ViewerViewModel(context.applicationContext as Application, savedState) as T
        }
        val viewer = ViewModelProvider(owner, factory)[ViewerViewModel::class.java]
        try {
            instrumentation.runOnMainSync {
                viewer.onForeground()
                viewer.onSurfaceAvailabilityChanged(true)
            }
            assertEquals(ViewerRestoreState.PERMISSION_REQUIRED, viewer.uiState.restoreState)
            assertEquals("URI_PERMISSION_LOST", viewer.uiState.detail)
            assertNull(viewer.uiState.activeFileGeneration)
            assertNull(savedState.get<String>("viewer.uri"))
            assertEquals(0, ReadOnlyFixtureProvider.readOpenCount.get())
        } finally {
            instrumentation.runOnMainSync(store::clear)
        }
    }

    private fun assertCancelledWithoutSwap(
        scenario: ActivityScenario<MainActivity>,
        publishedSwapCount: Long,
    ) {
        val current = state(scenario)
        assertEquals(ViewerRestoreState.CANCELLED, current.restoreState)
        assertNull(current.displayedFrame)
        assertEquals(publishedSwapCount, current.diagnostics.publishedSwapCount)
    }

    private fun ensureOrientation(
        scenario: ActivityScenario<MainActivity>,
        targetOrientation: Int,
    ): ActivitySnapshot {
        val current = activity(scenario)
        if (current.orientation == targetOrientation) return current
        val requested = if (targetOrientation == Configuration.ORIENTATION_LANDSCAPE) {
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        return rotateAndWait(scenario, requested, targetOrientation, current)
    }

    private fun rotateAndWait(
        scenario: ActivityScenario<MainActivity>,
        requestedOrientation: Int,
        targetOrientation: Int,
        previous: ActivitySnapshot,
    ): ActivitySnapshot {
        scenario.onActivity { it.requestedOrientation = requestedOrientation }
        val rotated = waitActivity(scenario, 20_000) {
            it.orientation == targetOrientation && it.activity !== previous.activity
        }
        assertNotSame(previous.activity, rotated.activity)
        return rotated
    }

    private fun open(scenario: ActivityScenario<MainActivity>, fixture: String) {
        onViewer(scenario) { it.openVideo(uri(fixture)) }
    }

    private fun uri(fixture: String): Uri =
        Uri.parse("content://${context.packageName}.fixture/$fixture")

    private fun viewer(scenario: ActivityScenario<MainActivity>): ViewerViewModel = activity(scenario).viewer

    private fun onViewer(
        scenario: ActivityScenario<MainActivity>,
        action: (ViewerViewModel) -> Unit,
    ) {
        scenario.onActivity { activity ->
            action(ViewModelProvider(activity)[ViewerViewModel::class.java])
        }
    }

    private fun state(scenario: ActivityScenario<MainActivity>): ViewerUiState = viewer(scenario).uiState

    private fun activity(scenario: ActivityScenario<MainActivity>): ActivitySnapshot {
        val value = AtomicReference<ActivitySnapshot>()
        scenario.onActivity { activity ->
            value.set(
                ActivitySnapshot(
                    activity,
                    ViewModelProvider(activity)[ViewerViewModel::class.java],
                    activity.resources.configuration.orientation,
                ),
            )
        }
        return requireNotNull(value.get())
    }

    private fun waitActivity(
        scenario: ActivityScenario<MainActivity>,
        timeoutMs: Long,
        predicate: (ActivitySnapshot) -> Boolean,
    ): ActivitySnapshot {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        var current = activity(scenario)
        while (SystemClock.elapsedRealtime() < deadline) {
            current = activity(scenario)
            if (predicate(current)) return current
            SystemClock.sleep(50)
        }
        error("activity timeout: orientation=${current.orientation}")
    }

    private fun waitState(
        scenario: ActivityScenario<MainActivity>,
        timeoutMs: Long = 20_000,
        predicate: (ViewerUiState) -> Boolean,
    ): ViewerUiState {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        var current = state(scenario)
        while (SystemClock.elapsedRealtime() < deadline) {
            current = state(scenario)
            if (predicate(current)) return current
            SystemClock.sleep(50)
        }
        error("viewer state timeout: $current")
    }

    private data class ActivitySnapshot(
        val activity: MainActivity,
        val viewer: ViewerViewModel,
        val orientation: Int,
    )

    private class OneShotDecodeBarrier {
        private val armed = AtomicBoolean(true)
        private val entered = CountDownLatch(1)
        private val released = CountDownLatch(1)

        fun block(request: FrameRequest) {
            if (!armed.compareAndSet(true, false)) return
            entered.countDown()
            check(released.await(15, TimeUnit.SECONDS)) {
                "decode barrier timed out for ${request.token}"
            }
        }

        fun awaitEntered(): Boolean = entered.await(10, TimeUnit.SECONDS)

        fun release() {
            released.countDown()
        }
    }

    private class OneShotPrefetchBarrier {
        private val armed = AtomicBoolean(true)
        private val entered = CountDownLatch(1)
        private val released = CountDownLatch(1)

        fun block(request: FrameRequest, frame: FrameKey) {
            if (!armed.compareAndSet(true, false)) return
            entered.countDown()
            check(released.await(15, TimeUnit.SECONDS)) {
                "prefetch barrier timed out for ${request.token} / $frame"
            }
        }

        fun awaitEntered(): Boolean = entered.await(10, TimeUnit.SECONDS)

        fun release() {
            released.countDown()
        }
    }
}
