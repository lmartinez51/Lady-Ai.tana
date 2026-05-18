package com.lmartinez.aitana.aitana.autopilot

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.SamplerConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.File

class MiniAitanaLiteRtEngine(
    private val context: Context,
    private val lease: AiEngineLeaseManager.Lease
) : Closeable {
    private var engine: Engine? = null
    private var conversation: Conversation? = null

    @OptIn(ExperimentalApi::class)
    suspend fun generateReply(
        config: AitanaConfig,
        sender: String,
        message: String
    ): String = withContext(Dispatchers.IO) {
        if (!lease.isValid) {
            throw IllegalStateException("AI engine lease is not valid.")
        }
        if (!AutoPilotStateStore.isAutoPilotEffectivelyArmed(context)) {
            throw IllegalStateException("Auto-Pilot is not armed.")
        }

        val modelFile = File(config.model.absolutePath)
        if (!modelFile.exists()) {
            throw IllegalStateException("Configured model file does not exist: ${config.model.absolutePath}")
        }

        try {
            val engineConfig = EngineConfig(
                modelPath = config.model.absolutePath,
                backend = Backend.CPU(),
                audioBackend = Backend.CPU(),
                visionBackend = Backend.CPU(),
                cacheDir = context.cacheDir.path
            )
            val loadedEngine = Engine(engineConfig)
            engine = loadedEngine
            loadedEngine.initialize()
            lease.heartbeat()

            val configForConversation = ConversationConfig(
                systemInstruction = Contents.of(config.whatsappOperator.systemPrompt),
                samplerConfig = SamplerConfig(
                    topK = 40,
                    topP = 0.85,
                    temperature = 0.7
                ),
                tools = emptyList()
            )
            val activeConversation = loadedEngine.createConversation(configForConversation)
            conversation = activeConversation

            val buffer = StringBuilder()
            activeConversation.sendMessageAsync(buildRuntimePrompt(sender, message))
                .collect { token ->
                    buffer.append(token.toString())
                }

            return@withContext AutoPilotReplySanitizer.clean(buffer.toString())
        } finally {
            try {
                conversation?.close()
            } finally {
                conversation = null
            }
        }
    }

    override fun close() {
        try {
            conversation?.close()
        } catch (_: Exception) {
        } finally {
            conversation = null
        }

        try {
            engine?.close()
        } finally {
            engine = null
            lease.close()
        }
    }

    private fun buildRuntimePrompt(sender: String, message: String): String =
        """
        # RUNTIME WHATSAPP CONTEXT
        - Sender: $sender
        - Message: "$message"

        Write the reply now.
        """.trimIndent()
}
