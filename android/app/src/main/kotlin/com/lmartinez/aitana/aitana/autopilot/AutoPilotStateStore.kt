package com.lmartinez.aitana.aitana.autopilot

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.service.quicksettings.TileService
import android.util.Log

object AutoPilotStateStore {
    private const val TAG = "AutoPilotStateStore"

    const val ACTION_AUTOPILOT_STATE_CHANGED =
        "com.lmartinez.aitana.aitana.autopilot.ACTION_STATE_CHANGED"

    private const val PREFS_NAME = "aitana_native_state"
    private const val KEY_USER_ENABLED = "auto_pilot_user_enabled"
    private const val KEY_FLUTTER_FOREGROUND = "flutter_foreground"
    private const val KEY_ENGINE_OWNER = "engine_owner"
    private const val KEY_OWNER_SINCE_MS = "owner_since_ms"
    private const val KEY_OWNER_HEARTBEAT_MS = "owner_heartbeat_ms"

    enum class EngineOwner(val value: String) {
        NONE("none"),
        FLUTTER("flutter"),
        AUTOPILOT("autopilot")
    }

    fun isUserEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_USER_ENABLED, false)

    fun setUserEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit()
            .putBoolean(KEY_USER_ENABLED, enabled)
            .commit()
    }

    // Best-effort UI telemetry only. This value can be stale after a force-stop or
    // swipe-to-kill, so it must never be used as an AI-engine ownership gate.
    fun isFlutterForeground(context: Context): Boolean =
        prefs(context).getBoolean(KEY_FLUTTER_FOREGROUND, false)

    // Best-effort UI telemetry only. The native file lock in AiEngineLeaseManager is
    // the only process-death-safe authority for engine exclusivity.
    fun setFlutterForeground(context: Context, foreground: Boolean) {
        prefs(context).edit()
            .putBoolean(KEY_FLUTTER_FOREGROUND, foreground)
            .commit()
    }

    fun engineOwner(context: Context): EngineOwner {
        val raw = prefs(context).getString(KEY_ENGINE_OWNER, EngineOwner.NONE.value)
        return EngineOwner.values().firstOrNull { it.value == raw } ?: EngineOwner.NONE
    }

    fun markEngineOwner(context: Context, owner: EngineOwner) {
        val now = System.currentTimeMillis()
        prefs(context).edit()
            .putString(KEY_ENGINE_OWNER, owner.value)
            .putLong(KEY_OWNER_SINCE_MS, now)
            .putLong(KEY_OWNER_HEARTBEAT_MS, now)
            .commit()
    }

    fun heartbeatEngineOwner(context: Context, owner: EngineOwner) {
        if (engineOwner(context) != owner) return
        prefs(context).edit()
            .putLong(KEY_OWNER_HEARTBEAT_MS, System.currentTimeMillis())
            .commit()
    }

    fun clearEngineOwner(context: Context, owner: EngineOwner) {
        if (engineOwner(context) != owner) return
        prefs(context).edit()
            .putString(KEY_ENGINE_OWNER, EngineOwner.NONE.value)
            .remove(KEY_OWNER_SINCE_MS)
            .remove(KEY_OWNER_HEARTBEAT_MS)
            .commit()
    }

    // "Armed" means the user tile is enabled. Flutter/background exclusivity is
    // enforced exclusively by the OS-backed file lock, not by persisted booleans.
    fun isAutoPilotEffectivelyArmed(context: Context): Boolean =
        isUserEnabled(context)

    fun broadcastStateChanged(context: Context) {
        val appContext = context.applicationContext
        val intent = Intent(ACTION_AUTOPILOT_STATE_CHANGED)
            .setPackage(appContext.packageName)
        appContext.sendBroadcast(intent)

        try {
            TileService.requestListeningState(
                appContext,
                ComponentName(appContext, AutoPilotTileService::class.java)
            )
        } catch (e: Exception) {
            Log.d(TAG, "Quick Settings tile refresh request ignored: ${e.message}")
        }
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}
