package com.snowberried.ctcinereviewer.media

import android.os.Trace

internal object CcrTrace {
    const val NAVIGATION_INPUT = "CCR.navigation.input"
    const val NAVIGATION_PACING = "CCR.navigation.pacing"
    const val SEEK_PLAN = "CCR.seek.plan"
    const val SEEK_EXTRACTOR = "CCR.seek.extractor"
    const val CODEC_FLUSH = "CCR.codec.flush"
    const val CODEC_FEED = "CCR.codec.feed"
    const val CODEC_FIRST_OUTPUT = "CCR.codec.first-output"
    const val CODEC_TARGET_OUTPUT = "CCR.codec.target-output"
    const val REVERSE_WINDOW_PLAN = "CCR.reverse.window-plan"
    const val REVERSE_WINDOW_BUILD = "CCR.reverse.window-build"
    const val REVERSE_WINDOW_HIT = "CCR.reverse.window-hit"
    const val REVERSE_WINDOW_REFILL = "CCR.reverse.window-refill"
    const val TEXTURE_COPY = "CCR.texture.copy"
    const val REQUEST_ACCEPT = "CCR.request.accept"
    const val ACTOR_START = "CCR.actor.start"
    const val SEEK = "CCR.seek"
    const val FLUSH = "CCR.flush"
    const val INPUT_FIRST = "CCR.input.first"
    const val OUTPUT_FIRST = "CCR.output.first"
    const val OUTPUT_TARGET = "CCR.output.target"
    const val SURFACE_WAIT = "CCR.surface.wait"
    const val TEXTURE_UPDATE = "CCR.texture.update"
    const val CANONICAL_COPY = "CCR.canonical.copy"
    const val CACHE_PUT = "CCR.cache.put"
    const val CACHE_EVICT = "CCR.cache.evict"
    const val DRAW = "CCR.draw"
    const val PUBLISH = "CCR.publish"
    const val SWAP = "CCR.swap"

    private const val MAX_SECTION_NAME_LENGTH = 127

    fun requestLabel(stage: String, request: FrameRequest): String = label(
        stage = stage,
        token = request.token,
        frameIndex = request.requestedFrameIndex,
        ptsUs = request.expectedKey.ptsUs,
    )

    fun navigationInputLabel(
        request: FrameRequest,
        navigationMode: String,
        stride: Int?,
        displayedFrameIndex: Int?,
    ): String = (
        "$NAVIGATION_INPUT f=${request.token.fileGeneration} r=${request.token.requestGeneration} " +
            "m=$navigationMode s=${stride ?: 0} i=${request.requestedFrameIndex} " +
            "d=${displayedFrameIndex ?: -1} p=${request.expectedKey.ptsUs}"
        ).take(MAX_SECTION_NAME_LENGTH)

    fun frameLabel(
        stage: String,
        token: GenerationToken,
        key: FrameKey,
    ): String = label(stage, token, key.displayFrameIndex, key.ptsUs)

    fun frameLabel(
        stage: String,
        fileGeneration: Long,
        key: FrameKey,
    ): String = "$stage f=$fileGeneration i=${key.displayFrameIndex} p=${key.ptsUs}"
        .take(MAX_SECTION_NAME_LENGTH)

    private fun label(
        stage: String,
        token: GenerationToken,
        frameIndex: Int,
        ptsUs: Long,
    ): String = "$stage f=${token.fileGeneration} r=${token.requestGeneration} i=$frameIndex p=$ptsUs"
        .take(MAX_SECTION_NAME_LENGTH)

    fun <T> section(label: String, block: () -> T): T {
        val started = runCatching {
            Trace.beginSection(label.take(MAX_SECTION_NAME_LENGTH))
            true
        }.getOrDefault(false)
        return try {
            block()
        } finally {
            if (started) runCatching(Trace::endSection)
        }
    }
}
