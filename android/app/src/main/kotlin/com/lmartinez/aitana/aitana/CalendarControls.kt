package com.lmartinez.aitana.aitana

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import com.google.ai.edge.litertlm.Tool
import com.google.ai.edge.litertlm.ToolParam
import com.google.ai.edge.litertlm.ToolSet
import kotlin.coroutines.resume

/**
 * Bridges the native LiteRT-LM tool-calling API to the Flutter [MethodChannel]
 * so the Gemma model can invoke `manage_calendar` and receive the result.
 */
class CalendarControls(private val channel: MethodChannel) : ToolSet {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Tool(
        description = "Manages the user's native Android calendar. Use 'add' to create an event."
    )
    fun manage_calendar(
        @ToolParam(description = "The action to perform: 'add'.") action: String = "add",
        @ToolParam(description = "A short title for the event.") title: String = "",
        @ToolParam(description = "The date in YYYY-MM-DD format.") date: String = "",
        @ToolParam(description = "The time in HH:MM format (24-hour). Birthdays MUST use '00:00'. Tasks (no specific time) MUST use '17:00'.") time: String = "17:00",
        @ToolParam(description = "Minutes before event for notification. Birthdays/Tasks MUST use 60. Standard events default to 0. Use -1 ONLY if explicitly asked for no alarm.") reminder_minutes: Int = 0,
        @ToolParam(description = "Boolean: True if it's a full-day event/task.") is_all_day: Boolean = false,
        @ToolParam(description = "Boolean: True if it's a birthday (will repeat yearly).") is_birthday: Boolean = false
    ): Map<String, Any> {

        android.util.Log.i("LiteRT-LM", "🛠️ Tool triggered: manage_calendar(action=$action, title=$title, date=$date, time=$time, reminder_minutes=$reminder_minutes)")

        val args = mapOf(
            "action" to action,
            "title"  to title,
            "date"   to date,
            "time"   to time,
            "reminder_minutes" to reminder_minutes,
            "is_all_day" to is_all_day,
            "is_birthday" to is_birthday
        )

        // Usamos tu misma estructura anti-deadlock
        return runBlocking {
            suspendCancellableCoroutine { continuation ->
                mainHandler.post {
                    if (!continuation.isActive) return@post

                    channel.invokeMethod(
                        "manage_calendar",
                        args,
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                continuation.resume(
                                    mapOf("status" to "success", "data" to (result?.toString() ?: ""))
                                )
                            }
                            override fun error(eCode: String, eMsg: String?, eDetails: Any?) {
                                continuation.resume(
                                    mapOf("status" to "error", "message" to (eMsg ?: "Unknown error"))
                                )
                            }
                            override fun notImplemented() {
                                continuation.resume(
                                    mapOf("status" to "error", "message" to "Not implemented in Dart.")
                                )
                            }
                        }
                    )
                }
            }
        }
    }
}