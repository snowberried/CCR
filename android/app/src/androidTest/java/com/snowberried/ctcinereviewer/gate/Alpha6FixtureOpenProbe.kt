package com.snowberried.ctcinereviewer.gate

import android.content.Context
import android.content.pm.PackageManager
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import android.graphics.ImageFormat
import com.snowberried.ctcinereviewer.BuildConfig
import org.json.JSONArray
import org.json.JSONObject
import java.io.FileNotFoundException
import java.security.MessageDigest

internal data class Alpha6FixtureSpec(
    val id: String,
    val fileName: String,
    val expectedSha256: String,
    val expectedPtsBySampleOrdinal: List<Long>,
)

internal data class Alpha6AssetIdentity(
    val byteCount: Long,
    val sha256: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("byteCount", byteCount)
        .put("sha256", sha256)
}

internal data class Alpha6ProviderDescriptor(
    val authority: String,
    val exported: Boolean,
    val statSize: Long,
    val regularFile: Boolean,
    val seekable: Boolean,
    val initialOffset: Long,
    val byteCount: Long,
    val sha256: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("authority", authority)
        .put("resolved", true)
        .put("exported", exported)
        .put("statSize", statSize)
        .put("regularFile", regularFile)
        .put("seekable", seekable)
        .put("initialOffset", initialOffset)
        .put("byteCount", byteCount)
        .put("sha256", sha256)
}

internal data class Alpha6ExtractorResult(
    val trackCount: Int,
    val videoTrackIndex: Int,
    val mime: String,
    val sampleCount: Int,
    val firstPtsUs: Long,
    val lastPtsUs: Long,
    val format: MediaFormat,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("trackCount", trackCount)
        .put("videoTrackIndex", videoTrackIndex)
        .put("mime", mime)
        .put("sampleCount", sampleCount)
        .put("firstPtsUs", firstPtsUs)
        .put("lastPtsUs", lastPtsUs)
}

internal data class Alpha6HardwareDecoderResult(
    val componentName: String,
    val hardwareAccelerated: Boolean,
    val softwareOnly: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("componentName", componentName)
        .put("hardwareAccelerated", hardwareAccelerated)
        .put("softwareOnly", softwareOnly)
}

internal data class Alpha6CodecStartResult(
    val componentName: String,
    val surfaceReady: Boolean,
    val configured: Boolean,
    val started: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("componentName", componentName)
        .put("surfaceReady", surfaceReady)
        .put("configured", configured)
        .put("started", started)
        .put("queuedInputBufferCount", 0)
        .put("dequeuedOutputBufferCount", 0)
}

internal data class Alpha6ProbeFailure(
    val stageCode: String,
    val classification: String,
    val exceptionClass: String,
    val sanitizedDetail: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("stageCode", stageCode)
        .put("classification", classification)
        .put("exceptionClass", exceptionClass)
        .put("sanitizedDetail", sanitizedDetail)
}

internal class Alpha6FixtureProbeException(
    val failure: Alpha6ProbeFailure,
    cause: Throwable? = null,
) : AssertionError(failure.classification) {
    init {
        if (cause != null) initCause(cause)
    }
}

internal data class Alpha6ProbeAttempt<T>(
    val value: T?,
    val failure: Alpha6ProbeFailure?,
) {
    val passed: Boolean get() = value != null && failure == null

    fun toJson(encode: (T) -> JSONObject): JSONObject = JSONObject()
        .put("status", if (passed) "PASS" else "FAIL")
        .put("result", value?.let(encode) ?: JSONObject.NULL)
        .put("failure", failure?.toJson() ?: JSONObject.NULL)
}

