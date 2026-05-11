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
 * so the Gemma model can invoke `search_vault` and receive the result.
 */
class VaultControls(private val channel: MethodChannel) : ToolSet {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Tool(
        description = "Searches the user's personal visual vault. CRITICAL: You MUST use this tool automatically when the user asks about an image, photo, or item they saved. DO NOT ask the user for a keyword. You must INFER and synthesize the best search keyword (e.g., if they ask about 'my car', use 'car' or 'vehicle' as the keyword). Always proactively search before replying."
    )
    fun search_vault(
        @ToolParam(description = "The specific object, item, or topic inferred from the user query. DO NOT ask the user for this; synthesize it yourself (e.g., 'vehicle', 'receipt', 'contract').") keyword: String
    ): Map<String, Any> {

        android.util.Log.i("LiteRT-LM", "🛠️ Tool triggered: search_vault(keyword=$keyword)")

        val args = mapOf("keyword" to keyword)

        return runBlocking {
            suspendCancellableCoroutine { continuation ->
                mainHandler.post {
                    if (!continuation.isActive) return@post

                    // Llama al método en Flutter. Asegúrate de tener un bloque
                    // 'search_vault' en tu methodCallHandler de main_chat_screen.dart
                    channel.invokeMethod(
                        "search_vault",
                        args,
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                continuation.resume(
                                    mapOf("status" to "success", "data" to (result?.toString() ?: "No results found."))
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