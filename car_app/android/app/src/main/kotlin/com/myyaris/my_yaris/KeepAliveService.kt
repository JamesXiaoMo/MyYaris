package com.myyaris.my_yaris

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class KeepAliveService : Service() {
    companion object {
        const val CHANNEL_ID = "myyaris_keepalive_channel"
        const val NOTIFICATION_ID = 1001
        private const val BUFFER_FILE_NAME = "native_trip_points.jsonl"
        private const val MAX_BUFFERED_LINES = 2000

        private val bufferLock = Any()

        @Volatile
        var latestValidLocation: Location? = null
            private set

        fun start(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java)
            context.stopService(intent)
        }

        fun drainBufferedPoints(context: Context, maxCount: Int = 200): List<Map<String, Any?>> {
            synchronized(bufferLock) {
                val file = File(context.filesDir, BUFFER_FILE_NAME)
                if (!file.exists()) return emptyList()
                val lines = try {
                    file.readLines().filter { it.isNotBlank() }
                } catch (_: Exception) {
                    return emptyList()
                }
                if (lines.isEmpty()) return emptyList()

                val takeCount = minOf(maxCount, lines.size)
                val taken = lines.subList(0, takeCount)
                val remaining = if (takeCount < lines.size) lines.subList(takeCount, lines.size) else emptyList()
                try {
                    if (remaining.isEmpty()) {
                        file.delete()
                    } else {
                        file.writeText(remaining.joinToString("\n") + "\n")
                    }
                } catch (_: Exception) {}

                val result = ArrayList<Map<String, Any?>>(taken.size)
                for (line in taken) {
                    try {
                        val obj = JSONObject(line)
                        val map = HashMap<String, Any?>()
                        map["latitude"] = obj.getDouble("latitude")
                        map["longitude"] = obj.getDouble("longitude")
                        map["speed_kmh"] = if (obj.isNull("speed_kmh")) null else obj.getDouble("speed_kmh")
                        map["accuracy_m"] = if (obj.isNull("accuracy_m")) null else obj.getDouble("accuracy_m")
                        map["timestamp_ms"] = obj.getLong("timestamp_ms")
                        map["provider"] = obj.optString("provider", "gps")
                        result.add(map)
                    } catch (_: Exception) {}
                }
                return result
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var locationManager: LocationManager? = null
    private var locationListener: LocationListener? = null
    private var samplerExecutor: ScheduledExecutorService? = null
    private var lastSampledTimeMs: Long = 0L

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForegroundCompat()
        acquireWakeLock()
        startNativeGpsSampler()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        startNativeGpsSampler()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopNativeGpsSampler()
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val hasLoc = hasLocationPermission()
            val types = if (hasLoc && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            }
            try {
                startForeground(NOTIFICATION_ID, notification, types)
            } catch (_: Exception) {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    private fun isBetterLocation(candidate: Location, current: Location?): Boolean {
        if (current == null) return true
        val timeDelta = candidate.time - current.time
        val isGps = candidate.provider == LocationManager.GPS_PROVIDER
        val curIsGps = current.provider == LocationManager.GPS_PROVIDER
        // Never let a coarse network fix overwrite a fresh GPS fix (< 20s old)
        if (curIsGps && !isGps && timeDelta < 20_000L) {
            return false
        }
        if (timeDelta > 15_000L) return true
        if (timeDelta < -15_000L) return false
        if (isGps && !curIsGps) return true
        return candidate.time >= current.time
    }

    private fun startNativeGpsSampler() {
        if (!hasLocationPermission()) return
        val lm = locationManager ?: (getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.also {
            locationManager = it
        } ?: return

        if (locationListener == null) {
            val listener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    if (isBetterLocation(location, latestValidLocation)) {
                        latestValidLocation = location
                    }
                }
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
                @Deprecated("Deprecated in Java")
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
            }
            locationListener = listener
            try {
                if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                    lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 5000L, 0f, listener, Looper.getMainLooper())
                }
            } catch (_: Exception) {}
            try {
                if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                    lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 10000L, 0f, listener, Looper.getMainLooper())
                }
            } catch (_: Exception) {}
        }

        if (samplerExecutor == null) {
            val exec = Executors.newSingleThreadScheduledExecutor()
            samplerExecutor = exec
            exec.scheduleAtFixedRate({
                try {
                    recordCurrentSample(lm)
                } catch (_: Exception) {}
            }, 2L, 10L, TimeUnit.SECONDS)
        }
    }

    private fun recordCurrentSample(lm: LocationManager) {
        if (!hasLocationPermission()) return
        var best = latestValidLocation
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
            try {
                val cand = lm.getLastKnownLocation(provider) ?: continue
                if (isBetterLocation(cand, best)) {
                    best = cand
                }
            } catch (_: Exception) {}
        }
        val loc = best ?: return
        latestValidLocation = loc

        if (loc.latitude == 0.0 && loc.longitude == 0.0) return
        val nowMs = System.currentTimeMillis()
        // Use actual sample time, avoiding stale cached points older than 60s
        if (nowMs - loc.time > 60_000L && lastSampledTimeMs == loc.time) return
        lastSampledTimeMs = loc.time

        val obj = JSONObject().apply {
            put("latitude", loc.latitude)
            put("longitude", loc.longitude)
            put("speed_kmh", if (loc.hasSpeed()) (loc.speed * 3.6).toDouble() else JSONObject.NULL)
            put("accuracy_m", if (loc.hasAccuracy()) loc.accuracy.toDouble() else JSONObject.NULL)
            put("timestamp_ms", nowMs)
            put("provider", loc.provider ?: "gps")
        }

        synchronized(bufferLock) {
            val file = File(filesDir, BUFFER_FILE_NAME)
            try {
                file.appendText(obj.toString() + "\n")
                if (file.length() > 320_000L) {
                    val lines = file.readLines().filter { it.isNotBlank() }
                    if (lines.size > MAX_BUFFERED_LINES) {
                        val trimmed = lines.subList(lines.size - MAX_BUFFERED_LINES, lines.size)
                        file.writeText(trimmed.joinToString("\n") + "\n")
                    }
                }
            } catch (_: Exception) {}
        }
    }

    private fun stopNativeGpsSampler() {
        samplerExecutor?.shutdownNow()
        samplerExecutor = null
        val lm = locationManager
        val listener = locationListener
        if (lm != null && listener != null) {
            try {
                lm.removeUpdates(listener)
            } catch (_: Exception) {}
        }
        locationListener = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "MyYaris 车机后台常驻服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持车机与远程后端长轮询及轨迹记录常驻"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: Intent(this, MainActivity::class.java)
        launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("MyYaris 车机助手")
            .setContentText("后台行程记录与远程播控运行中")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock == null) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = powerManager?.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "MyYaris::KeepAliveWakeLock"
                )?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            wakeLock = null
        } catch (_: Exception) {}
    }
}
