package com.snowberried.ctcinereviewer.render

import com.snowberried.ctcinereviewer.media.FrameKey
import com.snowberried.ctcinereviewer.media.FrameRequest
import com.snowberried.ctcinereviewer.media.GenerationToken
import org.junit.Assert.assertEquals
import org.junit.Test

class CacheOnlyTargetContractTest {
    @Test
    fun `product cache-only completion never enters window draw or publication`() {
        var cacheCompletions = 0
        var publications = 0

        completeCachedTextureTarget(
            publicationRequest = null,
            onCacheOnly = { cacheCompletions += 1 },
            onPublish = { publications += 1 },
        )

        assertEquals(1, cacheCompletions)
        assertEquals(0, publications)
    }

    @Test
    fun `publication target enters only the publication branch`() {
        val request = FrameRequest(GenerationToken(1, 2), 3, FrameKey(3, 4_000, 0))
        var cacheCompletions = 0
        var publishedRequest: FrameRequest? = null

        completeCachedTextureTarget(
            publicationRequest = request,
            onCacheOnly = { cacheCompletions += 1 },
            onPublish = { publishedRequest = it },
        )

        assertEquals(0, cacheCompletions)
        assertEquals(request, publishedRequest)
    }
}
