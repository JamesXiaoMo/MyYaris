package com.myyaris.my_yaris

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.myyaris.my_yaris/navigation"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "launchCarNavitime" -> {
                    val geoUriString = call.argument<String>("geoUri")
                    if (geoUriString.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "geoUri parameter is required and cannot be empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(geoUriString)).apply {
                            setPackage("com.navitime.local.carnavitime")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(mapOf("success" to true, "mode" to "geo_uri", "uri" to geoUriString))
                    } catch (e: Exception) {
                        result.error("LAUNCH_FAILED", e.localizedMessage ?: "Failed to launch $geoUriString", null)
                    }
                }
                "checkNavitimeInstalled" -> {
                    try {
                        packageManager.getPackageInfo("com.navitime.local.carnavitime", 0)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
