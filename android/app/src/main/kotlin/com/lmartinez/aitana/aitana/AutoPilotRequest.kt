package com.lmartinez.aitana.aitana

data class AutoPilotRequest(
    val requestId: String,
    val sender: String,
    val message: String,
    val notificationKey: String,
    val packageName: String,
    val postTime: Long
) {
    fun toMap(): Map<String, Any> = mapOf(
        "requestId" to requestId,
        "sender" to sender,
        "message" to message,
        "notificationKey" to notificationKey,
        "packageName" to packageName,
        "postTime" to postTime
    )
}
