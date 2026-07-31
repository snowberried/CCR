package com.snowberried.ctcinereviewer

import android.app.Application
import android.os.StrictMode
import android.os.strictmode.DiskReadViolation
import android.os.strictmode.DiskWriteViolation
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

class DebugApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        StrictMode.setThreadPolicy(
            StrictMode.ThreadPolicy.Builder()
                .detectDiskReads()
                .detectDiskWrites()
                .penaltyListener(STRICT_MODE_EXECUTOR, StrictModeDiagnostics::record)
                .build(),
        )
    }

    private companion object {
        val STRICT_MODE_EXECUTOR = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "ccr-strict-mode").apply { isDaemon = true }
        }
    }
}

internal object StrictModeDiagnostics {
    private val diskReads = AtomicLong()
    private val diskWrites = AtomicLong()

    fun record(violation: Throwable) {
        val code = when (violation) {
            is DiskReadViolation -> {
                diskReads.incrementAndGet()
                "MAIN_DISK_READ"
            }
            is DiskWriteViolation -> {
                diskWrites.incrementAndGet()
                "MAIN_DISK_WRITE"
            }
            else -> "MAIN_POLICY_VIOLATION"
        }
        Log.w("CcrStrictMode", code)
    }

    fun snapshot(): Snapshot = Snapshot(diskReads.get(), diskWrites.get())

    data class Snapshot(val diskReadCount: Long, val diskWriteCount: Long)
}
