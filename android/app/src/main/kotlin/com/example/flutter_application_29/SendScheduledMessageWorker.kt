package com.chatwave

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.gson.Gson
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class SendScheduledMessageWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        try {
            // Read authBox for session_id
            val authBoxFile = File(applicationContext.getDir("hive", Context.MODE_PRIVATE), "authBox.hive")
            val authBoxJson = if (authBoxFile.exists()) authBoxFile.readText() else "{}"
            val authBoxMap = Gson().fromJson(authBoxJson, Map::class.java) as Map<String, Any?>
            val sessionId = authBoxMap["session_id"] as? String

            if (sessionId == null) {
                println("DEBUG [${System.currentTimeMillis()}]: SendScheduledMessageWorker: No session ID, skipping")
                return Result.failure()
            }

            // Perform HTTP POST request to send message
            val url = URL("http://147.93.177.26/chat.php?action=send_message")
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.setRequestProperty("Session-ID", sessionId)
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true

            val body = inputData.getString("body")?.let { Gson().fromJson(it, Map::class.java) as Map<String, Any?> }
            val jsonBody = Gson().toJson(body)
            connection.outputStream.write(jsonBody.toByteArray())
            connection.connect()

            val responseBody = connection.inputStream.bufferedReader().use { it.readText() }
            println("DEBUG [${System.currentTimeMillis()}]: SendScheduledMessageWorker: Response: $responseBody")

            connection.disconnect()
            return if (connection.responseCode == 200) Result.success() else Result.failure()
        } catch (e: Exception) {
            println("DEBUG [${System.currentTimeMillis()}]: SendScheduledMessageWorker error: ${e.message}")
            return Result.failure(workDataOf("error" to e.message))
        }
    }
}