package com.chatwave

import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.gson.Gson
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class NotificationPollingWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        try {
            // Simulate Hive access for authBox and messageBox
            val hiveDir = applicationContext.getDir("hive", Context.MODE_PRIVATE)
            val authBoxFile = File(hiveDir, "authBox.hive")
            val messageBoxFile = File(hiveDir, "messageBox.hive")

            // Read authBox (session_id and user_id)
            val authBoxJson = if (authBoxFile.exists()) authBoxFile.readText() else "{}"
            val authBoxMap = Gson().fromJson(authBoxJson, Map::class.java) as Map<String, Any?>
            val sessionId = authBoxMap["session_id"] as? String
            val userId = (authBoxMap["user_id"] as? Double)?.toInt()

            if (sessionId == null || userId == null) {
                println("DEBUG [${System.currentTimeMillis()}]: NotificationPollingWorker: No session or user ID, skipping")
                return Result.failure()
            }

            // Perform HTTP GET request to poll notifications
            val url = URL("http://147.93.177.26/chat.php?action=poll_notifications")
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.setRequestProperty("Session-ID", sessionId)
            connection.setRequestProperty("Content-Type", "application/json")
            connection.connect()

            if (connection.responseCode == 200) {
                val responseBody = connection.inputStream.bufferedReader().use { it.readText() }
                val data = Gson().fromJson(responseBody, Map::class.java) as Map<String, Any?>
                println("DEBUG [${System.currentTimeMillis()}]: NotificationPollingWorker: Polling response: $responseBody")

                if (data["status"] == "success" && data["notifications"] != null) {
                    // Read messageBox (activeMessageIds)
                    val messageBoxJson = if (messageBoxFile.exists()) messageBoxFile.readText() else "{}"
                    val messageBoxMap = Gson().fromJson(messageBoxJson, Map::class.java) as Map<String, Any?>
                    val activeMessageIds = (messageBoxMap["activeMessageIds"] as? List<String>)?.toMutableSet() ?: mutableSetOf()

                    val notifications = data["notifications"] as List<Map<String, Any?>>
                    val notificationManager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

                    for (notification in notifications) {
                        val messageId = notification["message_id"]?.toString() ?: ""
                        if (notification["type"] != "message" || messageId.isEmpty() || activeMessageIds.contains(messageId)) {
                            continue
                        }
                        activeMessageIds.add(messageId)

                        val chatId = (notification["chat_id"]?.toString()?.toIntOrNull()) ?: 0
                        val senderName = notification["sender_name"]?.toString() ?: "Unknown"
                        val messageContent = notification["message"]?.toString() ?: "New message received"
                        val chatName = notification["chat_name"]?.toString() ?: "Chat"
                        val isGroup = notification["is_group"]?.toString() == "1"

                        // Create notification payload
                        val payload = Gson().toJson(mapOf(
                            "chatId" to chatId.toString(),
                            "chatName" to chatName,
                            "isGroup" to isGroup,
                            "userId" to userId.toString(),
                            "type" to "message",
                            "messageId" to messageId
                        ))

                        // Build and show notification
                        val notification = NotificationCompat.Builder(applicationContext, "message_notifications")
                            .setContentTitle("New Message from $senderName")
                            .setContentText(messageContent)
                            .setSmallIcon(R.mipmap.ic_launcher)
                            .setPriority(NotificationCompat.PRIORITY_HIGH)
                            .setAutoCancel(true)
                            .setContentIntent(
                                android.app.PendingIntent.getActivity(
                                    applicationContext,
                                    chatId,
                                    android.content.Intent(applicationContext, MainActivity::class.java).apply {
                                        action = "FLUTTER_NOTIFICATION_CLICK"
                                        putExtra("payload", payload)
                                    },
                                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
                                )
                            )
                            .build()

                        notificationManager.notify(chatId, notification)
                        println("DEBUG [${System.currentTimeMillis()}]: NotificationPollingWorker: Showed notification for messageId=$messageId")
                    }

                    // Save updated activeMessageIds
                    messageBoxFile.writeText(Gson().toJson(mapOf("activeMessageIds" to activeMessageIds.toList())))
                }
                connection.disconnect()
                return Result.success()
            } else {
                println("DEBUG [${System.currentTimeMillis()}]: NotificationPollingWorker: Polling failed with status: ${connection.responseCode}")
                connection.disconnect()
                return Result.failure()
            }
        } catch (e: Exception) {
            println("DEBUG [${System.currentTimeMillis()}]: NotificationPollingWorker error: ${e.message}")
            return Result.failure(workDataOf("error" to e.message))
        }
    }
}