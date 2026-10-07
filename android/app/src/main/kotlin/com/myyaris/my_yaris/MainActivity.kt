package com.myyaris.my_yaris

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.myyaris.my_yaris/navigation"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Ensure Foreground Service is started to keep process alive in background
        try {
            KeepAliveService.start(this)
        } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "launchCarNavitime" -> {
                    val geoUriString = call.argument<String>("geoUri")
                    val title = call.argument<String>("title") ?: ""
                    if (geoUriString.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "geoUri parameter is required and cannot be empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent(this, NavTransitionActivity::class.java).apply {
                            putExtra(NavTransitionActivity.EXTRA_GEO_URI, geoUriString)
                            putExtra(NavTransitionActivity.EXTRA_TITLE, title)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
                        }
                        startActivity(intent)
                        overridePendingTransition(0, 0)
                        result.success(mapOf("success" to true, "mode" to "transition_activity", "uri" to geoUriString))
                    } catch (e: Exception) {
                        try {
                            val directIntent = Intent(Intent.ACTION_VIEW, Uri.parse(geoUriString)).apply {
                                setPackage("com.navitime.local.carnavitime")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(directIntent)
                            result.success(mapOf("success" to true, "mode" to "geo_uri_direct", "uri" to geoUriString))
                        } catch (ex: Exception) {
                            result.error("LAUNCH_FAILED", ex.localizedMessage ?: "Failed to launch $geoUriString", null)
                        }
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
                "startKeepAliveService" -> {
                    try {
                        KeepAliveService.start(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_START_FAILED", e.localizedMessage, null)
                    }
                }
                "stopKeepAliveService" -> {
                    try {
                        KeepAliveService.stop(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_STOP_FAILED", e.localizedMessage, null)
                    }
                }
                "isBatteryOptimizationIgnored" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                        val isIgnoring = powerManager?.isIgnoringBatteryOptimizations(packageName) ?: false
                        result.success(isIgnoring)
                    } else {
                        result.success(true)
                    }
                }
                "requestIgnoreBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("REQUEST_FAILED", e.localizedMessage, null)
                        }
                    } else {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
