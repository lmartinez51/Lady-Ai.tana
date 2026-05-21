package com.lmartinez.aitana.aitana

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.util.Log
import com.google.android.gms.location.LocationServices

object GeofenceUtils {
    fun normalizeSsid(rawSsid: String?): String? {
        val cleanSsid = rawSsid
            ?.removeSurrounding("\"")
            ?.trim()
            ?: return null

        if (cleanSsid.isEmpty() || cleanSsid.equals("<unknown ssid>", ignoreCase = true)) {
            return null
        }

        return cleanSsid.lowercase()
    }

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

    fun isWifiConnected(context: Context): Boolean {
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        } catch (e: Exception) {
            return false
        }
    }

    fun getCurrentWifiSsid(context: Context): String? {
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
            val network = cm.activeNetwork ?: return null
            val caps = cm.getNetworkCapabilities(network) ?: return null
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null
            val wifiInfo = caps.transportInfo as? WifiInfo ?: return null
            return normalizeSsid(wifiInfo.ssid)
        } catch (e: Exception) {
            Log.e("GeofenceUtils", "Error retrieving current Wi-Fi SSID: ${e.message}")
            return null
        }
    }

    fun clearTriggeredStateAndSniperMap(context: Context, geofenceId: String, force: Boolean = false) {
        val currentSsid = getCurrentWifiSsid(context)
        val wifiActive = isWifiConnected(context)
        val sniperPrefs = context.getSharedPreferences("wifi_sniper_map", Context.MODE_PRIVATE)

        val associatedSsids = sniperPrefs.all.filter { it.value == geofenceId }.keys
        val keepLock = !force && wifiActive && currentSsid != null && associatedSsids.contains(currentSsid)

        if (keepLock && associatedSsids.isNotEmpty()) {
            val titlePrefs = context.getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
            titlePrefs.edit().remove(geofenceId).apply()

            val editor = sniperPrefs.edit()
            associatedSsids.forEach { ssid ->
                if (ssid != currentSsid) {
                    editor.remove(ssid)
                }
            }
            editor.apply()

            Log.i("GeofenceUtils", "Wi-Fi SSID cooldown lock active for $geofenceId. Cleanup postponed.")
        } else {
            val idemPrefs = context.getSharedPreferences("geofence_idempotency", Context.MODE_PRIVATE)
            val existing = idemPrefs.getStringSet("triggered_ids", emptySet())!!.toMutableSet()
            existing.remove(geofenceId)
            idemPrefs.edit().putStringSet("triggered_ids", existing).apply()

            val titlePrefs = context.getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
            titlePrefs.edit().remove(geofenceId).apply()

            if (associatedSsids.isNotEmpty()) {
                val editor = sniperPrefs.edit()
                associatedSsids.forEach { editor.remove(it) }
                editor.apply()
            }
            Log.i("GeofenceUtils", "Geofence $geofenceId cleared immediately.")
        }
    }

    fun removeGeofence(context: Context, geofenceId: String, force: Boolean = false) {
        clearTriggeredStateAndSniperMap(context, geofenceId, force)

        val clearedIntent = Intent(GeofenceBroadcastReceiver.ACTION_GEOFENCE_CLEARED).apply {
            setPackage(context.packageName)
            putExtra(GeofenceBroadcastReceiver.EXTRA_GEOFENCE_ID, geofenceId)
        }
        context.sendBroadcast(clearedIntent)

        try {
            val geofencingClient = LocationServices.getGeofencingClient(context)
            geofencingClient.removeGeofences(listOf(geofenceId)).run {
                addOnSuccessListener {
                    Log.d("GeofenceUtils", "Native geofence '$geofenceId' removed from Android.")
                }
                addOnFailureListener { exception ->
                    Log.e("GeofenceUtils", "Failed to remove geofence: ${exception.message}")
                }
            }
        } catch (e: SecurityException) {
            Log.e("GeofenceUtils", "Security Exception during removal: ${e.message}")
        } catch (e: Exception) {
            Log.e("GeofenceUtils", "Error removing geofence: ${e.message}")
        }
    }

    fun reconcileWifiSniper(context: Context, currentSsid: String?, force: Boolean = false) {
        val sniperPrefs = context.getSharedPreferences("wifi_sniper_map", Context.MODE_PRIVATE)
        if (sniperPrefs.all.isEmpty()) return

        val normalizedSsid = normalizeSsid(currentSsid)
        if (normalizedSsid == null) {
            Log.d("GeofenceUtils", "Wi-Fi SSID is unknown. No targeted sniper binding to reconcile.")
            return
        }

        val geofenceId = sniperPrefs.getString(normalizedSsid, null) ?: return

        if (force) {
            Log.i("GeofenceUtils", "Left Wi-Fi zone for geofence: $geofenceId. Triggering targeted exit cleanup.")
            removeGeofence(context, geofenceId, force = true)
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

            GeofenceBroadcastReceiver.sendNotification(
                context = context,
                title = "Aitana dice: Ya llegaste, wey! (Wi-Fi)",
                message = "No se te vaya a olvidar: $taskTitle",
                geofenceId = geofenceId
            )
        }
    }
}
