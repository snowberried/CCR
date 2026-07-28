package com.snowberried.ctcinereviewer.gate

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.validation.ValidationHarnessV2
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class Alpha6CandidateIdentitySmokeTest {
    @Test
    fun candidateIdentityMatchesInstalledRevisionFiveArtifacts() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ValidationHarnessV2.requireIdentity(
            instrumentation.targetContext,
            instrumentation.context,
        )
    }
}
