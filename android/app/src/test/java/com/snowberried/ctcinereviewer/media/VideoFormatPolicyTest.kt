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

    @Test
    fun `decoded output rejects invalid crop HDR and P010 independently`() {
        val output = DecodedOutputMetadata(
            width = 1920,
            height = 1080,
            cropLeft = 0,
            cropTop = 0,
            cropRight = 1919,
            cropBottom = 1079,
            colorStandard = MediaFormat.COLOR_STANDARD_BT709,
            colorRange = MediaFormat.COLOR_RANGE_LIMITED,
            colorTransfer = MediaFormat.COLOR_TRANSFER_SDR_VIDEO,
            mime = "video/raw",
            profile = null,
            colorFormat = null,
            hdrStaticInfoPresent = false,
        )
        assertEquals(
            VideoSupport.Supported,
            classifyDecodedOutputFormat(
                output,
                VideoFormatDescriptor("video/hevc", true, 8, false, false),
            ),
        )
        assertEquals(
            VideoSupport.Unsupported("OUTPUT_FORMAT_UNSUPPORTED"),
            classifyDecodedOutputFormat(
                output.copy(cropRight = 1920),
                VideoFormatDescriptor("video/hevc", true, 8, false, false),
            ),
        )
        assertEquals(
            10,
            androidDecodedVideoBitDepth(
                MediaFormat.MIMETYPE_VIDEO_HEVC,
                MediaCodecInfo.CodecProfileLevel.HEVCProfileMain,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUVP010,
            ),
        )
        assertTrue(
            classifyDecodedOutputFormat(
                output.copy(colorTransfer = MediaFormat.COLOR_TRANSFER_ST2084),
                VideoFormatDescriptor("video/hevc", true, 8, true, false),
            ) is VideoSupport.Unsupported,
        )
        assertEquals(
            false,
            androidDecodedOutputIsHdr(MediaFormat.COLOR_TRANSFER_SDR_VIDEO, hdrStaticInfoPresent = true),
        )
        assertEquals(true, androidDecodedOutputIsHdr(null, hdrStaticInfoPresent = true))
        assertEquals(
            true,
            androidDecodedOutputIsHdr(MediaFormat.COLOR_TRANSFER_HLG, hdrStaticInfoPresent = false),
        )
    }
}
