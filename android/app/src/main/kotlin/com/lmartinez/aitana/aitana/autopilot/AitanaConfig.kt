package com.lmartinez.aitana.aitana.autopilot

import android.content.Context
import org.json.JSONObject

data class AitanaConfig(
    val schemaVersion: Int,
    val updatedAt: String,
    val model: ModelConfig,
    val whatsappOperator: WhatsAppOperatorConfig,
    val whitelist: List<String>,
    val whitelistNormalized: List<String>
) {
    data class ModelConfig(
        val baseName: String,
        val absolutePath: String
    )

    data class WhatsAppOperatorConfig(
        val language: String,
        val personaName: String,
        val personaCategory: String,
        val systemPrompt: String
    )
}

object AitanaConfigReader {
    fun read(context: Context): AitanaConfig {
        val file = ModelFileResolver.configFile(context)
        val root = JSONObject(file.readText())
        val model = root.getJSONObject("model")
        val operator = root.getJSONObject("whatsapp_operator")

        return AitanaConfig(
            schemaVersion = root.getInt("schema_version"),
            updatedAt = root.optString("updated_at"),
            model = AitanaConfig.ModelConfig(
                baseName = model.getString("base_name"),
                absolutePath = model.getString("absolute_path")
            ),
            whatsappOperator = AitanaConfig.WhatsAppOperatorConfig(
                language = operator.getString("language"),
                personaName = operator.getString("persona_name"),
                personaCategory = operator.getString("persona_category"),
                systemPrompt = operator.getString("system_prompt")
            ),
            whitelist = root.getJSONArray("whitelist").toStringList(),
            whitelistNormalized = root.getJSONArray("whitelist_normalized").toStringList()
        )
    }

    private fun org.json.JSONArray.toStringList(): List<String> =
        List(length()) { index -> getString(index) }
}
