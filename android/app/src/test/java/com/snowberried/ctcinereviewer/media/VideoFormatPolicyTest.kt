package com.snowberried.ctcinereviewer.media

import android.media.MediaCodecInfo
import android.media.MediaFormat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoFormatPolicyTest {
    @Test
    fun `allows only SDR 8-bit AVC and HEVC supported profiles`() {
        assertEquals(
            VideoSupport.Supported,
            classifyVideoFormat(VideoFormatDescriptor("video/avc", true, 8, false, false)),
        )
        assertEquals(
            VideoSupport.Supported,
            classifyVideoFormat(VideoFormatDescriptor("video/hevc", true, 8, false, false)),
        )
        val unsupported = listOf(
            VideoFormatDescriptor("video/hevc", true, 10, false, false),
            VideoFormatDescriptor("video/hevc", true, 8, true, false),
            VideoFormatDescriptor("video/dolby-vision", true, 8, false, true),
            VideoFormatDescriptor("video/av01", true, 8, false, false),
        ).map(::classifyVideoFormat)
        assertTrue(unsupported.all { it is VideoSupport.Unsupported })
    }

    @Test
    fun `AVC Main is not confused with HEVC Main10 profile value`() {
        assertEquals(
            8,
            androidVideoBitDepth(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                MediaCodecInfo.CodecProfileLevel.AVCProfileMain,
            ),
        )
        assertEquals(
            10,
            androidVideoBitDepth(
                MediaFormat.MIMETYPE_VIDEO_HEVC,
                MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10,
            ),
        )
    }
}
