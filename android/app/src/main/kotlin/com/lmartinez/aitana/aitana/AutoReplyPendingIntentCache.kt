package com.lmartinez.aitana.aitana

import android.app.PendingIntent
import android.app.RemoteInput
import android.os.SystemClock
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

object AutoReplyPendingIntentCache {
    private const val TTL_MS = 90_000L
    private val idCounter = AtomicLong(0)
    private val entries = ConcurrentHashMap<String, Entry>()

    data class Entry(
        val requestId: String,
        val pendingIntent: PendingIntent,
        val remoteInputs: Array<RemoteInput>,
        val notificationKey: String,
        val sender: String,
        val message: String,
        val packageName: String,
        val createdAtElapsedMs: Long = SystemClock.elapsedRealtime()
    ) {
        fun isExpired(nowElapsedMs: Long = SystemClock.elapsedRealtime()): Boolean =
            nowElapsedMs - createdAtElapsedMs > TTL_MS
    }

    fun createRequestId(): String =
        "wa-${System.currentTimeMillis()}-${idCounter.incrementAndGet()}"

    fun put(entry: Entry) {
        purgeExpired()
        entries[entry.requestId] = entry
    }

    fun take(requestId: String): Entry? {
        purgeExpired()
        val entry = entries.remove(requestId) ?: return null
        return entry.takeUnless { it.isExpired() }
    }

    fun remove(requestId: String) {
        entries.remove(requestId)
    }

    fun removeByNotificationKey(notificationKey: String) {
        entries.entries.removeIf { it.value.notificationKey == notificationKey }
    }

    fun expireIfStale(requestId: String) {
        val entry = entries[requestId] ?: return
        if (entry.isExpired()) entries.remove(requestId, entry)
    }

    fun purgeExpired() {
        val now = SystemClock.elapsedRealtime()
        entries.entries.removeIf { it.value.isExpired(now) }
    }
}
