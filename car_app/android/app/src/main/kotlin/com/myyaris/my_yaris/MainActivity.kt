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
        setupUpdaterChannel(flutterEngine)
        setupVoiceChannel(flutterEngine)
        setupNavitimeGuideChannel(flutterEngine)
        ObdReportExporter.register(this, flutterEngine)
    }

    private fun setupNavitimeGuideChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.myyaris.my_yaris/navitime_guide")
        NavitimeAccessibilityService.onSnapshotUpdated = { snapshot ->
            runOnUiThread {
                try {
                    channel.invokeMethod("onNavitimeSnapshot", snapshot)
                } catch (_: Exception) {
                }
            }
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> {
                    result.success(
                        mapOf(
                            "running" to NavitimeAccessibilityService.isRunning,
                            "snapshot" to NavitimeAccessibilityService.latestSnapshot,
                        )
                    )
                }
                "openAccessibilitySettings" -> {
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
                "getLatestScreenshotJpeg" -> {
                    val ageMs = System.currentTimeMillis() - NavitimeAccessibilityService.latestScreenJpegAtMs
                    val jpeg = NavitimeAccessibilityService.latestScreenJpeg
                    if (jpeg != null && ageMs in 0..20000) {
                        result.success(jpeg)
                    } else {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Volatile
    private var voiceRecordingActive = false
    private var voiceAudioRecord: android.media.AudioRecord? = null
    private var voiceNoiseSuppressor: android.media.audiofx.NoiseSuppressor? = null
    private var voicePcmBuffer: java.io.ByteArrayOutputStream? = null
    private var voiceRecordThread: Thread? = null
    private var voiceMethodChannel: MethodChannel? = null
    private var wakeWordEngine: WakeWordEngine? = null

    private fun setupVoiceChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.myyaris.my_yaris/voice")
        voiceMethodChannel = channel

        wakeWordEngine?.release()
        wakeWordEngine = WakeWordEngine(applicationContext) { keyword ->
            runOnUiThread {
                try {
                    voiceMethodChannel?.invokeMethod(
                        "onWakeWordDetected",
                        mapOf("keyword" to keyword),
                    )
                } catch (_: Exception) {
                }
            }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setWakeWordEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                        if (!granted) {
                            androidx.core.app.ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 4102)
                            result.success(
                                mapOf(
                                    "enabled" to true,
                                    "listening" to false,
                                    "permissionRequested" to true,
                                    "lastError" to "请先允许麦克风权限",
                                )
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            KeepAliveService.start(this)
                        } catch (_: Exception) {
                        }
                    }
                    wakeWordEngine?.setEnabled(enabled)
                    result.success(wakeWordEngine?.getStatus() ?: mapOf("enabled" to false, "listening" to false))
                }
                "pauseWakeWord" -> {
                    wakeWordEngine?.pause()
                    result.success(true)
                }
                "resumeWakeWord" -> {
                    wakeWordEngine?.resume()
                    result.success(true)
                }
                "getWakeWordStatus" -> {
                    result.success(wakeWordEngine?.getStatus() ?: mapOf("enabled" to false, "listening" to false))
                }
                "startRecording" -> {
                    val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    if (!granted) {
                        androidx.core.app.ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 4102)
                        result.success("PERMISSION_REQUESTED")
                        return@setMethodCallHandler
                    }
                    val autoStopOnSilence = call.argument<Boolean>("autoStopOnSilence") ?: false
                    try {
                        wakeWordEngine?.pause()
                        stopVoiceRecorderInternal()
                        val sampleRate = 16000
                        val channelConfig = android.media.AudioFormat.CHANNEL_IN_MONO
                        val audioFormat = android.media.AudioFormat.ENCODING_PCM_16BIT
                        val minBuf = android.media.AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                        val bufSize = maxOf(minBuf * 2, 8192)
                        val sources = intArrayOf(
                            android.media.MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                            android.media.MediaRecorder.AudioSource.VOICE_RECOGNITION,
                            android.media.MediaRecorder.AudioSource.MIC,
                        )
                        var rec: android.media.AudioRecord? = null
                        for (src in sources) {
                            try {
                                val cand = android.media.AudioRecord(src, sampleRate, channelConfig, audioFormat, bufSize)
                                if (cand.state == android.media.AudioRecord.STATE_INITIALIZED) {
                                    rec = cand
                                    break
                                } else {
                                    cand.release()
                                }
                            } catch (_: Exception) {
                            }
                        }
                        if (rec == null) {
                            result.error("RECORDER_INIT_FAILED", "无法初始化车机麦克风", null)
                            return@setMethodCallHandler
                        }
                        try {
                            if (android.media.audiofx.NoiseSuppressor.isAvailable()) {
                                voiceNoiseSuppressor = android.media.audiofx.NoiseSuppressor.create(rec.audioSessionId)?.apply {
                                    enabled = true
                                }
                            }
                        } catch (_: Exception) {
                        }
                        val out = java.io.ByteArrayOutputStream()
                        voiceAudioRecord = rec
                        voicePcmBuffer = out
                        voiceRecordingActive = true
                        rec.startRecording()
                        voiceRecordThread = Thread({
                            val chunk = ByteArray(3200) // 100ms @ 16kHz mono 16-bit
                            val maxBytes = sampleRate * 2 * 12 // 12s safety cap
                            var totalMs = 0L
                            var silentMs = 0L
                            var speechDetected = false
                            var noiseFloorRms = 550.0
                            var calibrationFrames = 0
                            var autoFinished = false

                            while (voiceRecordingActive && out.size() < maxBytes) {
                                val read = try {
                                    rec.read(chunk, 0, chunk.size)
                                } catch (_: Exception) {
                                    -1
                                }
                                if (read > 0) {
                                    synchronized(out) {
                                        out.write(chunk, 0, read)
                                    }
                                    if (autoStopOnSilence) {
                                        val frameMs = (read * 1000L) / (sampleRate * 2L)
                                        totalMs += frameMs
                                        val rms = computePcm16Rms(chunk, read)
                                        if (calibrationFrames < 3) {
                                            noiseFloorRms = if (calibrationFrames == 0) rms else (noiseFloorRms * 0.6 + rms * 0.4)
                                            noiseFloorRms = noiseFloorRms.coerceIn(300.0, 1800.0)
                                            calibrationFrames++
                                        } else {
                                            val speechThresh = maxOf(noiseFloorRms * 2.1, 650.0)
                                            val silenceThresh = maxOf(noiseFloorRms * 1.4, 420.0)
                                            if (rms >= speechThresh) {
                                                speechDetected = true
                                                silentMs = 0L
                                            } else if (speechDetected && rms < silenceThresh) {
                                                silentMs += frameMs
                                                if (silentMs >= 1200L && totalMs >= 900L) {
                                                    autoFinished = true
                                                    break
                                                }
                                            } else if (!speechDetected && totalMs >= 4500L) {
                                                autoFinished = true
                                                break
                                            }
                                        }
                                    }
                                } else if (read < 0) {
                                    break
                                }
                            }

                            if (autoStopOnSilence && voiceRecordingActive) {
                                voiceRecordingActive = false
                                try {
                                    rec.stop()
                                } catch (_: Exception) {
                                }
                                try {
                                    voiceNoiseSuppressor?.release()
                                } catch (_: Exception) {
                                }
                                voiceNoiseSuppressor = null
                                try {
                                    rec.release()
                                } catch (_: Exception) {
                                }
                                voiceAudioRecord = null
                                voiceRecordThread = null
                                val pcmBytes = synchronized(out) { out.toByteArray() }
                                voicePcmBuffer = null

                                var wavPath = ""
                                if (speechDetected && pcmBytes.size >= 3200) {
                                    try {
                                        val wavFile = java.io.File(cacheDir, "ai_voice_input.wav")
                                        writePcm16MonoWav(wavFile, pcmBytes, sampleRate)
                                        wavPath = wavFile.absolutePath
                                    } catch (_: Exception) {
                                    }
                                }
                                runOnUiThread {
                                    try {
                                        voiceMethodChannel?.invokeMethod(
                                            "onAutoRecordingComplete",
                                            mapOf(
                                                "wavPath" to wavPath,
                                                "speechDetected" to speechDetected,
                                                "autoFinished" to autoFinished,
                                            ),
                                        )
                                    } catch (_: Exception) {
                                    }
                                }
                            }
                        }, "MyYarisVoiceRecord").apply { start() }
                        result.success("STARTED")
                    } catch (e: Exception) {
                        stopVoiceRecorderInternal()
                        result.error("RECORDER_ERROR", e.localizedMessage ?: "录音启动失败", null)
                    }
                }
                "stopRecording" -> {
                    try {
                        val pcmBytes = stopVoiceRecorderInternal()
                        if (pcmBytes.size < 1600) {
                            result.success("")
                            return@setMethodCallHandler
                        }
                        val wavFile = java.io.File(cacheDir, "ai_voice_input.wav")
                        writePcm16MonoWav(wavFile, pcmBytes, 16000)
                        result.success(wavFile.absolutePath)
                    } catch (e: Exception) {
                        result.error("STOP_ERROR", e.localizedMessage ?: "录音保存失败", null)
                    }
                }
                "cancelRecording" -> {
                    stopVoiceRecorderInternal()
                    result.success(true)
                }
                "speakOfflineTts" -> {
                    val text = (call.argument<String>("text") ?: "").trim()
                    val vol = ((call.argument<Double>("volume") ?: 0.95).toFloat()).coerceIn(0.1f, 1.0f)
                    if (text.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    speakOfflineChineseTts(text, vol) { ok ->
                        runOnUiThread {
                            try {
                                result.success(ok)
                            } catch (_: Exception) {
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private var offlineTts: android.speech.tts.TextToSpeech? = null
    @Volatile
    private var offlineTtsReady: Boolean = false
    @Volatile
    private var offlineTtsInitializing: Boolean = false
    private val offlineTtsSeq = java.util.concurrent.atomic.AtomicLong(0L)
    private val offlineTtsPending = mutableListOf<Pair<String, (Boolean) -> Unit>>()
    private val offlineTtsCallbacks = java.util.concurrent.ConcurrentHashMap<String, (Boolean) -> Unit>()

    private fun speakOfflineChineseTts(text: String, volume: Float = 0.95f, onDone: (Boolean) -> Unit) {
        val dispatchSpeak: (android.speech.tts.TextToSpeech, String, (Boolean) -> Unit) -> Unit = { engine, msg, cb ->
            val uttId = "myyaris_nav_${offlineTtsSeq.incrementAndGet()}"
            offlineTtsCallbacks[uttId] = cb
            val params = android.os.Bundle().apply {
                putFloat(android.speech.tts.TextToSpeech.Engine.KEY_PARAM_VOLUME, volume)
            }
            val code = engine.speak(msg, android.speech.tts.TextToSpeech.QUEUE_FLUSH, params, uttId)
            if (code != android.speech.tts.TextToSpeech.SUCCESS) {
                offlineTtsCallbacks.remove(uttId)?.invoke(false)
            }
        }

        synchronized(offlineTtsPending) {
            val existing = offlineTts
            if (existing != null && offlineTtsReady) {
                dispatchSpeak(existing, text, onDone)
                return
            }
            offlineTtsPending.add(Pair(text, onDone))
            if (offlineTtsInitializing) {
                return
            }
            offlineTtsInitializing = true
        }

        var createdEngine: android.speech.tts.TextToSpeech? = null
        createdEngine = android.speech.tts.TextToSpeech(applicationContext) { status ->
            val engine = createdEngine
            val queued: List<Pair<String, (Boolean) -> Unit>>
            synchronized(offlineTtsPending) {
                offlineTtsInitializing = false
                queued = offlineTtsPending.toList()
                offlineTtsPending.clear()
                if (status == android.speech.tts.TextToSpeech.SUCCESS && engine != null) {
                    val langRes = engine.setLanguage(java.util.Locale.SIMPLIFIED_CHINESE)
                    if (langRes == android.speech.tts.TextToSpeech.LANG_MISSING_DATA ||
                        langRes == android.speech.tts.TextToSpeech.LANG_NOT_SUPPORTED
                    ) {
                        engine.setLanguage(java.util.Locale.CHINESE)
                    }
                    engine.setSpeechRate(1.05f)
                    engine.setOnUtteranceProgressListener(object : android.speech.tts.UtteranceProgressListener() {
                        override fun onStart(utteranceId: String?) {}
                        override fun onDone(utteranceId: String?) {
                            utteranceId?.let { offlineTtsCallbacks.remove(it)?.invoke(true) }
                        }
                        override fun onStop(utteranceId: String?, interrupted: Boolean) {
                            utteranceId?.let { offlineTtsCallbacks.remove(it)?.invoke(false) }
                        }
                        @Deprecated("Deprecated in Java")
                        override fun onError(utteranceId: String?) {
                            utteranceId?.let { offlineTtsCallbacks.remove(it)?.invoke(false) }
                        }
                        override fun onError(utteranceId: String?, errorCode: Int) {
                            utteranceId?.let { offlineTtsCallbacks.remove(it)?.invoke(false) }
                        }
                    })
                    offlineTts = engine
                    offlineTtsReady = true
                } else {
                    try {
                        engine?.shutdown()
                    } catch (_: Exception) {
                    }
                    offlineTts = null
                    offlineTtsReady = false
                }
            }

            if (offlineTtsReady && engine != null) {
                // Only speak the latest queued request; resolve earlier ones cleanly as interrupted
                for (i in 0 until queued.size - 1) {
                    queued[i].second(false)
                }
                queued.lastOrNull()?.let { (msg, cb) -> dispatchSpeak(engine, msg, cb) }
            } else {
                for ((_, cb) in queued) cb(false)
            }
        }
    }

    private fun computePcm16Rms(buf: ByteArray, len: Int): Double {
        var sum = 0.0
        val samples = len / 2
        if (samples <= 0) return 0.0
        var i = 0
        while (i + 1 < len) {
            val lo = buf[i].toInt() and 0xFF
            val hi = buf[i + 1].toInt()
            val sample = (hi shl 8) or lo
            sum += sample.toDouble() * sample.toDouble()
            i += 2
        }
        return kotlin.math.sqrt(sum / samples)
    }

    private fun stopVoiceRecorderInternal(): ByteArray {
        voiceRecordingActive = false
        try {
            voiceAudioRecord?.stop()
        } catch (_: Exception) {}
        val t = voiceRecordThread
        if (t != null && t !== Thread.currentThread()) {
            try {
                t.join(500)
            } catch (_: Exception) {}
        }
        try {
            voiceNoiseSuppressor?.release()
        } catch (_: Exception) {}
        voiceNoiseSuppressor = null
        try {
            voiceAudioRecord?.release()
        } catch (_: Exception) {}
        voiceAudioRecord = null
        voiceRecordThread = null
        val bytes = voicePcmBuffer?.let { buf ->
            synchronized(buf) { buf.toByteArray() }
        } ?: ByteArray(0)
        voicePcmBuffer = null
        return bytes
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4102 && grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            try {
                KeepAliveService.start(this)
            } catch (_: Exception) {}
            runOnUiThread {
                try {
                    voiceMethodChannel?.invokeMethod("onMicPermissionGranted", true)
                } catch (_: Exception) {}
            }
        }
    }

    private fun writePcm16MonoWav(file: java.io.File, pcmData: ByteArray, sampleRate: Int) {
        val totalDataLen = pcmData.size + 36
        val byteRate = sampleRate * 2
        val header = ByteArray(44)
        header[0] = 'R'.code.toByte(); header[1] = 'I'.code.toByte(); header[2] = 'F'.code.toByte(); header[3] = 'F'.code.toByte()
        header[4] = (totalDataLen and 0xff).toByte()
        header[5] = ((totalDataLen shr 8) and 0xff).toByte()
        header[6] = ((totalDataLen shr 16) and 0xff).toByte()
        header[7] = ((totalDataLen shr 24) and 0xff).toByte()
        header[8] = 'W'.code.toByte(); header[9] = 'A'.code.toByte(); header[10] = 'V'.code.toByte(); header[11] = 'E'.code.toByte()
        header[12] = 'f'.code.toByte(); header[13] = 'm'.code.toByte(); header[14] = 't'.code.toByte(); header[15] = ' '.code.toByte()
        header[16] = 16; header[17] = 0; header[18] = 0; header[19] = 0
        header[20] = 1; header[21] = 0 // PCM
        header[22] = 1; header[23] = 0 // Mono
        header[24] = (sampleRate and 0xff).toByte()
        header[25] = ((sampleRate shr 8) and 0xff).toByte()
        header[26] = ((sampleRate shr 16) and 0xff).toByte()
        header[27] = ((sampleRate shr 24) and 0xff).toByte()
        header[28] = (byteRate and 0xff).toByte()
        header[29] = ((byteRate shr 8) and 0xff).toByte()
        header[30] = ((byteRate shr 16) and 0xff).toByte()
        header[31] = ((byteRate shr 24) and 0xff).toByte()
        header[32] = 2; header[33] = 0 // block align
        header[34] = 16; header[35] = 0 // bits per sample
        header[36] = 'd'.code.toByte(); header[37] = 'a'.code.toByte(); header[38] = 't'.code.toByte(); header[39] = 'a'.code.toByte()
        header[40] = (pcmData.size and 0xff).toByte()
        header[41] = ((pcmData.size shr 8) and 0xff).toByte()
        header[42] = ((pcmData.size shr 16) and 0xff).toByte()
        header[43] = ((pcmData.size shr 24) and 0xff).toByte()
        java.io.FileOutputStream(file).use { fos ->
            fos.write(header)
            fos.write(pcmData)
        }
    }

    private fun setupUpdaterChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.myyaris.my_yaris/updater").setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> {
                    try {
                        val pkgInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(packageName, android.content.pm.PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, 0)
                        }
                        result.success(pkgInfo.versionName ?: "")
                    } catch (e: Exception) {
                        result.success("")
                    }
                }
                "getUpdateCacheDir" -> {
                    try {
                        val dir = java.io.File(cacheDir, "updates")
                        if (!dir.exists()) dir.mkdirs()
                        result.success(dir.absolutePath)
                    } catch (e: Exception) {
                        result.error("DIR_ERROR", e.localizedMessage, null)
                    }
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("path")
                    if (apkPath.isNullOrBlank()) {
                        result.error("INVALID_PATH", "APK path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            val permIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(permIntent)
                            result.success("PERMISSION_REQUIRED")
                            return@setMethodCallHandler
                        }
                        val file = java.io.File(apkPath)
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this,
                            "$packageName.obd_reports",
                            file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success("STARTED")
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.localizedMessage ?: "Failed to launch installer", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
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
                        val allPaths = mutableListOf<String>()
                        allPaths.add(cacheDir.absolutePath)
                        for (d in dirs) {
                            val alt = java.io.File(d, "music_cache").absolutePath
                            if (!allPaths.contains(alt) && java.io.File(alt).exists()) {
                                allPaths.add(alt)
                            }
                        }
                        val stat = StatFs(cacheDir.absolutePath)
                        val freeBytes = stat.availableBytes
                        result.success(mapOf(
                            "path" to cacheDir.absolutePath,
                            "isSdCard" to isSd,
                            "freeBytes" to freeBytes,
                            "allPaths" to allPaths
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
        NavitimeAccessibilityService.onSnapshotUpdated = null
        try {
            wakeWordEngine?.release()
        } catch (_: Exception) {
        }
        wakeWordEngine = null
        stopVoiceRecorderInternal()
        try {
            offlineTts?.stop()
            offlineTts?.shutdown()
        } catch (_: Exception) {
        }
        offlineTts = null
        offlineTtsReady = false
        for (cb in offlineTtsCallbacks.values) {
            try {
                cb(false)
            } catch (_: Exception) {
            }
        }
        offlineTtsCallbacks.clear()
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
        var best = KeepAliveService.latestValidLocation ?: latestLocation
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
            try {
                val cand = lm.getLastKnownLocation(provider) ?: continue
                if (best == null) {
                    best = cand
                } else {
                    val curIsGps = best.provider == LocationManager.GPS_PROVIDER
                    val candIsGps = cand.provider == LocationManager.GPS_PROVIDER
                    val delta = cand.time - best.time
                    if (!(curIsGps && !candIsGps && delta < 20_000L) && (cand.time > best.time || (candIsGps && !curIsGps && delta > -15_000L))) {
                        best = cand
                    }
                }
            } catch (_: Exception) {}
        }
        if (best != null) latestLocation = best
        return best
    }

    private fun setupLocationChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, locationChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTracking" -> {
                    KeepAliveService.start(this)
                    result.success(startNativeLocationTracking())
                }
                "stopTracking" -> {
                    stopNativeLocationTracking()
                    result.success(true)
                }
                "drainBufferedLocations" -> {
                    result.success(KeepAliveService.drainBufferedPoints(this))
                }
                "peekBufferedLocations" -> {
                    val maxCount = call.argument<Int>("maxCount") ?: 120
                    result.success(KeepAliveService.peekBufferedPoints(this, maxCount))
                }
                "ackBufferedLocations" -> {
                    val count = call.argument<Int>("count") ?: 0
                    result.success(KeepAliveService.ackBufferedPoints(this, count))
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

    private fun postNavigationLaunchNotification(navIntent: Intent, title: String) {
        try {
            val channelId = "myyaris_nav_launch_channel"
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? android.app.NotificationManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = android.app.NotificationChannel(
                    channelId,
                    "远程导航目的地提醒",
                    android.app.NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "收到手机发送的目的地时自动唤起 CAR NAVITIME"
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                }
                nm.createNotificationChannel(ch)
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                android.app.PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = android.app.PendingIntent.getActivity(this, 2001, navIntent, flags)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                android.app.Notification.Builder(this, channelId)
            } else {
                @Suppress("DEPRECATION")
                android.app.Notification.Builder(this)
            }
            val destLabel = if (title.isNotBlank()) title else "新导航目的地"
            val notification = builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("正在启动 CAR NAVITIME")
                .setContentText("目的地：$destLabel（轻点立即导航）")
                .setCategory(android.app.Notification.CATEGORY_NAVIGATION)
                .setAutoCancel(true)
                .setTimeoutAfter(12_000L)
                .setContentIntent(pendingIntent)
                .setFullScreenIntent(pendingIntent, true)
                .build()
            nm.notify(2001, notification)
        } catch (_: Exception) {}
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
                        val navIntent = Intent(Intent.ACTION_VIEW, Uri.parse(geoUriString)).apply {
                            setPackage("com.navitime.local.carnavitime")
                            addFlags(
                                Intent.FLAG_ACTIVITY_NEW_TASK or
                                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                            )
                        }
                        val targetIntent = if (navIntent.resolveActivity(packageManager) != null) {
                            navIntent
                        } else {
                            Intent(Intent.ACTION_VIEW, Uri.parse(geoUriString)).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        }

                        // Always attempt direct launch (works immediately in foreground or when SYSTEM_ALERT_WINDOW is granted)
                        applicationContext.startActivity(targetIntent)

                        // Also post a high-priority full-screen / heads-up notification when overlay permission is missing
                        // so Android 10+ background activity launch restrictions never swallow the destination silently.
                        val canOverlay = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
                        if (!canOverlay) {
                            postNavigationLaunchNotification(targetIntent, title)
                        }

                        result.success(
                            mapOf(
                                "success" to true,
                                "mode" to if (canOverlay) "direct_overlay" else "direct_with_notification",
                                "uri" to geoUriString
                            )
                        )
                    } catch (ex: Exception) {
                        result.error("LAUNCH_FAILED", ex.localizedMessage ?: "Failed to launch $geoUriString", null)
                    }
                }
                "hasOverlayPermission" -> {
                    val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)
                    result.success(granted)
                }
                "openOverlaySettings" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            ).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OVERLAY_SETTINGS_FAILED", e.localizedMessage, null)
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
