package com.snowberried.ctcinereviewer.gate

import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.media.FrameResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class PilotRenderingTest {
    @Test
    fun pilotPublishesWithoutFullFrameReadback() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val scenario = ActivityScenario.launch<GateActivity>(
            Intent(context, GateActivity::class.java).putExtra(GateActivity.EXTRA_PILOT_MODE, true),
        )
        val activity = AtomicReference<GateActivity>()
        val ready = CountDownLatch(1)
        scenario.onActivity {
            activity.set(it)
            ready.countDown()
        }
        try {
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            val gate = activity.get()
            assertTrue(gate.awaitSurface())
            gate.runOnUiThread {
                gate.openFixture(Uri.parse("content://${context.packageName}.fixture/one-frame.mp4"))
            }
            assertNotNull(gate.awaitIndex())
            assertNotNull(gate.awaitMetadata())
            val observed = requireNotNull(gate.awaitResult())
            val published = observed.result as? FrameResult.Published
                ?: error("pilot did not publish: ${observed.result}")
            assertNull(published.imageProbe)
            assertEquals(0L, observed.diagnostics.fullFrameReadbackCount)
        } finally {
            scenario.close()
        }
    }
}
