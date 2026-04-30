package com.lmartinez.aitana.aitana

import android.content.Context
import android.content.Intent

object GeofenceUtils {
    fun isAlreadyTriggered(context: Context, geofenceId: String): Boolean {
        val prefs = context.getSharedPreferences("geofence_idempotency", Context.MODE_PRIVATE)
        return prefs.getStringSet("triggered_ids", emptySet())!!.contains(geofenceId)
    }

    fun markAsTriggered(context: Context, geofenceId: String) {
        val prefs = context.getSharedPreferences("geofence_idempotency", Context.MODE_PRIVATE)
        val existing = prefs.getStringSet("triggered_ids", emptySet())!!.toMutableSet()
        existing.add(geofenceId)
        prefs.edit().putStringSet("triggered_ids", existing).apply()
    }

    fun clearTriggeredStateAndSniperMap(context: Context, geofenceId: String) {
        // Clear idempotency
        val idemPrefs = context.getSharedPreferences("geofence_idempotency", Context.MODE_PRIVATE)
        val existing = idemPrefs.getStringSet("triggered_ids", emptySet())!!.toMutableSet()
        existing.remove(geofenceId)
        idemPrefs.edit().putStringSet("triggered_ids", existing).apply()

        // Clear title
        val titlePrefs = context.getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
        titlePrefs.edit().remove(geofenceId).apply()

        // Clear sniper map
        val sniperPrefs = context.getSharedPreferences("wifi_sniper_map", Context.MODE_PRIVATE)
        val toRemove = sniperPrefs.all.filter { it.value == geofenceId }.keys
        if (toRemove.isNotEmpty()) {
            val editor = sniperPrefs.edit()
            toRemove.forEach { editor.remove(it) }
            editor.apply()
        }
    }

    fun fireSyntheticTrigger(context: Context, geofenceId: String) {
        if (!isAlreadyTriggered(context, geofenceId)) {
            markAsTriggered(context, geofenceId)
            val intent = Intent(GeofenceBroadcastReceiver.ACTION_GEOFENCE_TRIGGERED).apply {
                setPackage(context.packageName)
                putExtra(GeofenceBroadcastReceiver.EXTRA_GEOFENCE_ID, geofenceId)
            }
            context.sendBroadcast(intent)
            
            val titlePrefs = context.getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
            val taskTitle = titlePrefs.getString(geofenceId, geofenceId)

            // Note: Since this bypasses GeofenceBroadcastReceiver's onReceive, 
            // we should also fire the notification here.
            GeofenceBroadcastReceiver.sendNotification(
                context = context,
                title = "Aitana dice: ¡Ya llegaste, wey! (Wi-Fi)",
                message = "No se te vaya a olvidar: $taskTitle",
                geofenceId = geofenceId
            )
        }
    }
}
