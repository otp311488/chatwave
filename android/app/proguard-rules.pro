# WorkManager
-keep class androidx.work.** { *; }
-dontwarn androidx.work.**

# Gson
-keep class com.google.gson.** { *; }
-keepattributes Signature
-keepattributes *Annotation*

# NotificationCompat (AndroidX Core)
-keep class androidx.core.app.NotificationCompat { *; }
-keep class androidx.core.app.NotificationCompat$** { *; }
-dontwarn androidx.core.app.**

# TensorFlow Lite
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.lite.**

# ExoPlayer
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**

# OkHttp and Okio
-keep class okhttp3.** { *; }
-dontwarn okhttp3.**
-keep class okio.** { *; }
-dontwarn okio.**

# Jackson (JSON and XML processing)
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**
-keep class java.beans.** { *; }
-dontwarn java.beans.**
-keep class org.w3c.dom.** { *; }
-dontwarn org.w3c.dom.**

# Conscrypt (used by OkHttp for SSL/TLS)
-keep class org.conscrypt.** { *; }
-dontwarn org.conscrypt.**

# Local Auth (for biometric authentication)
-keep class com.baseflow.localauth.** { *; }
-dontwarn com.baseflow.localauth.**

# Firebase
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# MultiDex
-keep class androidx.multidex.** { *; }
-dontwarn androidx.multidex.**

# media_kit (to address MediaKitAndroidHelper and related classes)
-keep class com.alexmercerind.mediakitandroidhelper.** { *; }
-dontwarn com.alexmercerind.mediakitandroidhelper.**