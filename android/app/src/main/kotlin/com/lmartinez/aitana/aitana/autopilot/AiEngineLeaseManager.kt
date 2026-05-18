package com.lmartinez.aitana.aitana.autopilot

import android.content.Context
import android.util.Log
import java.io.Closeable
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException

object AiEngineLeaseManager {
    private const val TAG = "AiEngineLease"
    private const val LOCK_FILE_NAME = "aitana_ai_engine.lock"
    private const val DEFAULT_POLL_MS = 100L

    class Lease internal constructor(
        private val appContext: Context,
        val owner: AutoPilotStateStore.EngineOwner,
        private val lockFile: File,
        private val randomAccessFile: RandomAccessFile,
        private val channel: FileChannel,
        private val lock: FileLock
    ) : Closeable {
        @Volatile
        private var closed = false

        val isValid: Boolean
            get() = !closed && lock.isValid

        fun heartbeat() {
            if (isValid) {
                AutoPilotStateStore.heartbeatEngineOwner(appContext, owner)
            }
        }

        override fun close() {
            if (closed) return
            closed = true

            try {
                if (lock.isValid) lock.release()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to release file lock for ${owner.value}: ${e.message}")
            }

            try {
                channel.close()
            } catch (_: Exception) {
            }

            try {
                randomAccessFile.close()
            } catch (_: Exception) {
            }

            AutoPilotStateStore.clearEngineOwner(appContext, owner)
            Log.i(TAG, "Released AI engine lease for ${owner.value}: ${lockFile.name}")
        }
    }

    fun acquire(
        context: Context,
        owner: AutoPilotStateStore.EngineOwner
    ): Lease? {
        val appContext = context.applicationContext
        val lockFile = File(appContext.filesDir, LOCK_FILE_NAME)
        lockFile.parentFile?.mkdirs()

        val randomAccessFile = RandomAccessFile(lockFile, "rw")
        val channel = randomAccessFile.channel
        val lock = try {
            channel.tryLock()
        } catch (_: OverlappingFileLockException) {
            null
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire AI engine lock for ${owner.value}: ${e.message}")
            null
        }

        if (lock == null) {
            try {
                channel.close()
            } catch (_: Exception) {
            }
            try {
                randomAccessFile.close()
            } catch (_: Exception) {
            }
            return null
        }

        randomAccessFile.setLength(0)
        randomAccessFile.write(
            "owner=${owner.value}\nsince=${System.currentTimeMillis()}\n".toByteArray()
        )
        randomAccessFile.fd.sync()

        AutoPilotStateStore.markEngineOwner(appContext, owner)
        Log.i(TAG, "Acquired AI engine lease for ${owner.value}: ${lockFile.name}")
        return Lease(appContext, owner, lockFile, randomAccessFile, channel, lock)
    }

    fun acquireBlocking(
        context: Context,
        owner: AutoPilotStateStore.EngineOwner,
        timeoutMs: Long
    ): Lease? {
        val deadline = if (timeoutMs <= 0L) {
            System.currentTimeMillis()
        } else {
            System.currentTimeMillis() + timeoutMs
        }

        do {
            acquire(context, owner)?.let { return it }
            if (timeoutMs <= 0L) return null
            Thread.sleep(DEFAULT_POLL_MS)
        } while (System.currentTimeMillis() < deadline)

        return null
    }
}