internal data class Alpha6FixtureOpenResult(
    val spec: Alpha6FixtureSpec,
    val asset: Alpha6AssetIdentity,
    val providerDescriptor: Alpha6ProviderDescriptor,
    val fdOnly: Alpha6ProbeAttempt<Alpha6ExtractorResult>,
    val explicitRange: Alpha6ProbeAttempt<Alpha6ExtractorResult>?,
    val hardwareDecoder: Alpha6ProbeAttempt<Alpha6HardwareDecoderResult>,
    val codecConfigureStart: Alpha6ProbeAttempt<Alpha6CodecStartResult>?,
) {
    fun requiredFailure(): Alpha6ProbeFailure? {
        val fdFailure = fdOnly.failure
        val explicitFailure = explicitRange?.failure
        if (fdFailure != null && explicitRange?.passed == true) {
            return Alpha6ProbeFailure(
                stageCode = "EXTRACTOR_FD_ONLY_COMPARISON",
                classification = "PRODUCT_RUNTIME_OPEN_CONTRACT_CHANGE_REQUIRED",
                exceptionClass = fdFailure.exceptionClass,
                sanitizedDetail = "FD_ONLY_FAILED_EXPLICIT_RANGE_PASSED",
            )
        }
        if (fdFailure != null) return fdFailure
        if (explicitFailure != null) return explicitFailure
        if (explicitRange != null) {
            val fdResult = requireNotNull(fdOnly.value)
            val explicitResult = requireNotNull(explicitRange.value)
            if (
                fdResult.trackCount != explicitResult.trackCount ||
                fdResult.videoTrackIndex != explicitResult.videoTrackIndex ||
                fdResult.mime != explicitResult.mime ||
                fdResult.sampleCount != explicitResult.sampleCount ||
                fdResult.firstPtsUs != explicitResult.firstPtsUs ||
                fdResult.lastPtsUs != explicitResult.lastPtsUs
            ) {
                return Alpha6ProbeFailure(
                    stageCode = "EXTRACTOR_MODE_COMPARISON",
                    classification = "MEDIA_EXTRACTOR_SAMPLE_ENUMERATION_FAILURE",
                    exceptionClass = "ContractViolation",
                    sanitizedDetail = "EXTRACTOR_MODE_RESULT_MISMATCH",
                )
            }
        }
        hardwareDecoder.failure?.let { return it }
        codecConfigureStart?.failure?.let { return it }
        return null
    }

    fun toJson(): JSONObject = JSONObject()
        .put("fixture", spec.fileName)
        .put("expectedSourceSha256", spec.expectedSha256)
        .put("expectedSampleCount", spec.expectedPtsBySampleOrdinal.size)
        .put("status", if (requiredFailure() == null) "PASS" else "FAIL")
        .put("asset", asset.toJson())
        .put("providerDescriptor", providerDescriptor.toJson())
        .put("cachePfdSha256", providerDescriptor.sha256)
        .put("extractorFdOnly", fdOnly.toJson(Alpha6ExtractorResult::toJson))
        .put(
            "extractorExplicitRange",
            explicitRange?.toJson(Alpha6ExtractorResult::toJson) ?: JSONObject.NULL,
        )
        .put("hardwareDecoderCandidate", hardwareDecoder.toJson(Alpha6HardwareDecoderResult::toJson))
        .put(
            "codecConfigureStart",
            codecConfigureStart?.toJson(Alpha6CodecStartResult::toJson) ?: JSONObject.NULL,
        )
        .put("fullFrameDecodeCount", 0)
        .put("performanceScenarioCount", 0)
        .also { json ->
            requiredFailure()?.let { json.put("failure", it.toJson()) }
        }
}

