package com.myyaris.my_yaris

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val navChannelName = "com.myyaris.my_yaris/navigation"
    private val musicChannelName = "com.myyaris.my_yaris/music"
    private val systemUiChannelName = "com.myyaris.my_yaris/system_ui"
    private val locationChannelName = "com.myyaris.my_yaris/location"
    private val storageChannelName = "com.myyaris.my_yaris/storage"
    private var isFullscreenConfigured: Boolean = true
    private var locationManager: LocationManager? = null
    private var locationListener: LocationListener? = null
    @Volatile
    private var latestLocation: Location? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            isFullscreenConfigured = prefs.getBoolean("flutter.myyaris_fullscreen_enabled", true)
            applyFullscreen(isFullscreenConfigured)
        } catch (_: Exception) {}

        // Ensure Foreground Service is started to keep process alive in background
        try {
            KeepAliveService.start(this)
        } catch (_: Exception) {}
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && isFullscreenConfigured) {
            applyFullscreen(true)
        }
    }

    private fun applyFullscreen(enabled: Boolean) {
        isFullscreenConfigured = enabled
        runOnUiThread {
            try {
                WindowCompat.setDecorFitsSystemWindows(window, !enabled)
                val controller = WindowCompat.getInsetsController(window, window.decorView)
                if (enabled) {
                    controller.hide(WindowInsetsCompat.Type.systemBars())
                    controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                } else {
                    controller.show(WindowInsetsCompat.Type.systemBars())
                }
            } catch (_: Exception) {}
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupNavigationChannel(flutterEngine)
        setupMusicChannel(flutterEngine)
        setupSystemUiChannel(flutterEngine)
        setupLocationChannel(flutterEngine)
        setupStorageChannel(flutterEngine)
        ObdReportExporter.register(this, flutterEngine)
    }

    private fun setupStorageChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "getMusicCacheDir" -> {
                    try {
                        val dirs = getExternalFilesDirs(null)?.filterNotNull() ?: emptyList()
                        var chosen: java.io.File? = null
                        var isSd = false
                        // Prefer removable mounted SD card first
                        for (d in dirs) {
                            try {
                                val removable = Environment.isExternalStorageRemovable(d)
                                val state = Environment.getExternalStorageState(d)
                                if (removable && state == Environment.MEDIA_MOUNTED) {
                                    chosen = d
                                    isSd = true
                                    break
                                }
                            } catch (_: Exception) {}
                        }
                        if (chosen == null) {
                            chosen = dirs.firstOrNull() ?: filesDir
                            isSd = false
                        }
                        val cacheDir = java.io.File(chosen, "music_cache")
                        if (!cacheDir.exists()) cacheDir.mkdirs()
                        val stat = StatFs(cacheDir.absolutePath)
                        val freeBytes = stat.availableBytes
                        result.success(mapOf(
                            "path" to cacheDir.absolutePath,
                            "isSdCard" to isSd,
                            "freeBytes" to freeBytes
                        ))
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.localizedMessage ?: "Cannot resolve cache dir", null)
                    }
                }
                "isOnWifi" -> {
                    try {
                        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                        val active = cm?.activeNetwork
                        val caps = if (active != null) cm.getNetworkCapabilities(active) else null
                        val onWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                        result.success(onWifi)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        stopNativeLocationTracking()
        super.onDestroy()
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun startNativeLocationTracking(): Boolean {
        if (!hasLocationPermission()) return false
        val lm = locationManager ?: (getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.also {
            locationManager = it
        } ?: return false

        if (locationListener == null) {
            val listener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    latestLocation = location
                }
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
                @Deprecated("Deprecated in Java")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            }
            locationListener = listener
            runOnUiThread {
                for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                    try {
                        if (lm.isProviderEnabled(provider)) {
                            lm.requestLocationUpdates(provider, 5000L, 0f, listener, Looper.getMainLooper())
                        }
                    } catch (_: Exception) {}
                }
            }
        }
        refreshBestLastKnownLocation(lm)
        return true
    }

    private fun stopNativeLocationTracking() {
        val lm = locationManager
        val listener = locationListener
        if (lm != null && listener != null) {
            try {
                lm.removeUpdates(listener)
            } catch (_: Exception) {}
        }
        locationListener = null
    }

    private fun refreshBestLastKnownLocation(lm: LocationManager): Location? {
        if (!hasLocationPermission()) return null
        var best = latestLocation
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
            try {
                val cand = lm.getLastKnownLocation(provider) ?: continue
                if (best == null || cand.time > best.time) {
                    best = cand
                }
            } catch (_: Exception) {}
        }
        if (best != null) latestLocation = best
        return best
    }

    private fun setupLocationChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, locationChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTracking" -> result.success(startNativeLocationTracking())
                "stopTracking" -> {
                    stopNativeLocationTracking()
                    result.success(true)
                }
                "getLatestLocation" -> {
                    if (!hasLocationPermission()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val lm = locationManager ?: (getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.also {
                        locationManager = it
                    }
                    val loc = if (lm != null) refreshBestLastKnownLocation(lm) else latestLocation
                    if (loc == null) {
                        result.success(null)
                    } else {
                        result.success(mapOf(
                            "latitude" to loc.latitude,
                            "longitude" to loc.longitude,
                            "speed_kmh" to if (loc.hasSpeed()) (loc.speed * 3.6).toDouble() else null,
                            "accuracy_m" to if (loc.hasAccuracy()) loc.accuracy.toDouble() else null,
                            "timestamp_ms" to loc.time,
                            "provider" to (loc.provider ?: "unknown")
                        ))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupSystemUiChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemUiChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setFullscreen" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    applyFullscreen(enabled)
                    result.success(true)
                }
                "isFullscreen" -> {
                    result.success(isFullscreenConfigured)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupNavigationChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, navChannelName).setMethodCallHandler { call, result ->
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

    private fun setupMusicChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, musicChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationAccessGranted" -> {
                    result.success(MediaControlNotificationListenerService.isPermissionGranted(this))
                }
                "openNotificationAccessSettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_SETTINGS_FAILED", e.localizedMessage, null)
                    }
                }
                "getPlaybackInfo" -> {
                    val hasPermission = MediaControlNotificationListenerService.isPermissionGranted(this)
                    if (!hasPermission) {
                        result.success(mapOf(
                            "hasPermission" to false,
                            "sessionFound" to false,
                            "message" to "未获得【通知使用权】。读取曲目与播放状态需系统通知使用权，请点击授权。"
                        ))
                        return@setMethodCallHandler
                    }
                    val controller = MediaControlNotificationListenerService.getCloudMusicController(this)
                    if (controller == null) {
                        result.success(mapOf(
                            "hasPermission" to true,
                            "sessionFound" to false,
                            "message" to "已获授权，但未检测到活跃的网易云音乐会话。请在后台或前台先打开网易云音乐。"
                        ))
                        return@setMethodCallHandler
                    }

                    val metadata = controller.metadata
                    val state = controller.playbackState
                    val title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)
                        ?: metadata?.description?.title?.toString() ?: "未知曲目"
                    val artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                        ?: metadata?.description?.subtitle?.toString() ?: "未知歌手"
                    val album = metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM)
                        ?: metadata?.description?.description?.toString() ?: ""
                    val stateCode = state?.state ?: PlaybackState.STATE_NONE
                    val stateName = when (stateCode) {
                        PlaybackState.STATE_PLAYING -> "播放中"
                        PlaybackState.STATE_PAUSED -> "已暂停"
                        PlaybackState.STATE_STOPPED -> "已停止"
                        PlaybackState.STATE_BUFFERING -> "缓冲中"
                        PlaybackState.STATE_FAST_FORWARDING -> "快进中"
                        PlaybackState.STATE_REWINDING -> "快退中"
                        else -> "状态代码: $stateCode"
                    }
                    val position = state?.position ?: -1L
                    val actionsMask = state?.actions ?: 0L

                    val customActionsList = mutableListOf<Map<String, Any?>>()
                    state?.customActions?.forEach { ca ->
                        val extrasMap = mutableMapOf<String, String>()
                        ca.extras?.let { bundle ->
                            for (key in bundle.keySet()) {
                                extrasMap[key] = bundle.get(key)?.toString() ?: ""
                            }
                        }
                        customActionsList.add(mapOf(
                            "action" to ca.action,
                            "name" to (ca.name?.toString() ?: ""),
                            "icon" to ca.icon,
                            "extras" to extrasMap
                        ))
                    }

                    val sessionExtras = controller.extras
                    val stateExtras = state?.extras
                    val repeatMode = sessionExtras?.getInt("android.media.session.extra.REPEAT_MODE", -1)
                        ?: stateExtras?.getInt("android.media.session.extra.REPEAT_MODE", -1)
                        ?: -1
                    val shuffleMode = sessionExtras?.getInt("android.media.session.extra.SHUFFLE_MODE", -1)
                        ?: stateExtras?.getInt("android.media.session.extra.SHUFFLE_MODE", -1)
                        ?: -1

                    android.util.Log.i("MyYarisMusic", "=== 网易云 MediaSession 实时数据 ===")
                    android.util.Log.i("MyYarisMusic", "Title: $title | Artist: $artist | Album: $album | State: $stateName($stateCode) | Actions: $actionsMask")
                    android.util.Log.i("MyYarisMusic", "repeatMode: $repeatMode | shuffleMode: $shuffleMode")
                    controller.extras?.keySet()?.forEach { k ->
                        android.util.Log.i("MyYarisMusic", "Controller extra: $k = ${controller.extras?.get(k)}")
                    }
                    state?.extras?.keySet()?.forEach { k ->
                        android.util.Log.i("MyYarisMusic", "State extra: $k = ${state?.extras?.get(k)}")
                    }
                    customActionsList.forEachIndexed { idx, item ->
                        android.util.Log.i("MyYarisMusic", "CustomAction[$idx]: name=${item["name"]}, action=${item["action"]}, extras=${item["extras"]}")
                    }

                    result.success(mapOf(
                        "hasPermission" to true,
                        "sessionFound" to true,
                        "title" to title,
                        "artist" to artist,
                        "album" to album,
                        "stateCode" to stateCode,
                        "stateName" to stateName,
                        "positionMs" to position,
                        "actionsMask" to actionsMask,
                        "repeatMode" to repeatMode,
                        "shuffleMode" to shuffleMode,
                        "customActions" to customActionsList,
                        "message" to "已成功读取网易云 MediaSession 信息"
                    ))
                }
                "togglePlayPause" -> {
                    val controller = MediaControlNotificationListenerService.getCloudMusicController(this)
                    if (controller == null) {
                        result.error("NO_SESSION", "未连接到网易云音乐会话（请确认已授权且网易云已启动）", null)
                        return@setMethodCallHandler
                    }
                    val isPlaying = controller.playbackState?.state == PlaybackState.STATE_PLAYING
                    if (isPlaying) {
                        controller.transportControls.pause()
                        result.success(mapOf("success" to true, "action" to "pause", "message" to "已向网易云发送【暂停】指令"))
                    } else {
                        controller.transportControls.play()
                        result.success(mapOf("success" to true, "action" to "play", "message" to "已向网易云发送【播放】指令"))
                    }
                }
                "skipToNext" -> {
                    val controller = MediaControlNotificationListenerService.getCloudMusicController(this)
                    if (controller == null) {
                        result.error("NO_SESSION", "未连接到网易云音乐会话", null)
                        return@setMethodCallHandler
                    }
                    controller.transportControls.skipToNext()
                    result.success(mapOf("success" to true, "action" to "next", "message" to "已向网易云发送【下一曲】指令"))
                }
                "skipToPrevious" -> {
                    val controller = MediaControlNotificationListenerService.getCloudMusicController(this)
                    if (controller == null) {
                        result.error("NO_SESSION", "未连接到网易云音乐会话", null)
                        return@setMethodCallHandler
                    }
                    controller.transportControls.skipToPrevious()
                    result.success(mapOf("success" to true, "action" to "previous", "message" to "已向网易云发送【上一曲】指令"))
                }
                "sendCustomAction" -> {
                    val actionId = call.argument<String>("action")
                    if (actionId.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "action 参数不可为空", null)
                        return@setMethodCallHandler
                    }
                    val controller = MediaControlNotificationListenerService.getCloudMusicController(this)
                    if (controller == null) {
                        result.error("NO_SESSION", "未连接到网易云音乐会话", null)
                        return@setMethodCallHandler
                    }
                    val extrasMap = call.argument<Map<String, String>>("extras")
                    val bundle = Bundle()
                    extrasMap?.forEach { (k, v) -> bundle.putString(k, v) }
                    controller.transportControls.sendCustomAction(actionId, bundle)
                    result.success(mapOf("success" to true, "action" to actionId, "message" to "已发送自定义动作 [$actionId]"))
                }
                "openSongPage" -> {
                    val input = call.argument<String>("input")?.trim() ?: ""
                    if (input.isEmpty()) {
                        result.error("INVALID_ARGUMENT", "歌曲 ID 或链接不可为空", null)
                        return@setMethodCallHandler
                    }
                    val songUri = if (input.startsWith("orpheus://")) {
                        input
                    } else if (input.startsWith("http://") || input.startsWith("https://")) {
                        val idRegex = Regex("""[?&]id=(\d+)""")
                        val match = idRegex.find(input)
                        if (match != null) {
                            "orpheus://song/${match.groupValues[1]}"
                        } else {
                            input
                        }
                    } else {
                        "orpheus://song/$input"
                    }

                    try {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(songUri)).apply {
                            setPackage("com.netease.cloudmusic")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(mapOf(
                            "success" to true,
                            "uri" to songUri,
                            "message" to "已发起打开歌曲详情页 ($songUri)。注意：仅定位详情页，非自动起播。"
                        ))
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", "打开失败: ${e.localizedMessage}", null)
                    }
                }
                "openPlaylistPage" -> {
                    val input = call.argument<String>("input")?.trim() ?: ""
                    if (input.isEmpty()) {
                        result.error("INVALID_ARGUMENT", "歌单 ID 或链接不可为空", null)
                        return@setMethodCallHandler
                    }
                    val playlistUri = if (input.startsWith("orpheus://")) {
                        input
                    } else if (input.startsWith("http://") || input.startsWith("https://")) {
                        val idRegex = Regex("""[?&]id=(\d+)""")
                        val match = idRegex.find(input)
                        if (match != null) {
                            "orpheus://playlist/${match.groupValues[1]}"
                        } else {
                            input
                        }
                    } else {
                        "orpheus://playlist/$input"
                    }

                    try {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(playlistUri)).apply {
                            setPackage("com.netease.cloudmusic")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(mapOf(
                            "success" to true,
                            "uri" to playlistUri,
                            "message" to "已发起打开歌单详情页 ($playlistUri)。注意：仅定位详情页，非自动全部播放。"
                        ))
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", "打开失败: ${e.localizedMessage}", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
