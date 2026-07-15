package com.snowberried.ctcinereviewer.media

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.Surface
import com.snowberried.ctcinereviewer.render.EglFrameRenderer
import com.snowberried.ctcinereviewer.render.FrameRenderMode
import com.snowberried.ctcinereviewer.render.VideoViewport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal fun androidVideoBitDepth(mime: String, profile: Int?): Int = when (mime) {
    MediaFormat.MIMETYPE_VIDEO_AVC ->
        if (profile == MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10) 10 else 8
    MediaFormat.MIMETYPE_VIDEO_HEVC ->
        if (profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10) 10 else 8
    else -> 8
}

internal fun androidDecodedVideoBitDepth(mime: String, profile: Int?, colorFormat: Int?): Int =
    if (colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010) {
        10
    } else {
        androidVideoBitDepth(mime, profile)
    }

internal fun androidDecodedOutputIsHdr(colorTransfer: Int?, hdrStaticInfoPresent: Boolean): Boolean =
    colorTransfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
        colorTransfer == MediaFormat.COLOR_TRANSFER_HLG ||
        (colorTransfer == null && hdrStaticInfoPresent)

class ExactFrameSession(
    context: Context,
    private val listener: Listener,
    renderMode: FrameRenderMode = FrameRenderMode.PILOT,
) : AutoCloseable {
    interface Listener {
        fun onStatus(fileGeneration: Long?, status: String, detail: String? = null)
        fun onVideoOpened(metadata: ContainerMetadata)
        fun onVideoIndexed(video: IndexedVideo) = Unit
        fun onFrameResult(result: FrameResult, diagnostics: DecoderDiagnostics)
        fun onPublicationEvent(event: PublicationEvent) = Unit
        fun onSurfaceAvailabilityChanged(available: Boolean) = Unit
    }

    private data class DecoderResources(
        val fileGeneration: Long,
        val descriptor: ParcelFileDescriptor,
        val extractor: MediaExtractor,
        val trackIndex: Int,
        val format: MediaFormat,
        val codecInfo: MediaCodecInfo,
        var codec: MediaCodec,
        var outputSurface: Surface,
        val video: IndexedVideo,
        val metadata: ContainerMetadata,
    )

    private val appContext = context.applicationContext
    private val mainHandler = Handler(appContext.mainLooper)
    private val publicationGate = PublicationGate(SystemClock::elapsedRealtimeNanos) { event ->
        mainHandler.post { listener.onPublicationEvent(event) }
    }
    private val actorThread = HandlerThread("ccr-media-actor").apply { start() }
    private val actor = Handler(actorThread.looper)
    private val latestRequest = LatestRequestSlot<FrameRequest>()
    private val currentVideo = AtomicReference<IndexedVideo?>()
    private val surfaceChanged = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val requestMessageToken = Any()
    @Volatile private var beforeDecodeHookForTest: ((FrameRequest) -> Unit)? = null
    private val renderer = EglFrameRenderer(publicationGate, { available ->
        surfaceChanged.set(true)
        if (!available) invalidateForSurfaceLoss()
        mainHandler.post { listener.onSurfaceAvailabilityChanged(available) }
    }, renderMode)

    private var resources: DecoderResources? = null
    private var diagnostics = DecoderDiagnostics()

    fun createViewport(context: Context): VideoViewport = VideoViewport(context, renderer)

    fun open(uri: Uri, initialFrameIndex: Int = 0): GenerationToken? {
        if (closed.get()) return null
        val token = publicationGate.beginFile()
        currentVideo.set(null)
        latestRequest.clear()
        actor.removeCallbacksAndMessages(requestMessageToken)
        notifyStatus(token.fileGeneration, "indexing")
        actor.post { openInternal(uri, token, initialFrameIndex) }
        return token
    }

    fun requestFrame(frameIndex: Int): RequestAcceptance? {
        val video = currentVideo.get() ?: run {
            notifyStatus(null, "error", "VIDEO_NOT_READY")
            return null
        }
        if (frameIndex !in video.frames.indices) {
            notifyStatus(video.fileGeneration, "error", "FRAME_INDEX_OUT_OF_RANGE")
            return null
        }
        val acceptance = publicationGate.acceptRequest(
            video.fileGeneration,
            frameIndex,
            video.frames[frameIndex].key,
        ) ?: return null
        latestRequest.offer(acceptance.request)
        actor.removeCallbacksAndMessages(requestMessageToken)
        actor.postAtTime(
            {
                latestRequest.take()?.let(::decodeInternal)
            },
            requestMessageToken,
            SystemClock.uptimeMillis(),
        )
        notifyStatus(acceptance.request.token.fileGeneration, "decoding")
        return acceptance
    }

    fun cancel(): GenerationToken? {
        if (closed.get()) return null
        val token = publicationGate.invalidateRequest()
        latestRequest.clear()
        actor.removeCallbacksAndMessages(requestMessageToken)
        notifyStatus(token.fileGeneration, "cancelled")
        return token
    }

    fun trimMemory(level: Int) {
        renderer.trimCache(level)
    }

    internal fun setBeforeDecodeHookForTest(hook: ((FrameRequest) -> Unit)?) {
        beforeDecodeHookForTest = hook
    }

    internal fun awaitActorIdleForTest(timeoutMs: Long = 5_000): Boolean {
        val latch = CountDownLatch(1)
        actor.post(latch::countDown)
        return latch.await(timeoutMs, TimeUnit.MILLISECONDS)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        publicationGate.beginFile()
        latestRequest.clear()
        actor.removeCallbacksAndMessages(requestMessageToken)
        val latch = CountDownLatch(1)
        actor.post {
            closeResources()
            latch.countDown()
        }
        latch.await(2, TimeUnit.SECONDS)
        actorThread.quitSafely()
        actorThread.join(2_000)
        renderer.close()
    }

    private fun openInternal(uri: Uri, token: GenerationToken, initialFrameIndex: Int) {
        closeResources()
        diagnostics = DecoderDiagnostics()
        renderer.beginFile(token.fileGeneration)
        var descriptor: ParcelFileDescriptor? = null
        var extractor: MediaExtractor? = null
        var codec: MediaCodec? = null
        try {
            descriptor = appContext.contentResolver.openFileDescriptor(uri, "r")
                ?: error("SOURCE_OPEN_FAILED")
            extractor = MediaExtractor().apply { setDataSource(descriptor.fileDescriptor) }
            val trackIndex = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: error("VIDEO_TRACK_NOT_FOUND")
            val format = extractor.getTrackFormat(trackIndex)
            val support = classifyAndroidFormat(format)
            if (support is VideoSupport.Unsupported) error(support.reason)

            extractor.selectTrack(trackIndex)
            val startedAt = SystemClock.elapsedRealtime()
            val samples = mutableListOf<IndexedSample>()
            var ordinal = 0
            while (extractor.sampleTrackIndex >= 0) {
                if (!publicationGate.isCurrent(token)) error("OPEN_STALE")
                if (extractor.sampleTrackIndex == trackIndex) {
                    val ptsUs = extractor.sampleTime
                    if (ptsUs < 0) break
                    samples += IndexedSample(
                        sampleOrdinal = ordinal,
                        ptsUs = ptsUs,
                        sync = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0,
                    )
                    ordinal += 1
                }
                if (!extractor.advance()) break
            }
            if (samples.isEmpty()) error("VIDEO_HAS_NO_FRAMES")
            val video = buildFrameIndex(token.fileGeneration, samples)
            val indexBuildMs = SystemClock.elapsedRealtime() - startedAt
            diagnostics = diagnostics.copy(indexBuildMs = indexBuildMs)
            if (!publicationGate.isCurrent(token)) error("OPEN_STALE")

            val codecInfo = selectHardwareDecoder(format) ?: error("HARDWARE_DECODER_REQUIRED")
            val outputSurface = renderer.awaitDecoderSurface(3_000) ?: error("RENDER_SURFACE_NOT_READY")
            val metadata = metadataFrom(format, token.fileGeneration, video.frameCount, codecInfo)
            val configuredOutputMetadata = decodedOutputMetadataFrom(format)
            diagnostics = diagnostics.copy(configuredOutputMetadata = configuredOutputMetadata)
            renderer.configureFrame(metadata, configuredOutputMetadata)
            format.setInteger(MediaFormat.KEY_ROTATION, 0)
            codec = createCodec(codecInfo, format, outputSurface)
            resources = DecoderResources(
                token.fileGeneration,
                descriptor,
                extractor,
                trackIndex,
                format,
                codecInfo,
                codec,
                outputSurface,
                video,
                metadata,
            )
            descriptor = null
            extractor = null
            codec = null
            currentVideo.set(video)
            surfaceChanged.set(false)
            notifyOpened(metadata, video)

            val targetIndex = initialFrameIndex.coerceIn(0, video.frames.lastIndex)
            val firstRequest = publicationGate.acceptInitialRequest(
                token,
                targetIndex,
                video.frames[targetIndex].key,
            )?.request ?: return
            decodeInternal(firstRequest)
        } catch (error: Throwable) {
            codec?.let(::releaseCodec)
            extractor?.release()
            descriptor?.close()
            if (error.message != "OPEN_STALE" && publicationGate.isCurrent(token)) {
                val code = sanitizeError(error)
                notifyStatus(
                    token.fileGeneration,
                    if (code in UNSUPPORTED_CODES) "unsupported" else "error",
                    code,
                )
            }
        }
    }

    private fun decodeInternal(request: FrameRequest) {
        if (!publicationGate.isCurrent(request.token)) {
            report(FrameResult.DiscardedStale(request, "before-decode"))
            return
        }
        beforeDecodeHookForTest?.invoke(request)
        if (!publicationGate.isCurrent(request.token)) {
            report(FrameResult.DiscardedStale(request, "after-test-hook"))
            return
        }
        var current = resources
        if (current == null || current.fileGeneration != request.token.fileGeneration) {
            report(FrameResult.Error(request, "DECODER_NOT_READY"))
            return
        }
        if (surfaceChanged.getAndSet(false) || !current.outputSurface.isValid) {
            current = try {
                recreateCodec(current)
            } catch (_: Throwable) {
                report(
                    if (publicationGate.isCurrent(request.token)) {
                        FrameResult.Error(request, "DECODER_SURFACE_RECREATE_FAILED")
                    } else {
                        FrameResult.DiscardedStale(request, "surface-recreate")
                    },
                )
                return
            }
        }

        val cached = renderer.presentCached(request)
        if (cached != null) {
            when (cached.status) {
                EglFrameRenderer.AckStatus.PUBLISHED -> {
                    diagnostics = diagnostics.copy(cacheHitCount = diagnostics.cacheHitCount + 1)
                    report(
                        FrameResult.Published(
                            request,
                            cached.textureTimestampNs,
                            cacheHit = true,
                            imageProbe = cached.imageProbe,
                        ),
                    )
                }
                EglFrameRenderer.AckStatus.STALE -> report(FrameResult.DiscardedStale(request, cached.code ?: "cache"))
                EglFrameRenderer.AckStatus.ERROR -> report(FrameResult.Error(request, cached.code ?: "CACHE_RENDER_FAILED"))
            }
            return
        }
        diagnostics = diagnostics.copy(cacheMissCount = diagnostics.cacheMissCount + 1)

        val target = current.video.frames[request.requestedFrameIndex]
        val startSample = current.video.previousSyncSample(target)
        val duplicateCounts = mutableMapOf<Long, Int>()
        current.video.frames.asSequence()
            .filter { it.sampleOrdinal < startSample.sampleOrdinal }
            .forEach { duplicateCounts[it.key.ptsUs] = duplicateCounts.getOrDefault(it.key.ptsUs, 0) + 1 }

        try {
            current.codec.flush()
            current.extractor.seekTo(target.key.ptsUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            var inputEos = false
            var decodeOrdinal = 0L
            val info = MediaCodec.BufferInfo()
            val deadline = SystemClock.elapsedRealtime() + 15_000
            while (SystemClock.elapsedRealtime() < deadline) {
                if (!publicationGate.isCurrent(request.token)) {
                    diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                    report(FrameResult.DiscardedStale(request, "decode-loop"))
                    return
                }

                if (!inputEos) {
                    val inputIndex = current.codec.dequeueInputBuffer(0)
                    if (inputIndex >= 0) {
                        val inputBuffer = current.codec.getInputBuffer(inputIndex) ?: error("INPUT_BUFFER_MISSING")
                        val sampleTrack = current.extractor.sampleTrackIndex
                        if (sampleTrack < 0) {
                            current.codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEos = true
                        } else {
                            val size = current.extractor.readSampleData(inputBuffer, 0)
                            if (size < 0) {
                                current.codec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputEos = true
                            } else {
                                current.codec.queueInputBuffer(inputIndex, 0, size, current.extractor.sampleTime, 0)
                                current.extractor.advance()
                            }
                        }
                    }
                }

                when (val outputIndex = current.codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val decoded = runCatching {
                            decodedOutputMetadataFrom(current.codec.outputFormat)
                        }.getOrElse {
                            report(FrameResult.Unsupported(request, "OUTPUT_FORMAT_UNSUPPORTED"))
                            return
                        }
                        diagnostics = diagnostics.copy(
                            outputFormatChangeCount = diagnostics.outputFormatChangeCount + 1,
                            decodedOutputFormatHistory = diagnostics.decodedOutputFormatHistory
                                .let { history -> if (history.lastOrNull() == decoded) history else history + decoded },
                        )
                        when (val support = classifyDecodedOutput(current.metadata, decoded)) {
                            VideoSupport.Supported -> renderer.configureFrame(current.metadata, decoded)
                            is VideoSupport.Unsupported -> {
                                report(FrameResult.Unsupported(request, support.reason))
                                return
                            }
                        }
                    }
                    else -> if (outputIndex >= 0) {
                        decodeOrdinal += 1
                        diagnostics = diagnostics.copy(decodeOrdinal = diagnostics.decodeOrdinal + 1)
                        val ptsUs = info.presentationTimeUs
                        val duplicateOrdinal = duplicateCounts.getOrDefault(ptsUs, 0)
                        duplicateCounts[ptsUs] = duplicateOrdinal + 1
                        val outputFrame = current.video.frameForOutput(ptsUs, duplicateOrdinal)
                        if (outputFrame == null || outputFrame.key.displayFrameIndex < target.key.displayFrameIndex) {
                            current.codec.releaseOutputBuffer(outputIndex, false)
                        } else if (outputFrame.key != target.key) {
                            current.codec.releaseOutputBuffer(outputIndex, false)
                            report(FrameResult.Error(request, "OUTPUT_PASSED_TARGET"))
                            return
                        } else {
                            val handle = renderer.queueTarget(request)
                            if (handle == null) {
                                current.codec.releaseOutputBuffer(outputIndex, false)
                                report(FrameResult.Error(request, "RENDER_TARGET_BUSY"))
                                return
                            }
                            current.codec.releaseOutputBuffer(outputIndex, true)
                            val ack = handle.await(3_000)
                            when (ack.status) {
                                EglFrameRenderer.AckStatus.PUBLISHED -> {
                                    report(
                                        FrameResult.Published(
                                            request,
                                            ack.textureTimestampNs,
                                            cacheHit = false,
                                            imageProbe = ack.imageProbe,
                                        ),
                                    )
                                }
                                EglFrameRenderer.AckStatus.STALE -> {
                                    diagnostics = diagnostics.copy(staleDiscardCount = diagnostics.staleDiscardCount + 1)
                                    report(FrameResult.DiscardedStale(request, ack.code ?: "render"))
                                }
                                EglFrameRenderer.AckStatus.ERROR -> report(
                                    FrameResult.Error(request, ack.code ?: "RENDER_FAILED"),
                                )
                            }
                            return
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            report(FrameResult.Error(request, "EOS_BEFORE_TARGET"))
                            return
                        }
                    }
                }
            }
            report(FrameResult.Error(request, "DECODE_TIMEOUT"))
        } catch (_: Throwable) {
            report(
                if (publicationGate.isCurrent(request.token)) {
                    FrameResult.Error(request, "DECODE_FAILED")
                } else {
                    FrameResult.DiscardedStale(request, "decode-exception")
                },
            )
        }
    }

    private fun recreateCodec(current: DecoderResources): DecoderResources {
        releaseCodec(current.codec)
        val surface = renderer.awaitDecoderSurface(3_000) ?: error("RENDER_SURFACE_NOT_READY")
        current.codec = createCodec(current.codecInfo, current.format, surface)
        current.outputSurface = surface
        diagnostics = diagnostics.copy(decoderRecreateCount = diagnostics.decoderRecreateCount + 1)
        return current
    }

    private fun createCodec(info: MediaCodecInfo, format: MediaFormat, surface: Surface): MediaCodec =
        MediaCodec.createByCodecName(info.name).apply {
            configure(format, surface, null, 0)
            setOnFrameRenderedListener(
                { _, _, _ ->
                    diagnostics = diagnostics.copy(renderedCallbackCount = diagnostics.renderedCallbackCount + 1)
                },
                actor,
            )
            start()
        }

    private fun selectHardwareDecoder(format: MediaFormat): MediaCodecInfo? {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
        return MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.asSequence()
            .filter { !it.isEncoder && it.isHardwareAccelerated && !it.isSoftwareOnly }
            .filter { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
            .firstOrNull { info ->
                runCatching { info.getCapabilitiesForType(mime).isFormatSupported(format) }.getOrDefault(false)
            }
    }

    private fun classifyAndroidFormat(format: MediaFormat): VideoSupport {
        val mime = format.getString(MediaFormat.KEY_MIME) ?: return VideoSupport.Unsupported("MIME_MISSING")
        val profile = format.intOrNull(MediaFormat.KEY_PROFILE)
        val bitDepth = androidVideoBitDepth(mime, profile)
        val transfer = format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER)
        val hdr = transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
            transfer == MediaFormat.COLOR_TRANSFER_HLG ||
            format.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)
        val rotation = ((format.intOrNull(MediaFormat.KEY_ROTATION) ?: 0) % 360 + 360) % 360
        if (rotation !in setOf(0, 90, 180, 270)) return VideoSupport.Unsupported("ROTATION_UNSUPPORTED")
        val parWidth = format.intOrNull("sar-width") ?: 1
        val parHeight = format.intOrNull("sar-height") ?: 1
        if (parWidth <= 0 || parHeight <= 0) return VideoSupport.Unsupported("PIXEL_ASPECT_RATIO_UNSUPPORTED")
        return classifyVideoFormat(
            VideoFormatDescriptor(
                mime = mime,
                profileSupported = isProfileSupported(mime, profile),
                bitDepth = bitDepth,
                hdr = hdr,
                dolbyVision = mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION,
            ),
        )
    }

    private fun isProfileSupported(mime: String, profile: Int?): Boolean = when (mime) {
        MediaFormat.MIMETYPE_VIDEO_AVC -> profile in setOf(
            MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline,
            MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedBaseline,
            MediaCodecInfo.CodecProfileLevel.AVCProfileMain,
            MediaCodecInfo.CodecProfileLevel.AVCProfileExtended,
            MediaCodecInfo.CodecProfileLevel.AVCProfileHigh,
            MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedHigh,
        )
        MediaFormat.MIMETYPE_VIDEO_HEVC -> profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain
        else -> false
    }

    private fun metadataFrom(
        format: MediaFormat,
        fileGeneration: Long,
        frameCount: Int,
        codecInfo: MediaCodecInfo,
    ): ContainerMetadata = ContainerMetadata(
        fileGeneration = fileGeneration,
        mime = format.getString(MediaFormat.KEY_MIME) ?: "video/unknown",
        profile = format.intOrNull(MediaFormat.KEY_PROFILE),
        codedWidth = format.getInteger(MediaFormat.KEY_WIDTH),
        codedHeight = format.getInteger(MediaFormat.KEY_HEIGHT),
        cropLeft = cropLeft(format),
        cropTop = cropTop(format),
        cropRight = cropRight(format),
        cropBottom = cropBottom(format),
        rotationDegrees = ((format.intOrNull(MediaFormat.KEY_ROTATION) ?: 0) % 360 + 360) % 360,
        pixelAspectRatioWidth = format.intOrNull("sar-width") ?: 1,
        pixelAspectRatioHeight = format.intOrNull("sar-height") ?: 1,
        durationUs = format.longOrNull(MediaFormat.KEY_DURATION),
        frameCount = frameCount,
        codecComponent = codecInfo.name,
        hardwareAccelerated = codecInfo.isHardwareAccelerated,
    )

    private fun decodedOutputMetadataFrom(format: MediaFormat): DecodedOutputMetadata {
        val width = format.intOrNull(MediaFormat.KEY_WIDTH) ?: error("OUTPUT_FORMAT_UNSUPPORTED")
        val height = format.intOrNull(MediaFormat.KEY_HEIGHT) ?: error("OUTPUT_FORMAT_UNSUPPORTED")
        return DecodedOutputMetadata(
            width = width,
            height = height,
            cropLeft = cropLeft(format),
            cropTop = cropTop(format),
            cropRight = cropRight(format),
            cropBottom = cropBottom(format),
            colorStandard = format.intOrNull(MediaFormat.KEY_COLOR_STANDARD),
            colorRange = format.intOrNull(MediaFormat.KEY_COLOR_RANGE),
            colorTransfer = format.intOrNull(MediaFormat.KEY_COLOR_TRANSFER),
            mime = format.getString(MediaFormat.KEY_MIME),
            profile = format.intOrNull(MediaFormat.KEY_PROFILE),
            colorFormat = format.intOrNull(MediaFormat.KEY_COLOR_FORMAT),
            hdrStaticInfoPresent = runCatching {
                format.getByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO)?.hasRemaining() == true
            }.getOrDefault(false),
        )
    }

    private fun classifyDecodedOutput(
        container: ContainerMetadata,
        output: DecodedOutputMetadata,
    ): VideoSupport {
        val mime = container.mime
        val profile = if (output.mime == container.mime) output.profile ?: container.profile else container.profile
        val bitDepth = androidDecodedVideoBitDepth(mime, profile, output.colorFormat)
        val hdr = androidDecodedOutputIsHdr(output.colorTransfer, output.hdrStaticInfoPresent)
        return classifyDecodedOutputFormat(
            output,
            VideoFormatDescriptor(
                mime = mime,
                profileSupported = isProfileSupported(mime, profile),
                bitDepth = bitDepth,
                hdr = hdr,
                dolbyVision = mime == MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION,
            ),
        )
    }

    private fun closeResources() {
        currentVideo.set(null)
        resources?.let {
            releaseCodec(it.codec)
            it.extractor.release()
            it.descriptor.close()
        }
        resources = null
    }

    private fun invalidateForSurfaceLoss() {
        if (closed.get()) return
        publicationGate.invalidateRequest()
        latestRequest.clear()
        actor.removeCallbacksAndMessages(requestMessageToken)
    }

    private fun releaseCodec(codec: MediaCodec) {
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    private fun report(result: FrameResult) {
        val publicationStats = publicationGate.snapshotStats()
        val nextDiagnostics = diagnostics.copy(
            cacheBytes = renderer.cacheByteSize(),
            cacheHitCount = renderer.cacheHits(),
            cacheMissCount = renderer.cacheMisses(),
            publishedSwapCount = publicationStats.publishedSwapCount,
            staleBeforeSwapCount = publicationStats.staleBeforeSwapCount,
            swapFailureCount = publicationStats.swapFailureCount,
            surfaceInvalidCount = publicationStats.surfaceInvalidCount,
            publicationInvariantViolationCount = publicationStats.publicationInvariantViolationCount,
            fullFrameReadbackCount = renderer.fullFrameReadbacks(),
        )
        diagnostics = nextDiagnostics
        mainHandler.post { listener.onFrameResult(result, nextDiagnostics) }
    }

    private fun notifyStatus(fileGeneration: Long?, status: String, detail: String? = null) {
        mainHandler.post { listener.onStatus(fileGeneration, status, detail) }
    }

    private fun notifyOpened(metadata: ContainerMetadata, video: IndexedVideo) {
        mainHandler.post {
            listener.onVideoIndexed(video)
            listener.onVideoOpened(metadata)
        }
    }

    private fun sanitizeError(error: Throwable): String {
        val allowed = setOf(
            "SOURCE_OPEN_FAILED",
            "VIDEO_TRACK_NOT_FOUND",
            "VIDEO_HAS_NO_FRAMES",
            "HARDWARE_DECODER_REQUIRED",
            "RENDER_SURFACE_NOT_READY",
            "DOLBY_VISION_UNSUPPORTED",
            "CODEC_UNSUPPORTED",
            "PROFILE_OR_BIT_DEPTH_UNSUPPORTED",
            "HDR_UNSUPPORTED",
            "MIME_MISSING",
            "ROTATION_UNSUPPORTED",
            "PIXEL_ASPECT_RATIO_UNSUPPORTED",
            "OUTPUT_FORMAT_UNSUPPORTED",
        )
        return error.message?.takeIf(allowed::contains) ?: "VIDEO_OPEN_FAILED"
    }

    private fun MediaFormat.intOrNull(key: String): Int? =
        if (containsKey(key)) runCatching { getInteger(key) }.getOrNull() else null

    private fun MediaFormat.longOrNull(key: String): Long? =
        if (containsKey(key)) runCatching { getLong(key) }.getOrNull() else null

    private fun cropLeft(format: MediaFormat): Int = format.intOrNull(MediaFormat.KEY_CROP_LEFT) ?: 0
    private fun cropTop(format: MediaFormat): Int = format.intOrNull(MediaFormat.KEY_CROP_TOP) ?: 0
    private fun cropRight(format: MediaFormat): Int =
        format.intOrNull(MediaFormat.KEY_CROP_RIGHT) ?: (format.getInteger(MediaFormat.KEY_WIDTH) - 1)
    private fun cropBottom(format: MediaFormat): Int =
        format.intOrNull(MediaFormat.KEY_CROP_BOTTOM) ?: (format.getInteger(MediaFormat.KEY_HEIGHT) - 1)

    companion object {
        private val UNSUPPORTED_CODES = setOf(
            "DOLBY_VISION_UNSUPPORTED",
            "CODEC_UNSUPPORTED",
            "PROFILE_OR_BIT_DEPTH_UNSUPPORTED",
            "HDR_UNSUPPORTED",
            "ROTATION_UNSUPPORTED",
            "PIXEL_ASPECT_RATIO_UNSUPPORTED",
            "HARDWARE_DECODER_REQUIRED",
            "OUTPUT_FORMAT_UNSUPPORTED",
        )
    }
}