internal class Alpha6FixtureOpenProgress(
    val fixtureId: String,
) {
    var spec: Alpha6FixtureSpec? = null
    var asset: Alpha6AssetIdentity? = null
    var providerDescriptor: Alpha6ProviderDescriptor? = null
    var fdOnly: Alpha6ProbeAttempt<Alpha6ExtractorResult>? = null
    var explicitRange: Alpha6ProbeAttempt<Alpha6ExtractorResult>? = null
    var hardwareDecoder: Alpha6ProbeAttempt<Alpha6HardwareDecoderResult>? = null
    var codecConfigureStart: Alpha6ProbeAttempt<Alpha6CodecStartResult>? = null
    var result: Alpha6FixtureOpenResult? = null
    var failure: Alpha6ProbeFailure? = null

    var goldenContractPassed = false
    var assetHashPassed = false
    var providerResolvePassed = false
    var providerOpenPassed = false
    var providerPfdStatPassed = false
    var providerPfdRegularFilePassed = false
    var providerPfdSeekablePassed = false
    var cacheVerificationPassed = false
    var fdOnlySetDataSourcePassed = false
    var fdOnlyVideoTrackPassed = false
    var fdOnlySampleEnumerationPassed = false
    var explicitRangeSetDataSourcePassed = false
    var explicitRangeVideoTrackPassed = false
    var explicitRangeSampleEnumerationPassed = false
    var renderSurfaceReadyPassed = false
    var codecConfigurePassed = false
    var codecStartPassed = false

    val extractorFdOnlyPassed: Boolean get() = fdOnly?.passed == true
    val extractorExplicitRangePassed: Boolean get() = explicitRange?.passed == true
    val hardwareDecoderCandidatePassed: Boolean get() = hardwareDecoder?.passed == true
    val codecConfigureStartPassed: Boolean get() = codecConfigureStart?.passed == true

    fun fixtureJson(failureOverride: Alpha6ProbeFailure? = failure): JSONObject {
        val completed = result
        val json = completed?.toJson() ?: JSONObject()
            .put("fixture", spec?.fileName ?: "$fixtureId.mp4")
            .put("expectedSourceSha256", spec?.expectedSha256 ?: JSONObject.NULL)
            .put("expectedSampleCount", spec?.expectedPtsBySampleOrdinal?.size ?: JSONObject.NULL)
            .put("status", "FAIL")
            .put("asset", asset?.toJson() ?: JSONObject.NULL)
            .put("providerDescriptor", providerDescriptor?.toJson() ?: JSONObject.NULL)
            .put("cachePfdSha256", providerDescriptor?.sha256 ?: JSONObject.NULL)
            .put(
                "extractorFdOnly",
                fdOnly?.toJson(Alpha6ExtractorResult::toJson) ?: JSONObject.NULL,
            )
            .put(
                "extractorExplicitRange",
                explicitRange?.toJson(Alpha6ExtractorResult::toJson) ?: JSONObject.NULL,
            )
            .put(
                "hardwareDecoderCandidate",
                hardwareDecoder?.toJson(Alpha6HardwareDecoderResult::toJson) ?: JSONObject.NULL,
            )
            .put(
                "codecConfigureStart",
                codecConfigureStart?.toJson(Alpha6CodecStartResult::toJson) ?: JSONObject.NULL,
            )
            .put("fullFrameDecodeCount", 0)
            .put("performanceScenarioCount", 0)
        json.put("stageProgress", stageProgressJson())
        val effectiveFailure = failureOverride ?: completed?.requiredFailure()
        if (effectiveFailure != null) {
            json.put("status", "FAIL")
            json.put("failure", effectiveFailure.toJson())
        }
        return json
    }

    private fun stageProgressJson(): JSONObject = JSONObject()
        .put("goldenContractPassed", goldenContractPassed)
        .put("assetHashPassed", assetHashPassed)
        .put("providerResolvePassed", providerResolvePassed)
        .put("providerOpenPassed", providerOpenPassed)
        .put("providerPfdStatPassed", providerPfdStatPassed)
        .put("providerPfdRegularFilePassed", providerPfdRegularFilePassed)
        .put("providerPfdSeekablePassed", providerPfdSeekablePassed)
        .put("cacheVerificationPassed", cacheVerificationPassed)
        .put("extractorFdOnlySetDataSourcePassed", fdOnlySetDataSourcePassed)
        .put("extractorFdOnlyVideoTrackPassed", fdOnlyVideoTrackPassed)
        .put("extractorFdOnlySampleEnumerationPassed", fdOnlySampleEnumerationPassed)
        .put("extractorExplicitRangeSetDataSourcePassed", explicitRangeSetDataSourcePassed)
        .put("extractorExplicitRangeVideoTrackPassed", explicitRangeVideoTrackPassed)
        .put("extractorExplicitRangeSampleEnumerationPassed", explicitRangeSampleEnumerationPassed)
        .put("hardwareDecoderCandidatePassed", hardwareDecoderCandidatePassed)
        .put("renderSurfaceReadyPassed", renderSurfaceReadyPassed)
        .put("codecConfigurePassed", codecConfigurePassed)
        .put("codecStartPassed", codecStartPassed)
}

internal object Alpha6FixtureOpenProbe {
    private const val ASSET_DIRECTORY = "frame-accuracy"
    private val fixtureIdPattern = Regex("[a-z0-9-]+")
    private val shaPattern = Regex("[a-f0-9]{64}")
    private val stableDetailPattern = Regex("[A-Za-z0-9_.:;=-]{1,240}")

    val requiredFixtures: List<String>
        get() = S24FrameAccuracyTest.REQUIRED_FIXTURES

    fun probe(
        context: Context,
        fixtureId: String,
        configureCodec: Boolean,
        compareExplicitRange: Boolean,
        progress: Alpha6FixtureOpenProgress,
    ): Alpha6FixtureOpenResult {
        require(progress.fixtureId == fixtureId) { "fixture progress identity mismatch" }
        try {
            val spec = loadSpec(context, fixtureId).also {
                progress.spec = it
                progress.goldenContractPassed = true
            }
            val asset = assetIdentity(context, spec).also {
                progress.asset = it
                progress.assetHashPassed = true
            }
            val descriptor = providerDescriptor(context, spec, progress).also {
                progress.providerDescriptor = it
            }
            val fdOnly = extractorAttempt(
                context = context,
                spec = spec,
                explicitRange = false,
                progress = progress,
            ).also { progress.fdOnly = it }
            val explicit = if (compareExplicitRange) {
                extractorAttempt(
                    context = context,
                    spec = spec,
                    explicitRange = true,
                    progress = progress,
                ).also { progress.explicitRange = it }
            } else {
                null
            }
            val format = fdOnly.value?.format ?: explicit?.value?.format
            val decoder: Alpha6ProbeAttempt<Alpha6HardwareDecoderResult> = if (format == null) {
                Alpha6ProbeAttempt<Alpha6HardwareDecoderResult>(
                    value = null,
                    failure = Alpha6ProbeFailure(
                        stageCode = "HARDWARE_DECODER_DISCOVERY",
                        classification = "HARDWARE_DECODER_DISCOVERY_FAILURE",
                        exceptionClass = "ContractViolation",
                        sanitizedDetail = "EXTRACTOR_FORMAT_UNAVAILABLE",
                    ),
                )
            } else {
                hardwareDecoderAttempt(format)
            }.also { progress.hardwareDecoder = it }
            val codec: Alpha6ProbeAttempt<Alpha6CodecStartResult>? = if (!configureCodec) {
                null
            } else if (format == null || decoder.value == null) {
                Alpha6ProbeAttempt<Alpha6CodecStartResult>(
                    value = null,
                    failure = decoder.failure ?: Alpha6ProbeFailure(
                        stageCode = "CODEC_CONFIGURE_START",
                        classification = "CODEC_CONFIGURE_START_FAILURE",
                        exceptionClass = "ContractViolation",
                        sanitizedDetail = "DECODER_CANDIDATE_UNAVAILABLE",
                    ),
                )
            } else {
                codecStartAttempt(format, decoder.value, progress)
            }.also { progress.codecConfigureStart = it }
            return Alpha6FixtureOpenResult(
                spec = spec,
                asset = asset,
                providerDescriptor = descriptor,
                fdOnly = fdOnly,
                explicitRange = explicit,
                hardwareDecoder = decoder,
                codecConfigureStart = codec,
            ).also {
                progress.result = it
                progress.failure = it.requiredFailure()
            }
        } catch (throwable: Throwable) {
            progress.failure = normalizedFailure(throwable)
            throw throwable
        }
    }

