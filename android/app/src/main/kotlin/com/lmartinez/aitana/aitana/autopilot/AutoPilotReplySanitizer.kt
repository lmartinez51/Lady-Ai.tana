package com.lmartinez.aitana.aitana.autopilot

object AutoPilotReplySanitizer {
    private val thoughtBlock = Regex(
        pattern = "<\\|channel>thought.*?<channel\\|>",
        options = setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)
    )
    private val thinkBlock = Regex(
        pattern = "<think>.*?</think>",
        options = setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)
    )
    private val prefix = Regex(
        pattern = "^(aitana|reply|respuesta|whatsapp reply)\\s*:\\s*",
        options = setOf(RegexOption.IGNORE_CASE)
    )

    fun clean(raw: String): String {
        var text = raw.trim()
        if (text.isEmpty()) return ""

        text = thoughtBlock.replace(text, "")
        text = thinkBlock.replace(text, "")
        text = text
            .replace("<|channel>thought", "")
            .replace("<channel|>", "")
            .replace("<|think|>", "")
            .trim()

        text = prefix.replace(text, "").trim()
        text = text.trim('"', '\'', ' ', '\n', '\r', '\t')
        return text
    }

    fun normalizeContactName(value: String): String {
        val withoutMarks = java.text.Normalizer.normalize(value, java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
        return withoutMarks
            .lowercase()
            .replace(Regex("[^a-z0-9\\s]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()
    }
}
