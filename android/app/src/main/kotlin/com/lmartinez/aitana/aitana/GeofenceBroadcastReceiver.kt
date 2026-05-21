package com.lmartinez.aitana.aitana

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingEvent

/**
 * Silent sentinel that listens for Geofence transitions (ENTER/EXIT/DWELL) triggered by
 * Google Play Services. It also intercepts the manual "dismiss" action from the notification.
 */
class GeofenceBroadcastReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_DISMISS_GEOFENCE   = "com.lmartinez.aitana.ACTION_DISMISS_GEOFENCE"
        const val ACTION_GEOFENCE_TRIGGERED = "com.lmartinez.aitana.ACTION_GEOFENCE_TRIGGERED"
        const val ACTION_GEOFENCE_CLEARED   = "com.lmartinez.aitana.ACTION_GEOFENCE_CLEARED"
        const val EXTRA_GEOFENCE_ID         = "GEOFENCE_ID"
        const val EXTRA_NOTIF_ID            = "NOTIF_ID"

        /**
         * Constructs and displays a high-priority notification with an Action Button.
         */
        fun sendNotification(context: Context, title: String, message: String, geofenceId: String) {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channelId = "aitana_geofence_alerts"

            val notificationId = geofenceId.hashCode()

            val channel = NotificationChannel(
                channelId,
                "Lady AI.tana Location Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alerts triggered when arriving at specific locations."
                enableVibration(true)
            }
            notificationManager.createNotificationChannel(channel)

            val dismissIntent = Intent(context, GeofenceBroadcastReceiver::class.java).apply {
                action = ACTION_DISMISS_GEOFENCE
                putExtra(EXTRA_GEOFENCE_ID, geofenceId)
                putExtra(EXTRA_NOTIF_ID, notificationId)
            }
            val dismissPendingIntent = PendingIntent.getBroadcast(
                context,
                notificationId,
                dismissIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notificationBuilder = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(android.R.drawable.ic_dialog_map)
                .setContentTitle(title)
                .setContentText(message)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setDefaults(Notification.DEFAULT_ALL)
                .setAutoCancel(true)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel, 
                    "¡Ya, alv!", 
                    dismissPendingIntent
                )

            notificationManager.notify(notificationId, notificationBuilder.build())
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d("GeofenceReceiver", "🔥 =========================================")
        Log.d("GeofenceReceiver", "🔥 WAKE UP! onReceive disparado en background!")
        Log.d("GeofenceReceiver", "🔥 Action del Intent: ${intent.action}")
        Log.d("GeofenceReceiver", "🔥 =========================================")
        
        if (intent.action == ACTION_DISMISS_GEOFENCE) {
            val geofenceId = intent.getStringExtra(EXTRA_GEOFENCE_ID) ?: return
            val notifId = intent.getIntExtra(EXTRA_NOTIF_ID, 0)
            
            Log.d("GeofenceReceiver", "🔘 Botón presionado. Borrando: $geofenceId")
            
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(notifId)
            
            GeofenceUtils.removeGeofence(context, geofenceId)
            return
        }

        val geofencingEvent = GeofencingEvent.fromIntent(intent)

        if (geofencingEvent == null) {
            Log.e("GeofenceReceiver", "GeofencingEvent is null.")
            return
        }

        if (geofencingEvent.hasError()) {
            val errorMessage = GeofenceStatusCodes.getStatusCodeString(geofencingEvent.errorCode)
            Log.e("GeofenceReceiver", "Geofence Error: $errorMessage")
            return
        }

        when (val geofenceTransition = geofencingEvent.geofenceTransition) {
            
            Geofence.GEOFENCE_TRANSITION_ENTER -> {
                geofencingEvent.triggeringGeofences?.forEach { geofence ->
                    if (!GeofenceUtils.isAlreadyTriggered(context, geofence.requestId)) {
                        GeofenceUtils.markAsTriggered(context, geofence.requestId)
                        
                        val titlePrefs = context.getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
                        val taskTitle = titlePrefs.getString(geofence.requestId, geofence.requestId)
                        
                        Log.d("GeofenceReceiver", "🎯 GEOFENCE ENTERED! ID: ${geofence.requestId}")
                        sendNotification(
                            context = context,
                            title = "¡Ya llegaste wey!",
                            message = "Pendiente: $taskTitle",
                            geofenceId = geofence.requestId
                        )
                        val triggeredIntent = Intent(ACTION_GEOFENCE_TRIGGERED).apply {
                            setPackage(context.packageName)
                            putExtra(EXTRA_GEOFENCE_ID, geofence.requestId)
                        }
                        context.sendBroadcast(triggeredIntent)
                    } else {
                        Log.d("GeofenceReceiver", "🚫 GEOFENCE ENTERED but already triggered (Idempotency Guard). ID: ${geofence.requestId}")
                    }
                }
            }
            
            Geofence.GEOFENCE_TRANSITION_DWELL -> {
                geofencingEvent.triggeringGeofences?.forEach { geofence ->
                    if (!GeofenceUtils.isAlreadyTriggered(context, geofence.requestId)) {
                        GeofenceUtils.markAsTriggered(context, geofence.requestId)
                        
                        val titlePrefs = context.getSharedPreferences("geofence_titles", Context.MODE_PRIVATE)
                        val taskTitle = titlePrefs.getString(geofence.requestId, geofence.requestId)
                        
                        Log.d("GeofenceReceiver", "⏳ GEOFENCE DWELL (5 mins)! ID: ${geofence.requestId}")
                        sendNotification(
                            context = context,
                            title = "Hey, pendejo!",
                            message = "¿Ya hiciste esto?: $taskTitle",
                            geofenceId = geofence.requestId
                        )
                        val triggeredIntent = Intent(ACTION_GEOFENCE_TRIGGERED).apply {
                            setPackage(context.packageName)
                            putExtra(EXTRA_GEOFENCE_ID, geofence.requestId)
                        }
                        context.sendBroadcast(triggeredIntent)
                    } else {
                        Log.d("GeofenceReceiver", "🚫 GEOFENCE DWELL but already triggered (Idempotency Guard). ID: ${geofence.requestId}")
                    }
                }
            }

            Geofence.GEOFENCE_TRANSITION_EXIT -> {
                geofencingEvent.triggeringGeofences?.forEach { geofence ->
                    Log.d("GeofenceReceiver", "👋 GEOFENCE EXITED. Auto-destrucción iniciada.")
                    GeofenceUtils.removeGeofence(context, geofence.requestId)
                }
            }
            
            else -> {
                Log.e("GeofenceReceiver", "Invalid transition type: $geofenceTransition")
            }
        }
    }
}