    fun requirePassed(result: Alpha6FixtureOpenResult) {
        result.requiredFailure()?.let { throw Alpha6FixtureProbeException(it) }
    }

    fun requireNoWriteOpens() {
        if (ReadOnlyFixtureProvider.writeOpenCount.get() != 0) {
            throw Alpha6FixtureProbeException(
                Alpha6ProbeFailure(
                    stageCode = "PROVIDER_WRITE_OPEN_COUNT",
                    classification = "PROVIDER_DESCRIPTOR_FAILURE",
                    exceptionClass = "ContractViolation",
                    sanitizedDetail = "WRITE_OPEN_COUNT_NON_ZERO",
                ),
            )
        }
    }

    fun fixtureFailureJson(fixture: String, failure: Alpha6ProbeFailure): JSONObject = JSONObject()
        .put("fixture", fixture)
        .put("status", "FAIL")
        .put("failure", failure.toJson())
        .put("fullFrameDecodeCount", 0)
        .put("performanceScenarioCount", 0)

    fun normalizedFailure(throwable: Throwable): Alpha6ProbeFailure =
        if (throwable is Alpha6FixtureProbeException) {
            throwable.failure
        } else {
            platformFailure(
                stageCode = "UNCLASSIFIED",
                classification = "UNCLASSIFIED_OPEN_PIPELINE_FAILURE",
                throwable = throwable,
            )
        }

    fun newReport(
        context: Context,
        kind: String,
        status: String,
        fixtureReports: JSONArray,
        progresses: List<Alpha6FixtureOpenProgress>,
        failure: Alpha6ProbeFailure?,
    ): JSONObject {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        return JSONObject()
            .put("schemaVersion", 1)
            .put("kind", kind)
            .put("status", status)
            .put("applicationId", context.packageName)
            .put("appVersionName", packageInfo.versionName)
            .put("appVersionCode", packageInfo.longVersionCode)
            .put("appCommitSha", BuildConfig.COMMIT_SHA)
            .put("device", JSONObject()
                .put("manufacturer", Build.MANUFACTURER)
                .put("model", Build.MODEL)
                .put("fingerprint", Build.FINGERPRINT)
                .put("securityPatch", Build.VERSION.SECURITY_PATCH)
                .put("sdk", Build.VERSION.SDK_INT))
            .put("syntheticOnly", true)
            .put("containsRealMediaMetadata", false)
            .put("fixtureCount", fixtureReports.length())
            .put("assetHashPassCount", progresses.count { it.assetHashPassed })
            .put("providerOpenPassCount", progresses.count { it.providerOpenPassed })
            .put(
                "cacheVerificationPassCount",
                progresses.count { it.cacheVerificationPassed },
            )
            .put("extractorFdOnlyPassCount", progresses.count { it.extractorFdOnlyPassed })
            .put(
                "extractorExplicitRangePassCount",
                progresses.count { it.extractorExplicitRangePassed },
            )
            .put("videoTrackPassCount", progresses.count { it.fdOnlyVideoTrackPassed })
            .put(
                "sampleEnumerationPassCount",
                progresses.count { it.fdOnlySampleEnumerationPassed },
            )
            .put(
                "hardwareDecoderCandidatePassCount",
                progresses.count { it.hardwareDecoderCandidatePassed },
            )
            .put(
                "codecConfigureStartPassCount",
                progresses.count { it.codecConfigureStartPassed },
            )
            .put("providerReadOpenCount", ReadOnlyFixtureProvider.readOpenCount.get())
            .put("writeOpenCount", ReadOnlyFixtureProvider.writeOpenCount.get())
            .put("fullFrameDecodeCount", 0)
            .put("performanceScenarioCount", 0)
            .put("performanceGateApplied", false)
            .put("fixtures", fixtureReports)
            .also { report ->
                if (failure != null) report.put("failure", failure.toJson())
            }
    }

