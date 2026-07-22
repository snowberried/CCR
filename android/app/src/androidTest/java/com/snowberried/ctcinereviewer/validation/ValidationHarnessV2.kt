package com.snowberried.ctcinereviewer.validation

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.BuildConfig
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

internal data class ValidationHarnessIdentity(
    val runId: String,
    val runtimeSourceSha: String,
    val harnessSourceSha: String,
    val runtimeInputsTreeSha256: String,
    val artifactSetRevision: Int,
    val appSha256: String,
    val testApkSha256: String,
)

internal object ValidationHarnessV2 {
    private const val EXPECTED_RUNTIME_SOURCE_SHA = "c9a7147d39d2d370916f325a108876c0947ddcb8"
    private const val EXPECTED_RUNTIME_INPUTS_TREE_SHA256 =
        "0eb249abadab7d89ba42a40772eb9a8610c193c87279c8633bb6275ac828fc0d"
    private const val EXPECTED_ARTIFACT_SET_REVISION = 4
    private const val RUN_ID_LEDGER = "validation-harness-v2-run-ids.txt"
    private val shaPattern = Regex("[0-9a-f]{64}")
    private val sourceShaPattern = Regex("[0-9a-f]{40}")
    private val runIdPattern = Regex("[A-Za-z0-9][A-Za-z0-9._-]{7,127}")

    @Volatile
    private var cachedIdentity: ValidationHarnessIdentity? = null

    @Synchronized
    fun requireIdentity(
        targetContext: Context,
        testContext: Context,
    ): ValidationHarnessIdentity {
        cachedIdentity?.let { return it }
        val arguments = InstrumentationRegistry.getArguments()
        fun required(name: String): String = requireNotNull(arguments.getString(name)?.trim()?.takeIf(String::isNotEmpty)) {
            "missing instrumentation argument: $name"
        }

        val runId = required("runId")
        require(runIdPattern.matches(runId)) { "invalid instrumentation runId" }
        val runtimeSourceSha = required("runtimeSourceSha").lowercase()
        require(sourceShaPattern.matches(runtimeSourceSha)) { "invalid runtimeSourceSha" }
        require(runtimeSourceSha == EXPECTED_RUNTIME_SOURCE_SHA) { "runtimeSourceSha mismatch" }
        require(BuildConfig.COMMIT_SHA.lowercase() == runtimeSourceSha) {
            "instrumentation was compiled against a different runtime source"
        }
        val harnessSourceSha = required("harnessSourceSha").lowercase()
        require(sourceShaPattern.matches(harnessSourceSha)) { "invalid harnessSourceSha" }
        val runtimeInputsTreeSha256 = required("runtimeInputsTreeSha256").lowercase()
        require(shaPattern.matches(runtimeInputsTreeSha256)) { "invalid runtimeInputsTreeSha256" }
        require(runtimeInputsTreeSha256 == EXPECTED_RUNTIME_INPUTS_TREE_SHA256) {
            "runtimeInputsTreeSha256 mismatch"
        }
        val artifactSetRevision = required("artifactSetRevision").toIntOrNull()
        require(artifactSetRevision == EXPECTED_ARTIFACT_SET_REVISION) { "artifactSetRevision mismatch" }

        val appSha256 = sha256(File(targetContext.applicationInfo.sourceDir))
        val testApkSha256 = sha256(File(testContext.applicationInfo.sourceDir))
        requireShaArgument("expectedAppSha256", appSha256, ::required)
        requireShaArgument("expectedTestApkSha256", testApkSha256, ::required)
        registerUniqueRunId(targetContext, runId)

        return ValidationHarnessIdentity(
            runId = runId,
            runtimeSourceSha = runtimeSourceSha,
            harnessSourceSha = harnessSourceSha,
            runtimeInputsTreeSha256 = runtimeInputsTreeSha256,
            artifactSetRevision = artifactSetRevision,
            appSha256 = appSha256,
            testApkSha256 = testApkSha256,
        ).also { cachedIdentity = it }
    }

    fun putReportIdentity(
        report: JSONObject,
        identity: ValidationHarnessIdentity,
        startedAtElapsedRealtimeNs: Long,
        finishedAtElapsedRealtimeNs: Long,
        testCount: Int,
        instrumentationExpectedTestCount: Int,
    ): JSONObject {
        require(finishedAtElapsedRealtimeNs >= startedAtElapsedRealtimeNs)
        return report
            .put("runId", identity.runId)
            .put("startedAtElapsedRealtimeNs", startedAtElapsedRealtimeNs)
            .put("finishedAtElapsedRealtimeNs", finishedAtElapsedRealtimeNs)
            .put("runtimeSourceSha", identity.runtimeSourceSha)
            .put("harnessSourceSha", identity.harnessSourceSha)
            .put("runtimeInputsTreeSha256", identity.runtimeInputsTreeSha256)
            .put("artifactSetRevision", identity.artifactSetRevision)
            .put("testCount", testCount)
            .put("instrumentationExpectedTestCount", instrumentationExpectedTestCount)
            .put("appSha256", identity.appSha256)
            .put("testApkSha256", identity.testApkSha256)
    }

    private fun requireShaArgument(
        name: String,
        actual: String,
        required: (String) -> String,
    ) {
        val expected = required(name).lowercase()
        require(shaPattern.matches(expected)) { "invalid $name" }
        require(expected == actual) { "$name mismatch" }
    }

    private fun registerUniqueRunId(context: Context, runId: String) {
        val ledger = File(context.filesDir, RUN_ID_LEDGER)
        RandomAccessFile(ledger, "rw").use { file ->
            file.channel.lock().use {
                file.seek(0)
                require(file.length() <= Int.MAX_VALUE) { "runId ledger is too large" }
                val bytes = ByteArray(file.length().toInt())
                file.readFully(bytes)
                val used = bytes.toString(Charsets.UTF_8).lineSequence().filter(String::isNotBlank).toSet()
                require(runId !in used) { "duplicate instrumentation runId" }
                file.seek(file.length())
                file.write("$runId\n".toByteArray(Charsets.UTF_8))
                file.fd.sync()
            }
        }
    }

    private fun sha256(file: File): String {
        require(file.isFile) { "installed APK path is not a file" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
