package com.snowberried.ctcinereviewer.media

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

class PublicationGate {
    private val lock = ReentrantLock()
    private var fileGeneration = 0L
    private var requestGeneration = 0L

    fun beginFile(): GenerationToken = lock.withLock {
        fileGeneration += 1
        requestGeneration += 1
        GenerationToken(fileGeneration, requestGeneration)
    }

    fun beginRequest(expectedFileGeneration: Long): GenerationToken? = lock.withLock {
        if (fileGeneration != expectedFileGeneration) return null
        requestGeneration += 1
        GenerationToken(fileGeneration, requestGeneration)
    }

    fun invalidateRequest(): GenerationToken = lock.withLock {
        requestGeneration += 1
        GenerationToken(fileGeneration, requestGeneration)
    }

    fun isCurrent(token: GenerationToken): Boolean = lock.withLock {
        token.fileGeneration == fileGeneration && token.requestGeneration == requestGeneration
    }

    fun publishIfCurrent(token: GenerationToken, publish: () -> Boolean): Boolean = lock.withLock {
        if (token.fileGeneration != fileGeneration || token.requestGeneration != requestGeneration) return false
        publish()
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