    private fun loadSpec(context: Context, fixtureId: String): Alpha6FixtureSpec =
        atStage("GOLDEN_CONTRACT", "PACKAGED_FIXTURE_IDENTITY_FAILURE") {
            if (!fixtureIdPattern.matches(fixtureId)) {
                contractFailure(
                    "GOLDEN_CONTRACT",
                    "PACKAGED_FIXTURE_IDENTITY_FAILURE",
                    "INVALID_FIXTURE_ID",
                )
            }
            val json = context.assets.open("$ASSET_DIRECTORY/$fixtureId.json")
                .bufferedReader()
                .use { JSONObject(it.readText()) }
            val fileName = json.getString("fixture")
            if (fileName != "$fixtureId.mp4") {
                contractFailure(
                    "GOLDEN_CONTRACT",
                    "PACKAGED_FIXTURE_IDENTITY_FAILURE",
                    "GOLDEN_FIXTURE_NAME_MISMATCH",
                )
            }
            val expectedSha = json.getString("sourceSha256")
            if (!shaPattern.matches(expectedSha)) {
                contractFailure(
                    "GOLDEN_CONTRACT",
                    "PACKAGED_FIXTURE_IDENTITY_FAILURE",
                    "INVALID_GOLDEN_SHA256",
                )
            }
            val frameCount = json.getInt("frameCount")
            val frames = json.getJSONArray("frames")
            if (frameCount <= 0 || frames.length() != frameCount) {
                contractFailure(
                    "GOLDEN_CONTRACT",
                    "PACKAGED_FIXTURE_IDENTITY_FAILURE",
                    "INVALID_GOLDEN_FRAME_COUNT",
                )
            }
            val samples = List(frames.length()) { index ->
                val frame = frames.getJSONObject(index)
                frame.getInt("sampleOrdinal") to frame.getLong("ptsUs")
            }.sortedBy(Pair<Int, Long>::first)
            if (samples.map(Pair<Int, Long>::first) != (0 until frameCount).toList()) {
                contractFailure(
                    "GOLDEN_CONTRACT",
                    "PACKAGED_FIXTURE_IDENTITY_FAILURE",
                    "INVALID_GOLDEN_SAMPLE_ORDINALS",
                )
            }
            Alpha6FixtureSpec(
                id = fixtureId,
                fileName = fileName,
                expectedSha256 = expectedSha,
                expectedPtsBySampleOrdinal = samples.map(Pair<Int, Long>::second),
            )
        }

    private fun assetIdentity(context: Context, spec: Alpha6FixtureSpec): Alpha6AssetIdentity =
        atStage("APK_ASSET_OPEN", "PACKAGED_FIXTURE_IDENTITY_FAILURE") {
            val identity = context.assets.open("$ASSET_DIRECTORY/${spec.fileName}").use(::digest)
            if (identity.byteCount <= 0L) {
                contractFailure(
                    "APK_ASSET_BYTE_COUNT",
                    "PACKAGED_FIXTURE_IDENTITY_FAILURE",
                    "ASSET_EMPTY",
                )
            }
            if (identity.sha256 != spec.expectedSha256) {
                contractFailure(
                    "APK_ASSET_SHA256",
                    "PACKAGED_FIXTURE_IDENTITY_FAILURE",
                    "ASSET_SHA256_MISMATCH",
                )
            }
            identity
        }

