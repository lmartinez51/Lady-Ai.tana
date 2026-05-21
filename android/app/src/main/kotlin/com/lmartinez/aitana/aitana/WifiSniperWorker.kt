package com.lmartinez.aitana.aitana

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.ListenableWorker

class WifiSniperWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    override fun doWork(): ListenableWorker.Result {
        val appContext = applicationContext
        val prefs = appContext.getSharedPreferences("wifi_sniper_map", Context.MODE_PRIVATE)
        
        // If no geofences with Wi-Fi exist, fast return
        if (prefs.all.isEmpty()) return ListenableWorker.Result.success()

        // 1. Get current connected SSID and reconcile sniper states
        val currentSsid = GeofenceUtils.getCurrentWifiSsid(appContext)
        GeofenceUtils.reconcileWifiSniper(appContext, currentSsid)

        // 2. Check for synthetic trigger match
        if (currentSsid != null) {
            val geofenceId = prefs.getString(currentSsid, null)
            if (geofenceId != null) {
                Log.i("WifiSniperWorker", "🎯 SSID match in worker! Checking idempotency for: $geofenceId")
                GeofenceUtils.fireSyntheticTrigger(appContext, geofenceId)
            }
        }
        
        return ListenableWorker.Result.success()
    }
}
