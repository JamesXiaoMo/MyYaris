package com.myyaris.my_yaris

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import androidx.core.content.ContextCompat
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.KeywordSpotterConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig

/**
 * Offline wake-word listener ("Hey Yaris") backed by sherpa-onnx GigaSpeech 3.3M int8 KWS.
 *
 * Uses VOICE_COMMUNICATION with hardware AcousticEchoCanceler + NoiseSuppressor when available
 * so car speakers playing music / navigation audio do not drown out the driver's voice.
 */
class WakeWordEngine(
    private val context: Context,
    private val onWakeWordDetected: (String) -> Unit,
) {
    companion object {
        private const val TAG = "WakeWordEngine"
        private const val SAMPLE_RATE = 16000
        private const val CHUNK_SAMPLES = 1600 // 100 ms per read
        private const val COOLDOWN_MS = 2500L
        private const val KWS_ASSET_DIR = "kws"
    }

    private val lock = Any()
    private var spotter: KeywordSpotter? = null
    private var stream: OnlineStream? = null
    private var audioRecord: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var workerThread: Thread? = null

    @Volatile
    private var desiredEnabled: Boolean = false

    @Volatile
    private var paused: Boolean = false

    @Volatile
    private var running: Boolean = false

    @Volatile
    private var modelLoaded: Boolean = false

    @Volatile
    private var aecActive: Boolean = false

    @Volatile
    private var nsActive: Boolean = false

    @Volatile
    private var lastError: String? = null

    @Volatile
    private var lastTriggerAtMs: Long = 0L

    fun getStatus(): Map<String, Any?> = mapOf(
        "enabled" to desiredEnabled,
        "listening" to (running && !paused),
        "paused" to paused,
        "modelLoaded" to modelLoaded,
        "aecEnabled" to aecActive,
        "nsEnabled" to nsActive,
        "lastError" to lastError,
    )

    fun setEnabled(enabled: Boolean): Boolean {
        synchronized(lock) {
            desiredEnabled = enabled
            if (!enabled) {
                paused = false
                stopLoopLocked()
                Log.i(TAG, "Wake-word listening disabled")
                return true
            }
            if (paused) {
                Log.i(TAG, "Wake-word enabled while paused; will resume when unpaused")
                return true
            }
            return startLoopLocked()
        }
    }

    /** Temporarily release AudioRecord while voice command recording or TTS is active. */
    fun pause() {
        synchronized(lock) {
            if (paused && !running) return
            paused = true
            stopLoopLocked()
            Log.i(TAG, "Wake-word listening paused")
        }
    }

    /** Resume wake-word listening if user has it enabled. */
    fun resume() {
        synchronized(lock) {
            paused = false
            if (desiredEnabled && !running) {
                startLoopLocked()
            }
        }
    }

    fun release() {
        synchronized(lock) {
            desiredEnabled = false
            paused = false
            stopLoopLocked()
            try {
                stream?.release()
            } catch (_: Exception) {
            }
            stream = null
            try {
                spotter?.release()
            } catch (_: Exception) {
            }
            spotter = null
            modelLoaded = false
            Log.i(TAG, "WakeWordEngine released")
        }
    }

    private fun ensureSpotterLocked(): Boolean {
        if (spotter != null && stream != null) return true
        return try {
            val transducer = OnlineTransducerModelConfig(
                encoder = "$KWS_ASSET_DIR/encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                decoder = "$KWS_ASSET_DIR/decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
                joiner = "$KWS_ASSET_DIR/joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx",
            )
            val modelConfig = OnlineModelConfig(
                transducer = transducer,
                tokens = "$KWS_ASSET_DIR/tokens.txt",
                numThreads = 2,
                debug = false,
                provider = "cpu",
                modelType = "zipformer2",
            )
            val featConfig = FeatureConfig(
                sampleRate = SAMPLE_RATE,
                featureDim = 80,
            )
            val kwsConfig = KeywordSpotterConfig(
                featConfig = featConfig,
                modelConfig = modelConfig,
                maxActivePaths = 4,
                keywordsFile = "$KWS_ASSET_DIR/keywords.txt",
                keywordsScore = 1.5f,
                keywordsThreshold = 0.25f,
                numTrailingBlanks = 1,
            )
            val created = KeywordSpotter(
                assetManager = context.assets,
                config = kwsConfig,
            )
            val createdStream = created.createStream("")
            spotter = created
            stream = createdStream
            modelLoaded = true
            lastError = null
            Log.i(TAG, "Sherpa-ONNX KeywordSpotter initialized (GigaSpeech 3.3M int8, keyword=HEY YARIS)")
            true
        } catch (e: Throwable) {
            lastError = "模型加载失败: ${e.message}"
            modelLoaded = false
            Log.e(TAG, "Failed to initialize Sherpa-ONNX KeywordSpotter", e)
            false
        }
    }

    private fun startLoopLocked(): Boolean {
        if (running) return true
        val hasMic = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasMic) {
            lastError = "缺少麦克风权限"
            Log.w(TAG, "Cannot start WakeWordEngine: RECORD_AUDIO not granted")
            return false
        }
        if (!ensureSpotterLocked()) return false

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufBytes = maxOf(minBuf * 2, CHUNK_SAMPLES * 2 * 4)

        // IMPORTANT: Never use VOICE_COMMUNICATION or hardware AcousticEchoCanceler on Android
        // car boxes (e.g. OttoAibox P3 Pro / CarPlay bridge). VOICE_COMMUNICATION / AEC forces
        // the audio HAL into call/VoIP routing mode, which causes severe clipping/crackling on
        // STREAM_MUSIC and hijacks steering-wheel volume & media skip buttons.
        // VOICE_RECOGNITION is designed for always-on voice assistants without touching media output.
        val sources = intArrayOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            MediaRecorder.AudioSource.MIC,
        )
        var rec: AudioRecord? = null
        var chosenSource = -1
        for (src in sources) {
            try {
                val candidate = AudioRecord(
                    src,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufBytes,
                )
                if (candidate.state == AudioRecord.STATE_INITIALIZED) {
                    rec = candidate
                    chosenSource = src
                    break
                } else {
                    candidate.release()
                }
            } catch (_: Exception) {
            }
        }
        if (rec == null) {
            lastError = "无法初始化车机麦克风"
            Log.e(TAG, "Failed to initialize AudioRecord for WakeWordEngine")
            return false
        }

        // Keep AEC/NS disabled on continuous background capture so media output stays pure Hi-Fi stereo
        aecActive = false
        nsActive = false

        try {
            rec.startRecording()
        } catch (e: Exception) {
            lastError = "麦克风启动失败: ${e.message}"
            releaseAudioEffectsLocked()
            try {
                rec.release()
            } catch (_: Exception) {
            }
            Log.e(TAG, "AudioRecord.startRecording failed", e)
            return false
        }

        audioRecord = rec
        running = true
        lastError = null
        Log.i(TAG, "Wake-word listening started (source=$chosenSource, AEC=$aecActive, NS=$nsActive)")

        val thread = Thread({
            runDecodeLoop(rec)
        }, "MyYarisWakeWord").apply {
            isDaemon = true
            start()
        }
        workerThread = thread
        return true
    }

    private fun runDecodeLoop(rec: AudioRecord) {
        val pcm = ShortArray(CHUNK_SAMPLES)
        val floats = FloatArray(CHUNK_SAMPLES)
        val kws = spotter ?: return
        val st = stream ?: return

        while (running) {
            val read = try {
                rec.read(pcm, 0, pcm.size)
            } catch (_: Exception) {
                -1
            }
            if (read <= 0) {
                if (!running) break
                try {
                    Thread.sleep(30)
                } catch (_: InterruptedException) {
                    break
                }
                continue
            }

            for (i in 0 until read) {
                floats[i] = pcm[i] / 32768.0f
            }
            val input = if (read == floats.size) floats else floats.copyOf(read)

            var detectedKeyword = ""
            synchronized(lock) {
                if (!running || spotter == null || stream == null) return@synchronized
                try {
                    st.acceptWaveform(input, SAMPLE_RATE)
                    while (kws.isReady(st)) {
                        kws.decode(st)
                    }
                    val res = kws.getResult(st)
                    if (res.keyword.isNotBlank()) {
                        kws.reset(st)
                        detectedKeyword = res.keyword.trim()
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "KWS decode error", e)
                }
            }

            if (detectedKeyword.isNotEmpty()) {
                val now = System.currentTimeMillis()
                if (now - lastTriggerAtMs >= COOLDOWN_MS) {
                    lastTriggerAtMs = now
                    Log.i(TAG, "Wake word detected: '$detectedKeyword'")
                    // Immediately release mic before notifying Flutter so recording can start cleanly
                    pause()
                    playWakeChime()
                    try {
                        onWakeWordDetected(detectedKeyword)
                    } catch (e: Exception) {
                        Log.e(TAG, "onWakeWordDetected callback failed", e)
                    }
                    break
                }
            }
        }
    }

    private fun playWakeChime() {
        try {
            val tg = ToneGenerator(AudioManager.STREAM_MUSIC, 70)
            tg.startTone(ToneGenerator.TONE_PROP_BEEP, 130)
            Thread {
                try {
                    Thread.sleep(220)
                } catch (_: InterruptedException) {
                }
                try {
                    tg.release()
                } catch (_: Exception) {
                }
            }.start()
        } catch (e: Exception) {
            Log.w(TAG, "Wake chime note: ${e.message}")
        }
    }

    private fun stopLoopLocked() {
        running = false
        val rec = audioRecord
        audioRecord = null
        try {
            rec?.stop()
        } catch (_: Exception) {
        }
        val t = workerThread
        workerThread = null
        if (t != null && t !== Thread.currentThread()) {
            try {
                t.join(400)
            } catch (_: Exception) {
            }
        }
        releaseAudioEffectsLocked()
        try {
            rec?.release()
        } catch (_: Exception) {
        }
        aecActive = false
        nsActive = false
    }

    private fun releaseAudioEffectsLocked() {
        try {
            aec?.release()
        } catch (_: Exception) {
        }
        aec = null
        try {
            ns?.release()
        } catch (_: Exception) {
        }
        ns = null
    }
}
