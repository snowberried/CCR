package com.snowberried.ctcinereviewer.media

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

internal enum class CachedNavigationSource {
    BACKWARD_HISTORY,
    REVERSE_WINDOW,
}

internal enum class CachedNavigationMissReason {
    NOT_CACHED,
    SOURCE_NOT_ALLOWED,
    FRAME_KEY_MISMATCH,
    QUEUE_REJECTED,
}

/** Immutable generations and the full exact key captured at request acceptance. */
internal data class CachedNavigationInput(
    val request: FrameRequest,
    val surfaceGeneration: Long,
    val gestureGeneration: Long,
    val signedStride: Int,
    val allowedSources: Set<CachedNavigationSource>,
) {
    init {
        require(request.requestedFrameIndex == request.expectedKey.displayFrameIndex)
        require(surfaceGeneration >= 0)
        require(gestureGeneration >= 0)
        require(signedStride == -1 || signedStride == -5)
        require(allowedSources.isNotEmpty())
    }
}

internal sealed interface CachedNavigationOutcome {
    val input: CachedNavigationInput

    data class Published(
        override val input: CachedNavigationInput,
        val event: PublicationEvent,
        val source: CachedNavigationSource,
        val imageProbe: FrameImageProbe?,
    ) : CachedNavigationOutcome

    data class Miss(
        override val input: CachedNavigationInput,
        val reason: CachedNavigationMissReason,
    ) : CachedNavigationOutcome

    data class Stale(
        override val input: CachedNavigationInput,
        val code: String,
        val event: PublicationEvent? = null,
    ) : CachedNavigationOutcome

    data class Error(
        override val input: CachedNavigationInput,
        val code: String,
        val event: PublicationEvent? = null,
    ) : CachedNavigationOutcome
}

internal typealias CachedNavigationContextCheck = (CachedNavigationInput) -> Boolean
internal typealias CachedNavigationCompletion = (CachedNavigationOutcome) -> Unit
internal typealias CachedNavigationEnqueue = (
    CachedNavigationInput,
    CachedNavigationContextCheck,
    CachedNavigationCompletion,
) -> Boolean

/**
 * Routes an accepted request exactly once. A cache miss keeps the original FrameRequest for the
 * media-actor fallback; stale and render errors are terminal and must not be hidden by a decode.
 */
internal class CachedNavigationPublisher(
    private val enqueue: CachedNavigationEnqueue,
) {
    fun submit(
        input: CachedNavigationInput,
        contextCurrent: CachedNavigationContextCheck,
        onPublished: (CachedNavigationOutcome.Published) -> Unit,
        onFallback: (CachedNavigationOutcome.Miss) -> Unit,
        onTerminal: (CachedNavigationOutcome) -> Unit,
    ) {
        val routed = AtomicBoolean(false)
        val route: CachedNavigationCompletion = { outcome ->
            if (routed.compareAndSet(false, true)) {
                when (outcome) {
                    is CachedNavigationOutcome.Published -> onPublished(outcome)
                    is CachedNavigationOutcome.Miss -> onFallback(outcome)
                    is CachedNavigationOutcome.Stale,
                    is CachedNavigationOutcome.Error -> onTerminal(outcome)
                }
            }
        }
        val queued = runCatching { enqueue(input, contextCurrent, route) }.getOrDefault(false)
        if (!queued) route(CachedNavigationOutcome.Miss(input, CachedNavigationMissReason.QUEUE_REJECTED))
    }
}

/** Tracks queued EGL commands so begin-file/close can complete callbacks before removing posts. */
internal class CachedNavigationPendingRegistry {
    internal class Ticket(
        val input: CachedNavigationInput,
        private val completion: CachedNavigationCompletion,
    ) {
        private val completed = AtomicBoolean(false)

        fun complete(outcome: CachedNavigationOutcome): Boolean {
            require(outcome.input == input)
            if (!completed.compareAndSet(false, true)) return false
            runCatching { completion(outcome) }
            return true
        }
    }

    private val pending = ConcurrentHashMap.newKeySet<Ticket>()

    fun register(input: CachedNavigationInput, completion: CachedNavigationCompletion): Ticket =
        Ticket(input, completion).also(pending::add)

    fun complete(ticket: Ticket, outcome: CachedNavigationOutcome): Boolean =
        ticket.complete(outcome).also { completed ->
            if (completed) pending.remove(ticket)
        }

    fun completeAll(outcome: (CachedNavigationInput) -> CachedNavigationOutcome) {
        pending.toList().forEach { ticket -> complete(ticket, outcome(ticket.input)) }
    }

    fun isPending(ticket: Ticket): Boolean = ticket in pending

    val size: Int get() = pending.size
}
