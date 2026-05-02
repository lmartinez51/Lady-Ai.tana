package com.lmartinez.aitana.aitana

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

import androidx.work.ListenableWorker

class WifiSniperWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    override fun doWork(): ListenableWorker.Result {
        val appContext = applicationContext
        val prefs = applicationContext.getSharedPreferences("wifi_sniper_map", Context.MODE_PRIVATE)
        
        // If no geofences with Wi-Fi exist, fast return
        if (prefs.all.isEmpty()) return ListenableWorker.Result.success()

        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return ListenableWorker.Result.success()
        val caps = cm.getNetworkCapabilities(network) ?: return ListenableWorker.Result.success()
        
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return ListenableWorker.Result.success()
        
        val wifiInfo = caps.transportInfo as? WifiInfo ?: return ListenableWorker.Result.success()
        val connectedSsid = wifiInfo.ssid?.removeSurrounding("\"")?.lowercase() ?: return ListenableWorker.Result.success()

        val geofenceId = prefs.getString(connectedSsid, null) as? String
        if (geofenceId != null) {
            Log.i("WifiSniperWorker", "🎯 SSID match in worker! Checking idempotency for: $geofenceId")
            GeofenceUtils.fireSyntheticTrigger(appContext, geofenceId)
        }
        
        return ListenableWorker.Result.success()
    }
}