    private fun providerDescriptor(
        context: Context,
        spec: Alpha6FixtureSpec,
        progress: Alpha6FixtureOpenProgress,
    ): Alpha6ProviderDescriptor {
        val authority = "${context.packageName}.fixture"
        val provider = atStage("PROVIDER_URI_RESOLVE", "PROVIDER_DESCRIPTOR_FAILURE") {
            context.packageManager.resolveContentProvider(
                authority,
                PackageManager.ComponentInfoFlags.of(0L),
            ) ?: contractFailure(
                "PROVIDER_URI_RESOLVE",
                "PROVIDER_DESCRIPTOR_FAILURE",
                "PROVIDER_NOT_RESOLVED",
            )
        }
        if (provider.authority != authority || provider.exported) {
            contractFailure(
                "PROVIDER_URI_RESOLVE",
                "PROVIDER_DESCRIPTOR_FAILURE",
                if (provider.exported) "PROVIDER_EXPORTED" else "PROVIDER_AUTHORITY_MISMATCH",
            )
        }
        progress.providerResolvePassed = true
        val descriptor = openProviderDescriptor(context, spec)
        progress.providerOpenPassed = true
        descriptor.use { pfd ->
            return atStage("PROVIDER_PFD_INSPECT", "PROVIDER_DESCRIPTOR_FAILURE") {
                val statSize = pfd.statSize
                if (statSize <= 0L) {
                    contractFailure(
                        "PROVIDER_PFD_STAT_SIZE",
                        "FIXTURE_CACHE_MATERIALIZATION_FAILURE",
                        "CACHE_PFD_EMPTY",
                    )
                }
                progress.providerPfdStatPassed = true
                val stat = Os.fstat(pfd.fileDescriptor)
                val regular = OsConstants.S_ISREG(stat.st_mode)
                if (!regular) {
                    contractFailure(
                        "PROVIDER_PFD_REGULAR_FILE",
                        "PROVIDER_DESCRIPTOR_FAILURE",
                        "PFD_NOT_REGULAR_FILE",
                    )
                }
                progress.providerPfdRegularFilePassed = true
                val initialOffset = Os.lseek(pfd.fileDescriptor, 0L, OsConstants.SEEK_CUR)
                progress.providerPfdSeekablePassed = true
                val duplicate = ParcelFileDescriptor.dup(pfd.fileDescriptor)
                Os.lseek(duplicate.fileDescriptor, 0L, OsConstants.SEEK_SET)
                val identity = ParcelFileDescriptor.AutoCloseInputStream(duplicate).use(::digest)
                Os.lseek(pfd.fileDescriptor, initialOffset, OsConstants.SEEK_SET)
                if (identity.byteCount != statSize || identity.sha256 != spec.expectedSha256) {
                    contractFailure(
                        "PROVIDER_PFD_SHA256",
                        "FIXTURE_CACHE_MATERIALIZATION_FAILURE",
                        if (identity.byteCount != statSize) {
                            "CACHE_PFD_SIZE_MISMATCH"
                        } else {
                            "CACHE_PFD_SHA256_MISMATCH"
                        },
                    )
                }
                progress.cacheVerificationPassed = true
                Alpha6ProviderDescriptor(
                    authority = authority,
                    exported = provider.exported,
                    statSize = statSize,
                    regularFile = regular,
                    seekable = true,
                    initialOffset = initialOffset,
                    byteCount = identity.byteCount,
                    sha256 = identity.sha256,
                )
            }
        }
    }

