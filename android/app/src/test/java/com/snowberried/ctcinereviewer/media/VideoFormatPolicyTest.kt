package com.snowberried.ctcinereviewer.media

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
}
