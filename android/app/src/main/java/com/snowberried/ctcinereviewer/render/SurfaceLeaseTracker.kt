package com.snowberried.ctcinereviewer.render

internal class SurfaceLeaseTracker {
    private var activeLeaseId: Long? = null

    fun attach(leaseId: Long): Boolean {
        val active = activeLeaseId
        if (active != null && leaseId < active) return false
        activeLeaseId = leaseId
        return true
    }

    fun detach(leaseId: Long): Boolean {
        if (leaseId != activeLeaseId) return false
        activeLeaseId = null
        return true
    }

    fun isActive(leaseId: Long): Boolean = leaseId == activeLeaseId
}
