package com.lmartinez.aitana.aitana

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Parcelable
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.lmartinez.aitana.aitana.autopilot.AiEngineLeaseManager
import com.lmartinez.aitana.aitana.autopilot.AitanaConfig
import com.lmartinez.aitana.aitana.autopilot.AitanaConfigReader
import com.lmartinez.aitana.aitana.autopilot.AutoPilotReplySanitizer
import com.lmartinez.aitana.aitana.autopilot.AutoPilotStateStore
import com.lmartinez.aitana.aitana.autopilot.MiniAitanaLiteRtEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class AitanaNotificationListenerService : NotificationListenerService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "Notification listener connected.")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.w(TAG, "Notification listener disconnected.")
    }

    override fun onDestroy() {
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName !in WHATSAPP_PACKAGES) return

        val notification = sbn.notification ?: return
        if ((notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) {
            Log.d(TAG, "Skipping WhatsApp group summary.")
            return
        }

        val payload = extractWhatsAppPayload(notification.extras)
        if (payload == null) {
            Log.i(TAG, "WhatsApp | content unavailable or redacted | key=${sbn.key}")
            return
        }

        Log.i(TAG, "WhatsApp | sender=\"${payload.sender}\" | message=\"${payload.message}\"")

        val replyAction = findReplyAction(notification)
        if (replyAction == null) {
            Log.w(TAG, "Auto-pilot skipped: no RemoteInput reply action for ${payload.sender}.")
            return
        }

        serviceScope.launch {
            handleAutoPilotReply(
                notificationKey = sbn.key,
                packageName = sbn.packageName,
                payload = payload,
                replyAction = replyAction
            )
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        removeFingerprintForNotification(sbn.key)
    }

    private suspend fun handleAutoPilotReply(
        notificationKey: String,
        packageName: String,
        payload: WhatsAppPayload,
        replyAction: ReplyActionPayload
    ) {
        val context = applicationContext

        if (!AutoPilotStateStore.isUserEnabled(context)) {
            Log.d(TAG, "Auto-pilot skipped: tile is OFF.")
            return
        }

        val config = try {
            AitanaConfigReader.read(context)
        } catch (e: Exception) {
            Log.w(TAG, "Auto-pilot skipped: config unavailable (${e.message}).")
            return
        }

        if (!isSenderAuthorized(config, payload.sender)) {
            Log.d(TAG, "Auto-pilot skipped: sender not whitelisted (${payload.sender}).")
            return
        }

        if (!markAutoPilotFingerprint(notificationKey, packageName, payload)) {
            Log.d(TAG, "Auto-pilot skipped: duplicate notification for ${payload.sender}.")
            return
        }

        val lease = AiEngineLeaseManager.acquire(
            context,
            AutoPilotStateStore.EngineOwner.AUTOPILOT
        )
        if (lease == null) {
            Log.w(
                TAG,
                "Auto-pilot skipped: AI file lock denied. " +
                    "Last recorded owner=${AutoPilotStateStore.engineOwner(context).value}"
            )
            return
        }

        var miniAitana: MiniAitanaLiteRtEngine? = null
        try {
            miniAitana = MiniAitanaLiteRtEngine(context, lease)
            val reply = miniAitana.generateReply(
                config = config,
                sender = payload.sender,
                message = payload.message
            )

            if (reply.isBlank()) {
                Log.w(TAG, "Auto-pilot dropped empty reply for ${payload.sender}.")
                return
            }

            sendDirectReply(
                context = context,
                sender = payload.sender,
                action = replyAction.action,
                remoteInputs = replyAction.remoteInputs,
                reply = reply
            )
        } catch (e: Exception) {
            Log.e(TAG, "Auto-pilot inference failed for ${payload.sender}: ${e.message}", e)
        } finally {
            if (miniAitana != null) {
                miniAitana.close()
            } else {
                lease.close()
            }
        }
    }

    private fun extractWhatsAppPayload(extras: Bundle): WhatsAppPayload? {
        extractFromMessagingStyle(extras)?.let { return it }

        val title = clean(extras.getCharSequence(Notification.EXTRA_TITLE))
        val text = clean(extras.getCharSequence(Notification.EXTRA_TEXT))
            ?: clean(extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
            ?: latestTextLine(extras)

        if (text == null) return null

        val conversationTitle = clean(extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE))
        val senderAndMessage = splitGroupMessage(text)

        val sender = when {
            conversationTitle != null && senderAndMessage != null -> senderAndMessage.first
            title != null -> title
            conversationTitle != null -> conversationTitle
            else -> "Unknown"
        }
        val message = senderAndMessage?.second ?: text

        return WhatsAppPayload(sender = sender, message = message)
    }

    private fun extractFromMessagingStyle(extras: Bundle): WhatsAppPayload? {
        val rawMessages = extras.getParcelableArray(
            Notification.EXTRA_MESSAGES,
            Parcelable::class.java
        ) ?: return null

        val latestMessage = Notification.MessagingStyle.Message
            .getMessagesFromBundleArray(rawMessages)
            .lastOrNull { clean(it.text) != null }
            ?: return null

        val message = clean(latestMessage.text) ?: return null
        val sender = clean(latestMessage.senderPerson?.name)
            ?: clean(extras.getCharSequence(Notification.EXTRA_TITLE))
            ?: "Unknown"

        return WhatsAppPayload(sender = sender, message = message)
    }

    private fun latestTextLine(extras: Bundle): String? {
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            ?: return null
        return lines.mapNotNull(::clean).lastOrNull()
    }

    private fun splitGroupMessage(text: String): Pair<String, String>? {
        val separatorIndex = text.indexOf(": ")
        if (separatorIndex <= 0 || separatorIndex >= text.lastIndex) return null

        val sender = text.substring(0, separatorIndex).trim()
        val message = text.substring(separatorIndex + 2).trim()
        if (sender.isEmpty() || message.isEmpty()) return null

        return sender to message
    }

    private fun clean(value: CharSequence?): String? {
        val cleaned = value
            ?.toString()
            ?.replace(Regex("\\s+"), " ")
            ?.trim()

        return cleaned?.takeIf { it.isNotEmpty() }
    }

    private fun findReplyAction(notification: Notification): ReplyActionPayload? {
        val actions = notification.actions ?: return null
        val candidates = actions.mapNotNull { action ->
            val remoteInputs = action.remoteInputs
                ?.filter { it.allowFreeFormInput }
                ?.toTypedArray()
                ?: emptyArray()
            if (remoteInputs.isEmpty()) return@mapNotNull null
            ReplyActionPayload(action, remoteInputs)
        }

        return candidates.firstOrNull {
            it.action.semanticAction == Notification.Action.SEMANTIC_ACTION_REPLY
        } ?: candidates.firstOrNull()
    }

    private fun isSenderAuthorized(config: AitanaConfig, sender: String): Boolean {
        val normalizedSender = AutoPilotReplySanitizer.normalizeContactName(sender)
        return normalizedSender in config.whitelistNormalized
    }

    private fun markAutoPilotFingerprint(
        notificationKey: String,
        packageName: String,
        payload: WhatsAppPayload
    ): Boolean {
        val now = System.currentTimeMillis()
        val fingerprint = "$notificationKey|$packageName|${payload.sender}|${payload.message}"
        synchronized(recentAutoPilotFingerprints) {
            val lastSeen = recentAutoPilotFingerprints[fingerprint]
            if (lastSeen != null && now - lastSeen < DUPLICATE_WINDOW_MS) {
                return false
            }
            recentAutoPilotFingerprints[fingerprint] = now
            val iterator = recentAutoPilotFingerprints.entries.iterator()
            while (iterator.hasNext()) {
                if (now - iterator.next().value > DUPLICATE_WINDOW_MS) {
                    iterator.remove()
                }
            }
        }
        return true
    }

    private fun removeFingerprintForNotification(notificationKey: String) {
        synchronized(recentAutoPilotFingerprints) {
            recentAutoPilotFingerprints.entries.removeIf { it.key.startsWith("$notificationKey|") }
        }
    }

    private fun sendDirectReply(
        context: Context,
        sender: String,
        action: Notification.Action,
        remoteInputs: Array<RemoteInput>,
        reply: String
    ) {
        val pendingIntent = action.actionIntent
        if (pendingIntent == null) {
            Log.w(TAG, "Auto-pilot skipped: reply PendingIntent missing for $sender.")
            return
        }

        val fillInIntent = Intent()
        val remoteInputResults = Bundle()
        remoteInputs.forEach { input ->
            remoteInputResults.putCharSequence(input.resultKey, reply)
        }
        RemoteInput.addResultsToIntent(remoteInputs, fillInIntent, remoteInputResults)
        RemoteInput.setResultsSource(fillInIntent, RemoteInput.SOURCE_FREE_FORM_INPUT)

        try {
            pendingIntent.send(context, 0, fillInIntent)
            Log.i(TAG, "Auto-pilot reply sent to \"$sender\".")
        } catch (e: PendingIntent.CanceledException) {
            Log.e(TAG, "WhatsApp reply PendingIntent was canceled for $sender.", e)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send WhatsApp auto-reply for $sender.", e)
        }
    }

    private data class WhatsAppPayload(
        val sender: String,
        val message: String
    )

    private data class ReplyActionPayload(
        val action: Notification.Action,
        val remoteInputs: Array<RemoteInput>
    )

    companion object {
        private const val TAG = "AitanaInterceptor"
        private const val DUPLICATE_WINDOW_MS = 45_000L

        private val WHATSAPP_PACKAGES = setOf(
            "com.whatsapp",
            "com.whatsapp.w4b"
        )

        @Deprecated(
            message = "Whitelist is now read from aitana_config.json by the native listener."
        )
        fun updateActiveWhitelist(rawContacts: List<String>) {
            Log.i(
                TAG,
                "Ignoring legacy in-memory whitelist sync (${rawContacts.size}); JSON config is authoritative."
            )
        }

        private val recentAutoPilotFingerprints =
            object : LinkedHashMap<String, Long>(32, 0.75f, true) {
                override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?): Boolean =
                    size > 64
            }
    }
}
