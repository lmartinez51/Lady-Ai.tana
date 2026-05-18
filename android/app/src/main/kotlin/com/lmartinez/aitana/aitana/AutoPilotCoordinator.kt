package com.lmartinez.aitana.aitana

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.StatusBarNotification
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object AutoPilotCoordinator {
    private const val TAG = "AitanaAutoPilot"
    private const val CHANNEL = "com.lmartinez.aitana/autopilot"
    private const val CACHE_TTL_MS = 90_000L

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var channel: MethodChannel? = null

    @Volatile
    private var contactProvider: ContactProvider? = null

    interface ContactProvider {
        fun requestContactsPermission(result: MethodChannel.Result)
        fun getDeviceContactNames(result: MethodChannel.Result)
    }

    fun attach(flutterEngine: FlutterEngine, context: Context, provider: ContactProvider? = null) {
        appContext = context.applicationContext
        contactProvider = provider
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handleDartCall)
        }
        Log.i(TAG, "Auto-pilot bridge attached.")
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        contactProvider = null
        Log.i(TAG, "Auto-pilot bridge detached.")
    }

    @Deprecated(
        message = "WhatsApp Auto-Pilot generation now runs entirely in AitanaNotificationListenerService."
    )
    fun enqueueWhatsAppReply(
        context: Context,
        sbn: StatusBarNotification,
        sender: String,
        message: String,
        action: Notification.Action,
        remoteInputs: Array<RemoteInput>
    ) {
        val pendingIntent = action.actionIntent
        if (pendingIntent == null) {
            Log.w(TAG, "Reply action for \"$sender\" has no PendingIntent.")
            return
        }

        val activeChannel = channel
        if (activeChannel == null) {
            Log.w(TAG, "Flutter bridge unavailable. Dropping auto-reply request for \"$sender\".")
            return
        }

        val requestId = AutoReplyPendingIntentCache.createRequestId()
        val entry = AutoReplyPendingIntentCache.Entry(
            requestId = requestId,
            pendingIntent = pendingIntent,
            remoteInputs = remoteInputs,
            notificationKey = sbn.key,
            sender = sender,
            message = message,
            packageName = sbn.packageName
        )
        AutoReplyPendingIntentCache.put(entry)

        val request = AutoPilotRequest(
            requestId = requestId,
            sender = sender,
            message = message,
            notificationKey = sbn.key,
            packageName = sbn.packageName,
            postTime = sbn.postTime
        )

        mainHandler.postDelayed({
            AutoReplyPendingIntentCache.expireIfStale(requestId)
        }, CACHE_TTL_MS)

        mainHandler.post {
            Log.i(TAG, "Dispatching auto-pilot request $requestId for \"$sender\".")
            activeChannel.invokeMethod(
                "onWhatsAppAutoReplyRequest",
                request.toMap(),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        Log.d(TAG, "Dart accepted auto-pilot request $requestId: $result")
                    }

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        AutoReplyPendingIntentCache.remove(requestId)
                        Log.e(TAG, "Dart rejected auto-pilot request $requestId: $errorCode $errorMessage")
                    }

                    override fun notImplemented() {
                        AutoReplyPendingIntentCache.remove(requestId)
                        Log.e(TAG, "Dart auto-pilot handler is not implemented.")
                    }
                }
            )
        }
    }

    fun removeForNotification(notificationKey: String) {
        AutoReplyPendingIntentCache.removeByNotificationKey(notificationKey)
    }

    private fun handleDartCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "completeAutoReply" -> {
                val requestId = call.argument<String>("requestId")
                val reply = call.argument<String>("reply")
                if (requestId.isNullOrBlank() || reply.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "requestId and reply are required.", null)
                    return
                }

                val context = appContext
                if (context == null) {
                    result.error("NO_CONTEXT", "Auto-pilot context is not attached.", null)
                    return
                }

                sendCachedReply(context, requestId, reply, result)
            }

            "dropAutoReply" -> {
                val requestId = call.argument<String>("requestId")
                if (!requestId.isNullOrBlank()) {
                    AutoReplyPendingIntentCache.remove(requestId)
                    Log.i(TAG, "Dropped auto-pilot request $requestId.")
                }
                result.success(true)
            }

            "requestContactsPermission" -> {
                val provider = contactProvider
                if (provider == null) {
                    result.error("NO_CONTACT_PROVIDER", "Contacts bridge is not attached.", null)
                    return
                }
                provider.requestContactsPermission(result)
            }

            "getDeviceContactNames" -> {
                val provider = contactProvider
                if (provider == null) {
                    result.error("NO_CONTACT_PROVIDER", "Contacts bridge is not attached.", null)
                    return
                }
                provider.getDeviceContactNames(result)
            }

            "setActiveWhitelist" -> {
                val contacts = when (val args = call.arguments) {
                    is List<*> -> args.mapNotNull { it as? String }
                    is Map<*, *> -> (args["contacts"] as? List<*>)
                        ?.mapNotNull { it as? String }
                        ?: emptyList()
                    else -> emptyList()
                }
                Log.i(
                    TAG,
                    "Received legacy whitelist bridge sync (${contacts.size}); aitana_config.json is authoritative."
                )
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun sendCachedReply(
        context: Context,
        requestId: String,
        reply: String,
        result: MethodChannel.Result
    ) {
        val entry = AutoReplyPendingIntentCache.take(requestId)
        if (entry == null) {
            result.error("REQUEST_EXPIRED", "No live PendingIntent for request $requestId.", null)
            return
        }

        val fillInIntent = Intent()
        val remoteInputResults = Bundle()
        entry.remoteInputs.forEach { input ->
            remoteInputResults.putCharSequence(input.resultKey, reply)
        }
        RemoteInput.addResultsToIntent(entry.remoteInputs, fillInIntent, remoteInputResults)
        RemoteInput.setResultsSource(fillInIntent, RemoteInput.SOURCE_FREE_FORM_INPUT)

        try {
            entry.pendingIntent.send(context, 0, fillInIntent)
            Log.i(TAG, "Auto-reply sent to \"${entry.sender}\" via WhatsApp request $requestId.")
            result.success(true)
        } catch (e: PendingIntent.CanceledException) {
            Log.e(TAG, "WhatsApp reply PendingIntent was canceled for $requestId.", e)
            result.error("PENDING_INTENT_CANCELED", e.message, null)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send WhatsApp auto-reply for $requestId.", e)
            result.error("SEND_FAILED", e.message, null)
        }
    }
}