    private fun extractorAttempt(
        context: Context,
        spec: Alpha6FixtureSpec,
        explicitRange: Boolean,
        progress: Alpha6FixtureOpenProgress,
    ): Alpha6ProbeAttempt<Alpha6ExtractorResult> = attempt {
        val mode = if (explicitRange) "EXPLICIT_RANGE" else "FD_ONLY"
        val descriptor = openProviderDescriptor(context, spec)
        descriptor.use { pfd ->
            val extractor = atStage(
                "MEDIA_EXTRACTOR_${mode}_CREATE",
                "MEDIA_EXTRACTOR_SET_DATASOURCE_FAILURE",
            ) { MediaExtractor() }
            try {
                atStage(
                    "MEDIA_EXTRACTOR_${mode}_SET_DATASOURCE",
                    "MEDIA_EXTRACTOR_SET_DATASOURCE_FAILURE",
                ) {
                    if (explicitRange) {
                        val length = pfd.statSize
                        if (length <= 0L) {
                            contractFailure(
                                "MEDIA_EXTRACTOR_EXPLICIT_RANGE_SET_DATASOURCE",
                                "MEDIA_EXTRACTOR_SET_DATASOURCE_FAILURE",
                                "EXPLICIT_RANGE_LENGTH_INVALID",
                            )
                        }
                        extractor.setDataSource(pfd.fileDescriptor, 0L, length)
                    } else {
                        extractor.setDataSource(pfd.fileDescriptor)
                    }
                }
                if (explicitRange) {
                    progress.explicitRangeSetDataSourcePassed = true
                } else {
                    progress.fdOnlySetDataSourcePassed = true
                }
                val track = atStage(
                    "MEDIA_EXTRACTOR_${mode}_TRACK",
                    "MEDIA_EXTRACTOR_TRACK_FAILURE",
                ) {
                    val trackCount = extractor.trackCount
                    val videoTrackIndex = (0 until trackCount).firstOrNull { index ->
                        extractor.getTrackFormat(index)
                            .getString(MediaFormat.KEY_MIME)
                            ?.startsWith("video/") == true
                    } ?: contractFailure(
                        "MEDIA_EXTRACTOR_${mode}_TRACK",
                        "MEDIA_EXTRACTOR_TRACK_FAILURE",
                        "VIDEO_TRACK_NOT_FOUND",
                    )
                    val format = extractor.getTrackFormat(videoTrackIndex)
                    val mime = format.getString(MediaFormat.KEY_MIME)
                        ?: contractFailure(
                            "MEDIA_EXTRACTOR_${mode}_TRACK",
                            "MEDIA_EXTRACTOR_TRACK_FAILURE",
                            "VIDEO_MIME_MISSING",
                        )
                    Triple(trackCount, videoTrackIndex, mime) to format
                }
                val trackCount = track.first.first
                val videoTrackIndex = track.first.second
                val mime = track.first.third
                val format = track.second
                if (explicitRange) {
                    progress.explicitRangeVideoTrackPassed = true
                } else {
                    progress.fdOnlyVideoTrackPassed = true
                }
                val samplePts = atStage(
                    "MEDIA_EXTRACTOR_${mode}_SAMPLE_ENUMERATION",
                    "MEDIA_EXTRACTOR_SAMPLE_ENUMERATION_FAILURE",
                ) {
                    extractor.selectTrack(videoTrackIndex)
                    buildList {
                        while (extractor.sampleTrackIndex >= 0) {
                            if (extractor.sampleTrackIndex == videoTrackIndex) {
                                val ptsUs = extractor.sampleTime
                                if (ptsUs < 0L) break
                                add(ptsUs)
                            }
                            if (!extractor.advance()) break
                        }
                    }
                }
                if (
                    samplePts.size != spec.expectedPtsBySampleOrdinal.size ||
                    samplePts.firstOrNull() != spec.expectedPtsBySampleOrdinal.first() ||
                    samplePts.lastOrNull() != spec.expectedPtsBySampleOrdinal.last()
                ) {
                    contractFailure(
                        "MEDIA_EXTRACTOR_${mode}_SAMPLE_ENUMERATION",
                        "MEDIA_EXTRACTOR_SAMPLE_ENUMERATION_FAILURE",
                        when {
                            samplePts.size != spec.expectedPtsBySampleOrdinal.size ->
                                "SAMPLE_COUNT_MISMATCH"
                            samplePts.firstOrNull() != spec.expectedPtsBySampleOrdinal.first() ->
                                "FIRST_SAMPLE_PTS_MISMATCH"
                            else -> "LAST_SAMPLE_PTS_MISMATCH"
                        },
                    )
                }
                if (explicitRange) {
                    progress.explicitRangeSampleEnumerationPassed = true
                } else {
                    progress.fdOnlySampleEnumerationPassed = true
                }
                Alpha6ExtractorResult(
                    trackCount = trackCount,
                    videoTrackIndex = videoTrackIndex,
                    mime = mime,
                    sampleCount = samplePts.size,
                    firstPtsUs = samplePts.first(),
                    lastPtsUs = samplePts.last(),
                    format = format,
                )
            } finally {
                extractor.release()
            }
        }
    }

    private fun hardwareDecoderAttempt(
        format: MediaFormat,
    ): Alpha6ProbeAttempt<Alpha6HardwareDecoderResult> = attempt {
        atStage("HARDWARE_DECODER_DISCOVERY", "HARDWARE_DECODER_DISCOVERY_FAILURE") {
            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: contractFailure(
                    "HARDWARE_DECODER_DISCOVERY",
                    "HARDWARE_DECODER_DISCOVERY_FAILURE",
                    "VIDEO_MIME_MISSING",
                )
            val info = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.asSequence()
                .filter { !it.isEncoder && it.isHardwareAccelerated && !it.isSoftwareOnly }
                .filter { candidate ->
                    candidate.supportedTypes.any { it.equals(mime, ignoreCase = true) }
                }
                .firstOrNull { candidate ->
                    runCatching {
                        candidate.getCapabilitiesForType(mime).isFormatSupported(format)
                    }.getOrDefault(false)
                } ?: contractFailure(
                "HARDWARE_DECODER_DISCOVERY",
                "HARDWARE_DECODER_DISCOVERY_FAILURE",
                "HARDWARE_DECODER_NOT_FOUND",
            )
            Alpha6HardwareDecoderResult(
                componentName = info.name,
                hardwareAccelerated = info.isHardwareAccelerated,
                softwareOnly = info.isSoftwareOnly,
            )
        }
    }

