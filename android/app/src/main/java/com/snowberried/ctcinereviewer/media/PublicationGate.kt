package com.snowberried.ctcinereviewer.media

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class PublicationGate(
    private val clockNanos: () -> Long = System::nanoTime,
    private val onPublicationEvent: (PublicationEvent) -> Unit = {},
) {
    private val lock = ReentrantLock()
    private var fileGeneration = 0L
    private var requestGeneration = 0L
    private var sequence = 0L
    private var stats = PublicationStats()

    fun beginFile(): GenerationToken = lock.withLock {
        fileGeneration += 1
        requestGeneration += 1
        sequence += 1
        GenerationToken(fileGeneration, requestGeneration)
    }

    fun acceptRequest(
        expectedFileGeneration: Long,
        requestedFrameIndex: Int,
        expectedKey: FrameKey,
    ): RequestAcceptance? = lock.withLock {
        if (fileGeneration != expectedFileGeneration) return null
        acceptLocked(requestedFrameIndex, expectedKey)
    }

    fun acceptInitialRequest(
        expectedToken: GenerationToken,
        requestedFrameIndex: Int,
        expectedKey: FrameKey,
    ): RequestAcceptance? = lock.withLock {
        if (fileGeneration != expectedToken.fileGeneration || requestGeneration != expectedToken.requestGeneration) {
            return null
        }
        acceptLocked(requestedFrameIndex, expectedKey)
    }

    private fun acceptLocked(
        requestedFrameIndex: Int,
        expectedKey: FrameKey,
    ): RequestAcceptance {
        requestGeneration += 1
        sequence += 1
        val request = FrameRequest(
            GenerationToken(fileGeneration, requestGeneration),
            requestedFrameIndex,
            expectedKey,
        )
        return RequestAcceptance(request, sequence, clockNanos())
    }

    fun invalidateRequest(): GenerationToken = lock.withLock {
        requestGeneration += 1
        sequence += 1
        GenerationToken(fileGeneration, requestGeneration)
    }

    fun isCurrent(token: GenerationToken): Boolean = lock.withLock {
        token.fileGeneration == fileGeneration && token.requestGeneration == requestGeneration
    }

    fun publish(
        request: FrameRequest,
        textureTimestampNs: Long,
        surfaceValid: () -> Boolean,
        swap: () -> Boolean,
    ): PublicationEvent {
        val event = lock.withLock {
            val currentFileGeneration = fileGeneration
            val currentRequestGeneration = requestGeneration
            val stale = request.token.fileGeneration != currentFileGeneration ||
                request.token.requestGeneration != currentRequestGeneration
            val surfaceIsValid = !stale && surfaceValid()
            val swapResult = if (surfaceIsValid) swap() else null
            val result = when {
                stale -> PublicationResult.STALE_BEFORE_SWAP
                !surfaceIsValid -> PublicationResult.SURFACE_INVALID
                swapResult == true -> PublicationResult.PUBLISHED
                else -> PublicationResult.SWAP_FAILED
            }
            sequence += 1
            PublicationEvent(
                eventSequence = sequence,
                elapsedRealtimeNanos = clockNanos(),
                fileGeneration = request.token.fileGeneration,
                requestGeneration = request.token.requestGeneration,
                requestedFrameIndex = request.requestedFrameIndex,
                expectedKey = request.expectedKey,
                currentFileGeneration = currentFileGeneration,
                currentRequestGeneration = currentRequestGeneration,
                textureTimestampNs = textureTimestampNs,
                swapAttempted = surfaceIsValid,
                eglSwapBuffersResult = swapResult,
                result = result,
            ).also(::record)
        }
        onPublicationEvent(event)
        return event
    }

    fun snapshotStats(): PublicationStats = lock.withLock { stats }

    private fun record(event: PublicationEvent) {
        stats = when (event.result) {
            PublicationResult.PUBLISHED -> stats.copy(publishedSwapCount = stats.publishedSwapCount + 1)
            PublicationResult.STALE_BEFORE_SWAP -> stats.copy(staleBeforeSwapCount = stats.staleBeforeSwapCount + 1)
            PublicationResult.SWAP_FAILED -> stats.copy(swapFailureCount = stats.swapFailureCount + 1)
            PublicationResult.SURFACE_INVALID -> stats.copy(surfaceInvalidCount = stats.surfaceInvalidCount + 1)
        }
        val violations = publicationInvariantViolationCount(listOf(event))
        if (violations != 0L) {
            stats = stats.copy(
                publicationInvariantViolationCount = stats.publicationInvariantViolationCount + violations,
            )
        }
    }
}

class LatestRequestSlot<T> {
    private val lock = Any()
    private var pending: T? = null

    fun offer(value: T) = synchronized(lock) {
        pending = value
    }

    fun take(): T? = synchronized(lock) {
        val value = pending
        pending = null
        value
    }

    fun clear() = synchronized(lock) {
        pending = null
    }
}
