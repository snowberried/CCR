package com.snowberried.ctcinereviewer.gate

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameResult
import com.snowberried.ctcinereviewer.validation.ValidationHarnessV2
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs
import kotlin.math.ceil

@RunWith(AndroidJUnit4::class)
class Alpha6RenderOpenSmokeTest {
    @Test
    fun h264IpRendersFirstExactFrameOnStableCurrentSurface() {
        assumeTrue(
            "Alpha 6 render-open smoke requires Samsung SM-S928*",
            Build.MANUFACTURER.equals("samsung", ignoreCase = true) &&
                Build.MODEL.startsWith("SM-S928"),
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val identity = ValidationHarnessV2.requireIdentity(context, instrumentation.context)
        val expected = loadExpectedFrameZero(context)
        val startedAtNs = SystemClock.elapsedRealtimeNanos()
        ReadOnlyFixtureProvider.readOpenCount.set(0)
        ReadOnlyFixtureProvider.writeOpenCount.set(0)

        var beforeOpen: Alpha6GateSurfaceSnapshot? = null
        var afterOpen: Alpha6GateSurfaceSnapshot? = null
        var driftCounters = Alpha6GateDriftCounters(0, 0, 0)
        val statuses = mutableListOf<CapturedRenderStatus>()
        var indexReceived = false
        var metadataReceived = false
        var firstFramePublished = false
        var actualFrameKey: FrameKey? = null
        var actualTextureTimestampNs: Long? = null
        var hardwareAccelerated: Boolean? = null
        var codecComponent: String? = null
        var actualEmbeddedFrameId: Int? = null
        var imageProbeSampleCount = 0
        var signatureMeanError: Double? = null
        var signatureP99Error: Int? = null
        var signatureMaximumError: Int? = null

        val outcome = runCatching {
            ActivityScenario.launch(GateActivity::class.java).use { scenario ->
                val stableGate = Alpha6StableGateActivity(scenario)
                var activityForEvidence: GateActivity? = null
                try {
                    val opened = stableGate.openFixture(fixtureUri(context))
                    val activity = opened.activity
                    activityForEvidence = activity
                    beforeOpen = opened.beforeOpen
                    afterOpen = opened.afterOpen
                    captureStatuses(activity, statuses)

                    val index = activity.awaitIndex(15) ?: throw Alpha6RenderOpenException(
                        "RENDER_OPEN_INDEX_TIMEOUT",
                        "INDEX_NOT_RECEIVED",
                    )
                    indexReceived = true
                    captureStatuses(activity, statuses)
                    require(index.frames.isNotEmpty()) {
                        "RENDER_OPEN_INDEX_EMPTY"
                    }
                    require(index.frames.first().key == expected.frameKey) {
                        "RENDER_OPEN_INDEX_FRAME_KEY_MISMATCH"
                    }

                    val metadata = activity.awaitMetadata(15) ?: throw Alpha6RenderOpenException(
                        "RENDER_OPEN_METADATA_TIMEOUT",
                        "METADATA_NOT_RECEIVED",
                    )
                    metadataReceived = true
                    captureStatuses(activity, statuses)
                    hardwareAccelerated = metadata.hardwareAccelerated
                    codecComponent = metadata.codecComponent
                    require(metadata.hardwareAccelerated) {
                        "RENDER_OPEN_SOFTWARE_DECODER_FORBIDDEN"
                    }
                    require(metadata.codecComponent.isNotBlank()) {
                        "RENDER_OPEN_CODEC_COMPONENT_MISSING"
                    }

                    val observed = activity.awaitResult(20) ?: throw Alpha6RenderOpenException(
                        "RENDER_OPEN_FRAME_TIMEOUT",
                        "FRAME_ZERO_NOT_RECEIVED",
                    )
                    val published = when (val result = observed.result) {
                        is FrameResult.Published -> result
                        is FrameResult.DiscardedStale -> throw Alpha6RenderOpenException(
                            "RENDER_OPEN_FRAME_STALE",
                            "FRAME_ZERO_DISCARDED_STALE",
                        )
                        is FrameResult.Error -> throw Alpha6RenderOpenException(
                            "RENDER_OPEN_FRAME_ERROR",
                            safeToken(result.code),
                        )
                        is FrameResult.Unsupported -> throw Alpha6RenderOpenException(
                            "RENDER_OPEN_FRAME_UNSUPPORTED",
                            safeToken(result.reason),
                        )
                    }
                    firstFramePublished = true
                    captureStatuses(activity, statuses)
                    actualFrameKey = published.request.expectedKey
                    actualTextureTimestampNs = published.textureTimestampNs
                    require(published.request.requestedFrameIndex == 0) {
                        "RENDER_OPEN_REQUESTED_INDEX_MISMATCH"
                    }
                    require(actualFrameKey == expected.frameKey) {
                        "RENDER_OPEN_PUBLISHED_FRAME_KEY_MISMATCH"
                    }
                    require(actualTextureTimestampNs == expected.textureTimestampNs) {
                        "RENDER_OPEN_TEXTURE_TIMESTAMP_MISMATCH"
                    }

                    val imageProbe = published.imageProbe ?: throw Alpha6RenderOpenException(
                        "RENDER_OPEN_IMAGE_PROBE_MISSING",
                        "FRAME_ZERO_IMAGE_PROBE_MISSING",
                    )
                    actualEmbeddedFrameId = imageProbe.embeddedFrameId
                    imageProbeSampleCount = imageProbe.imageSignature.size
                    require(actualEmbeddedFrameId == expected.embeddedFrameId) {
                        "RENDER_OPEN_EMBEDDED_FRAME_ID_MISMATCH"
                    }
                    require(imageProbe.imageSignature.size == expected.imageSignature.size) {
                        "RENDER_OPEN_IMAGE_SIGNATURE_LENGTH_MISMATCH"
                    }
                    val errors = imageProbe.imageSignature.zip(expected.imageSignature) { actual, frozen ->
                        abs(actual - frozen)
                    }.sorted()
                    signatureMeanError = errors.average()
                    signatureP99Error = errors[(ceil(errors.size * 0.99).toInt() - 1).coerceAtLeast(0)]
                    signatureMaximumError = errors.last()
                    require(requireNotNull(signatureMeanError) <= 6.0) {
                        "RENDER_OPEN_IMAGE_SIGNATURE_MEAN_MISMATCH"
                    }
                    require(requireNotNull(signatureP99Error) <= 16) {
                        "RENDER_OPEN_IMAGE_SIGNATURE_P99_MISMATCH"
                    }
                    require(requireNotNull(signatureMaximumError) <= 40) {
                        "RENDER_OPEN_IMAGE_SIGNATURE_MAX_MISMATCH"
                    }
                    require(ReadOnlyFixtureProvider.writeOpenCount.get() == 0) {
                        "RENDER_OPEN_WRITE_OPEN_FORBIDDEN"
                    }
                } finally {
                    val attemptEvidence = stableGate.lastOpenAttemptEvidence()
                    (activityForEvidence ?: attemptEvidence?.activity)?.let {
                        captureStatuses(it, statuses)
                    }
                    beforeOpen = beforeOpen ?: attemptEvidence?.beforeOpen
                    afterOpen = stableGate.currentSnapshot()
                    mergeGateEvents(statuses, attemptEvidence?.events.orEmpty())
                    driftCounters = stableGate.driftCounters()
                }
            }
        }

        val providerReadOpenCount = ReadOnlyFixtureProvider.readOpenCount.get()
        val writeOpenCount = ReadOnlyFixtureProvider.writeOpenCount.get()
        val providerOrExtractorEntered =
            providerReadOpenCount > 0 || indexReceived || metadataReceived
        val videoOpenFailedCount = statuses.count { captured ->
            captured.status == "VIDEO_OPEN_FAILED" ||
                captured.detail == "VIDEO_OPEN_FAILED" ||
                captured.status.contains("VIDEO_OPEN_FAILED") ||
                captured.detail?.contains("VIDEO_OPEN_FAILED") == true
        }
        val beforeSnapshot = beforeOpen
        val afterSnapshot = afterOpen
        val observedActivityDrift = if (
            beforeSnapshot?.activityInstanceId != null &&
            afterSnapshot?.activityInstanceId != null &&
            beforeSnapshot.activityInstanceId != afterSnapshot.activityInstanceId
        ) 1 else 0
        val observedGenerationDrift = if (
            beforeSnapshot?.surfaceGeneration != null &&
            afterSnapshot?.surfaceGeneration != null &&
            beforeSnapshot.surfaceGeneration != afterSnapshot.surfaceGeneration
        ) 1 else 0
        val beforeSnapshotReady = beforeSnapshot?.let(::isRenderReadySnapshot) == true
        val afterSnapshotReady = afterSnapshot?.let(::isRenderReadySnapshot) == true
        val observedSurfaceLoss = if (
            beforeSnapshotReady && !afterSnapshotReady
        ) 1 else 0
        val finalDriftCounters = Alpha6GateDriftCounters(
            activityInstanceDriftCount =
                driftCounters.activityInstanceDriftCount + observedActivityDrift,
            surfaceGenerationDriftCount =
                driftCounters.surfaceGenerationDriftCount + observedGenerationDrift,
            surfaceLossCount = driftCounters.surfaceLossCount + observedSurfaceLoss,
        )
        val validatedOutcome = outcome.mapCatching {
            if (!beforeSnapshotReady) {
                throw Alpha6RenderOpenException(
                    "RENDER_OPEN_SURFACE_NOT_STABLE",
                    "CURRENT_SURFACE_WAS_NOT_STABLE_BEFORE_OPEN",
                )
            }
            if (finalDriftCounters.activityInstanceDriftCount > 0) {
                throw Alpha6RenderOpenException(
                    "RENDER_OPEN_ACTIVITY_INSTANCE_DRIFT",
                    "ACTIVITY_INSTANCE_CHANGED_DURING_OPEN",
                )
            }
            if (finalDriftCounters.surfaceGenerationDriftCount > 0) {
                throw Alpha6RenderOpenException(
                    "RENDER_OPEN_SURFACE_GENERATION_DRIFT",
                    "SURFACE_GENERATION_CHANGED_DURING_OPEN",
                )
            }
            if (finalDriftCounters.surfaceLossCount > 0) {
                throw Alpha6RenderOpenException(
                    "RENDER_OPEN_SURFACE_LOST",
                    "SURFACE_BECAME_UNAVAILABLE_DURING_OPEN",
                )
            }
            if (videoOpenFailedCount > 0) {
                throw Alpha6RenderOpenException(
                    "RENDER_OPEN_VIDEO_OPEN_FAILED",
                    "VIDEO_OPEN_FAILED_OBSERVED",
                )
            }
        }
        val failure = validatedOutcome.exceptionOrNull()?.let { throwable ->
            classifyFailure(
                throwable = throwable,
                beforeOpen = beforeOpen,
                afterOpen = afterOpen,
                driftCounters = finalDriftCounters,
                providerOrExtractorEntered = providerOrExtractorEntered,
                indexReceived = indexReceived,
                metadataReceived = metadataReceived,
            )
        }
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val report = JSONObject()
            .put("schemaVersion", 1)
            .put("kind", "alpha6-render-open-smoke")
            .put("status", if (validatedOutcome.isSuccess) "PASS" else "FAIL")
            .put("applicationId", context.packageName)
            .put("appVersionName", packageInfo.versionName)
            .put("appVersionCode", packageInfo.longVersionCode)
            .put(
                "device",
                JSONObject()
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .put("fingerprint", Build.FINGERPRINT)
                    .put("securityPatch", Build.VERSION.SECURITY_PATCH)
                    .put("sdk", Build.VERSION.SDK_INT),
            )
            .put("fixture", FIXTURE_FILE)
            .put("stableIntervalMs", 300)
            .put("activityInstanceDriftCount", finalDriftCounters.activityInstanceDriftCount)
            .put("surfaceGenerationDriftCount", finalDriftCounters.surfaceGenerationDriftCount)
            .put("surfaceLossCount", finalDriftCounters.surfaceLossCount)
            .put("videoOpenFailedCount", videoOpenFailedCount)
            .put("providerReadOpenCount", providerReadOpenCount)
            .put("providerOrExtractorEntered", providerOrExtractorEntered)
            .put("indexReceived", indexReceived)
            .put("metadataReceived", metadataReceived)
            .put("firstFramePublished", firstFramePublished)
            .put("expectedFrameKey", frameKeyJson(expected.frameKey))
            .put("actualFrameKey", actualFrameKey?.let(::frameKeyJson) ?: JSONObject.NULL)
            .put("expectedTextureTimestampNs", expected.textureTimestampNs)
            .put("actualTextureTimestampNs", actualTextureTimestampNs ?: JSONObject.NULL)
            .put("hardwareAccelerated", hardwareAccelerated ?: JSONObject.NULL)
            .put("codecComponent", codecComponent ?: JSONObject.NULL)
            .put("writeOpenCount", writeOpenCount)
            .put("performanceScenarioCount", 0)
            .put("fullFrameDecodeCount", if (firstFramePublished) 1 else 0)
            .put("imageProbePresent", actualEmbeddedFrameId != null)
            .put("expectedEmbeddedFrameId", expected.embeddedFrameId)
            .put("actualEmbeddedFrameId", actualEmbeddedFrameId ?: JSONObject.NULL)
            .put("imageProbeSampleCount", imageProbeSampleCount)
            .put("signatureMeanError", signatureMeanError ?: JSONObject.NULL)
            .put("signatureP99Error", signatureP99Error ?: JSONObject.NULL)
            .put("signatureMaximumError", signatureMaximumError ?: JSONObject.NULL)
            .put(
                "activitySurfaceEvidence",
                JSONObject()
                    .put("beforeOpen", beforeOpen?.let(::surfaceSnapshotJson) ?: JSONObject.NULL)
                    .put("afterOpen", afterOpen?.let(::surfaceSnapshotJson) ?: JSONObject.NULL)
                    .put(
                        "statusSequence",
                        JSONArray(
                            statuses.map(::statusJson),
                        ),
                    ),
            )
            .put("failure", failure?.let(::failureJson) ?: JSONObject.NULL)
            .put("syntheticOnly", true)
            .put("containsRealMediaMetadata", false)
        ValidationHarnessV2.putReportIdentity(
            report = report,
            identity = identity,
            startedAtElapsedRealtimeNs = startedAtNs,
            finishedAtElapsedRealtimeNs = SystemClock.elapsedRealtimeNanos(),
            testCount = 1,
            instrumentationExpectedTestCount = 1,
        )
        File(context.filesDir, REPORT_FILE).writeText(report.toString(2))
        validatedOutcome.getOrThrow()
    }

    private fun loadExpectedFrameZero(context: Context): ExpectedFrameZero {
        val manifest = context.assets.open("frame-accuracy/h264-ip.json").bufferedReader().use {
            JSONObject(it.readText())
        }
        require(manifest.getString("fixture") == FIXTURE_FILE) {
            "RENDER_OPEN_FIXTURE_MANIFEST_MISMATCH"
        }
        val frame = manifest.getJSONArray("frames").getJSONObject(0)
        val key = FrameKey(
            displayFrameIndex = frame.getInt("displayFrameIndex"),
            ptsUs = frame.getLong("ptsUs"),
            duplicateOrdinal = frame.getInt("duplicateOrdinal"),
        )
        require(key.displayFrameIndex == 0) {
            "RENDER_OPEN_FROZEN_FRAME_ZERO_MISSING"
        }
        return ExpectedFrameZero(
            frameKey = key,
            textureTimestampNs = key.ptsUs * 1_000L,
            embeddedFrameId = frame.getInt("embeddedFrameId"),
            imageSignature = frame.getJSONArray("imageSignature").toIntList(),
        )
    }

    private fun classifyFailure(
        throwable: Throwable,
        beforeOpen: Alpha6GateSurfaceSnapshot?,
        afterOpen: Alpha6GateSurfaceSnapshot?,
        driftCounters: Alpha6GateDriftCounters,
        providerOrExtractorEntered: Boolean,
        indexReceived: Boolean,
        metadataReceived: Boolean,
    ): SmokeFailure {
        if (throwable is Alpha6StableGateException) {
            return SmokeFailure(
                classification = throwable.classification,
                stageCode = throwable.stageCode,
                exceptionClass = throwable.javaClass.simpleName,
                sanitizedDetail = throwable.sanitizedDetail,
            )
        }
        val classification = when {
            driftCounters.activityInstanceDriftCount > 0 ->
                Alpha6SurfaceFailureClassification.STALE_ACTIVITY_INSTANCE
            driftCounters.surfaceGenerationDriftCount > 0 ||
                driftCounters.surfaceLossCount > 0 ||
                (beforeOpen?.surfaceValid == true && afterOpen?.surfaceValid != true) ->
                Alpha6SurfaceFailureClassification.SURFACE_LOST_DURING_OPEN
            beforeOpen != null && !beforeOpen.decoderSurfaceAvailable ->
                Alpha6SurfaceFailureClassification.DECODER_SURFACE_UNAVAILABLE
            beforeOpen == null || !isRenderReadySnapshot(beforeOpen) ->
                Alpha6SurfaceFailureClassification.SURFACE_NOT_STABLE_BEFORE_OPEN
            providerOrExtractorEntered && (!indexReceived || !metadataReceived) ->
                Alpha6SurfaceFailureClassification.PROVIDER_OR_EXTRACTOR_OPEN_FAILURE
            else -> Alpha6SurfaceFailureClassification.UNCLASSIFIED_AFTER_STABLE_SURFACE
        }
        val stageCode = (throwable as? Alpha6RenderOpenException)?.stageCode
            ?: safeToken(throwable.message ?: "RENDER_OPEN_UNCLASSIFIED")
        val sanitizedDetail = (throwable as? Alpha6RenderOpenException)?.sanitizedDetail
            ?: safeToken(throwable.message ?: stageCode)
        return SmokeFailure(
            classification = classification,
            stageCode = stageCode,
            exceptionClass = throwable.javaClass.simpleName,
            sanitizedDetail = sanitizedDetail,
        )
    }

    private fun fixtureUri(context: Context): Uri =
        Uri.parse("content://${context.packageName}.fixture/$FIXTURE_FILE")

    private fun JSONArray.toIntList(): List<Int> = List(length()) { getInt(it) }

    private data class ExpectedFrameZero(
        val frameKey: FrameKey,
        val textureTimestampNs: Long,
        val embeddedFrameId: Int,
        val imageSignature: List<Int>,
    )

    internal data class SmokeFailure(
        val classification: Alpha6SurfaceFailureClassification,
        val stageCode: String,
        val exceptionClass: String,
        val sanitizedDetail: String,
    )

    private class Alpha6RenderOpenException(
        val stageCode: String,
        val sanitizedDetail: String,
    ) : AssertionError("$stageCode:$sanitizedDetail")

    private companion object {
        const val FIXTURE_FILE = "h264-ip.mp4"
        const val REPORT_FILE = "s24-alpha6-render-open-smoke-v1.json"
    }
}

private fun frameKeyJson(key: FrameKey): JSONObject = JSONObject()
    .put("displayFrameIndex", key.displayFrameIndex)
    .put("ptsUs", key.ptsUs)
    .put("duplicateOrdinal", key.duplicateOrdinal)

private fun surfaceSnapshotJson(snapshot: Alpha6GateSurfaceSnapshot): JSONObject = JSONObject()
    .put("capturedAtElapsedRealtimeNs", snapshot.capturedAtElapsedRealtimeNs)
    .put("scenarioState", snapshot.scenarioState)
    .put("activityInstanceId", snapshot.activityInstanceId ?: JSONObject.NULL)
    .put("activityFinishing", snapshot.activityFinishing ?: JSONObject.NULL)
    .put("activityDestroyed", snapshot.activityDestroyed ?: JSONObject.NULL)
    .put("decorAttached", snapshot.decorAttached ?: JSONObject.NULL)
    .put("surfaceViewPresent", snapshot.surfaceViewPresent ?: JSONObject.NULL)
    .put("surfaceValid", snapshot.surfaceValid ?: JSONObject.NULL)
    .put("surfaceGeneration", snapshot.surfaceGeneration ?: JSONObject.NULL)
    .put("decoderSurfaceAvailable", snapshot.decoderSurfaceAvailable)

private fun isRenderReadySnapshot(snapshot: Alpha6GateSurfaceSnapshot): Boolean =
    snapshot.scenarioState == "RESUMED" &&
        snapshot.activityInstanceId != null &&
        snapshot.activityFinishing == false &&
        snapshot.activityDestroyed == false &&
        snapshot.decorAttached == true &&
        snapshot.surfaceViewPresent == true &&
        snapshot.surfaceValid == true &&
        snapshot.decoderSurfaceAvailable

private data class CapturedRenderStatus(
    val ordinal: Int,
    val capturedAtElapsedRealtimeNs: Long,
    val status: String,
    val detail: String?,
)

private fun captureStatuses(
    activity: GateActivity,
    destination: MutableList<CapturedRenderStatus>,
) {
    val capturedAtNs = SystemClock.elapsedRealtimeNanos()
    activity.drainStatuses().forEach { (status, detail) ->
        destination += CapturedRenderStatus(
            ordinal = destination.size,
            capturedAtElapsedRealtimeNs = capturedAtNs,
            status = status,
            detail = detail,
        )
    }
}

private fun mergeGateEvents(
    destination: MutableList<CapturedRenderStatus>,
    gateEvents: List<Alpha6GateEvent>,
) {
    val combined = destination.mapIndexed { sourceIndex, status ->
        sourceIndex to status
    }.toMutableList()
    val offset = combined.size
    gateEvents.forEachIndexed { index, event ->
        combined += (offset + index) to CapturedRenderStatus(
            ordinal = -1,
            capturedAtElapsedRealtimeNs = event.capturedAtElapsedRealtimeNs,
            status = event.status,
            detail = event.detail,
        )
    }
    val ordered = combined.sortedWith(
        compareBy<Pair<Int, CapturedRenderStatus>>(
            { it.second.capturedAtElapsedRealtimeNs },
            { it.first },
        ),
    )
    destination.clear()
    ordered.forEachIndexed { index, entry ->
        destination += entry.second.copy(ordinal = index)
    }
}

private fun statusJson(status: CapturedRenderStatus): JSONObject = JSONObject()
    .put("ordinal", status.ordinal)
    .put("sequence", status.ordinal)
    .put("capturedAtElapsedRealtimeNs", status.capturedAtElapsedRealtimeNs)
    .put("status", safeToken(status.status))
    .put("detail", status.detail?.let(::safeToken) ?: JSONObject.NULL)

private fun failureJson(failure: Alpha6RenderOpenSmokeTest.SmokeFailure): JSONObject = JSONObject()
    .put("classification", failure.classification.name)
    .put("stageCode", failure.stageCode)
    .put("exceptionClass", failure.exceptionClass)
    .put("sanitizedDetail", failure.sanitizedDetail)

private fun safeToken(value: String): String =
    value.take(160).takeIf { SAFE_TOKEN.matches(it) } ?: "REDACTED"

private val SAFE_TOKEN = Regex("[A-Za-z0-9_.:\\[\\]=,/ -]{1,160}")