    private fun codecStartAttempt(
        format: MediaFormat,
        decoder: Alpha6HardwareDecoderResult,
        progress: Alpha6FixtureOpenProgress,
    ): Alpha6ProbeAttempt<Alpha6CodecStartResult> = attempt {
        val reader = atStage("RENDER_SURFACE_CREATE", "RENDER_SURFACE_FAILURE") {
            val width = format.getInteger(MediaFormat.KEY_WIDTH)
            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
            if (width <= 0 || height <= 0) {
                contractFailure(
                    "RENDER_SURFACE_CREATE",
                    "RENDER_SURFACE_FAILURE",
                    "VIDEO_DIMENSIONS_INVALID",
                )
            }
            ImageReader.newInstance(width, height, ImageFormat.PRIVATE, 2)
        }
        var codec: MediaCodec? = null
        var started = false
        try {
            val surface = atStage("RENDER_SURFACE_READY", "RENDER_SURFACE_FAILURE") {
                reader.surface.also {
                    if (!it.isValid) {
                        contractFailure(
                            "RENDER_SURFACE_READY",
                            "RENDER_SURFACE_FAILURE",
                            "OUTPUT_SURFACE_INVALID",
                        )
                    }
                }
            }
            progress.renderSurfaceReadyPassed = true
            codec = atStage("CODEC_CREATE", "CODEC_CONFIGURE_START_FAILURE") {
                MediaCodec.createByCodecName(decoder.componentName)
            }
            atStage("CODEC_CONFIGURE_START", "CODEC_CONFIGURE_START_FAILURE") {
                format.setInteger(MediaFormat.KEY_ROTATION, 0)
                codec.configure(format, surface, null, 0)
                progress.codecConfigurePassed = true
                codec.start()
                started = true
                progress.codecStartPassed = true
            }
            Alpha6CodecStartResult(
                componentName = decoder.componentName,
                surfaceReady = surface.isValid,
                configured = true,
                started = true,
            )
        } finally {
            if (started) runCatching { codec?.stop() }
            runCatching { codec?.release() }
            reader.close()
        }
    }

    private fun openProviderDescriptor(
        context: Context,
        spec: Alpha6FixtureSpec,
    ): ParcelFileDescriptor = atStage("PROVIDER_OPEN_FILE_DESCRIPTOR", "PROVIDER_DESCRIPTOR_FAILURE") {
        val uri = Uri.Builder()
            .scheme("content")
            .authority("${context.packageName}.fixture")
            .appendPath(spec.fileName)
            .build()
        context.contentResolver.openFileDescriptor(uri, "r")
            ?: contractFailure(
                "PROVIDER_OPEN_FILE_DESCRIPTOR",
                "PROVIDER_DESCRIPTOR_FAILURE",
                "PFD_NULL",
            )
    }

    private fun digest(input: java.io.InputStream): Alpha6AssetIdentity {
        val digest = MessageDigest.getInstance("SHA-256")
        var byteCount = 0L
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
            byteCount += count
        }
        return Alpha6AssetIdentity(
            byteCount = byteCount,
            sha256 = digest.digest().joinToString("") { "%02x".format(it) },
        )
    }

    private inline fun <T> attempt(block: () -> T): Alpha6ProbeAttempt<T> =
        try {
            Alpha6ProbeAttempt(value = block(), failure = null)
        } catch (failure: Alpha6FixtureProbeException) {
            Alpha6ProbeAttempt(value = null, failure = failure.failure)
        } catch (throwable: Throwable) {
            Alpha6ProbeAttempt(
                value = null,
                failure = platformFailure(
                    stageCode = "UNCLASSIFIED",
                    classification = "UNCLASSIFIED_OPEN_PIPELINE_FAILURE",
                    throwable = throwable,
                ),
            )
        }

    private inline fun <T> atStage(
        stageCode: String,
        classification: String,
        block: () -> T,
    ): T = try {
        block()
    } catch (failure: Alpha6FixtureProbeException) {
        throw failure
    } catch (throwable: Throwable) {
        throw Alpha6FixtureProbeException(
            platformFailure(stageCode, classification, throwable),
            throwable,
        )
    }

    private fun contractFailure(
        stageCode: String,
        classification: String,
        detail: String,
    ): Nothing = throw Alpha6FixtureProbeException(
        Alpha6ProbeFailure(
            stageCode = stageCode,
            classification = classification,
            exceptionClass = "ContractViolation",
            sanitizedDetail = detail,
        ),
    )

    private fun platformFailure(
        stageCode: String,
        classification: String,
        throwable: Throwable,
    ): Alpha6ProbeFailure {
        val detail = when (throwable) {
            is MediaCodec.CodecException -> {
                "errorCode=${throwable.errorCode};" +
                    "diagnosticInfo=${stableDetail(throwable.diagnosticInfo)};" +
                    "recoverable=${throwable.isRecoverable};" +
                    "transient=${throwable.isTransient}"
            }
            is FileNotFoundException -> stableDetail(throwable.message)
            is SecurityException -> "SECURITY_EXCEPTION"
            else -> "REDACTED"
        }
        return Alpha6ProbeFailure(
            stageCode = stageCode,
            classification = classification,
            exceptionClass = throwable.javaClass.simpleName
                .takeIf { it.matches(Regex("[A-Za-z0-9_$]{1,96}")) }
                ?: "Throwable",
            sanitizedDetail = detail,
        )
    }

    private fun stableDetail(value: String?): String =
        value?.takeIf(stableDetailPattern::matches) ?: "REDACTED"
}
