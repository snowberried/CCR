package com.snowberried.ctcinereviewer.media

data class VideoFormatDescriptor(
    val mime: String,
    val profileSupported: Boolean,
    val bitDepth: Int,
    val hdr: Boolean,
    val dolbyVision: Boolean,
)

sealed interface VideoSupport {
    data object Supported : VideoSupport
    data class Unsupported(val reason: String) : VideoSupport
}

fun classifyVideoFormat(format: VideoFormatDescriptor): VideoSupport {
    if (format.dolbyVision) return VideoSupport.Unsupported("DOLBY_VISION_UNSUPPORTED")
    if (format.mime != "video/avc" && format.mime != "video/hevc") {
        return VideoSupport.Unsupported("CODEC_UNSUPPORTED")
    }
    if (!format.profileSupported || format.bitDepth != 8) {
        return VideoSupport.Unsupported("PROFILE_OR_BIT_DEPTH_UNSUPPORTED")
    }
    if (format.hdr) return VideoSupport.Unsupported("HDR_UNSUPPORTED")
    return VideoSupport.Supported
}
