package com.myyaris.my_yaris

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

/**
 * Reads live navigation cues (upcoming intersections, lane guidance boxes, VICS traffic
 * color bars, turn arrows, two-ahead turns, speed limit signs, ETA, remaining distance)
 * directly from CAR NAVITIME when it is visible on screen (full-screen or split-screen).
 * Uses Android 11+ AccessibilityService.takeScreenshot() on a dedicated background
 * executor for zero main-thread jank and zero MediaProjection dialogs.
 */
class NavitimeAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "NavitimeGuide"
        private const val NAVITIME_PKG = "com.navitime.local.carnavitime"
        private const val ID_PREFIX = "$NAVITIME_PKG:id/"
        private const val VISUAL_CACHE_TTL_MS = 6000L

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var latestSnapshot: Map<String, Any>? = null
            private set

        @Volatile
        var latestScreenJpeg: ByteArray? = null
            private set

        @Volatile
        var latestScreenJpegAtMs: Long = 0L
            private set

        @Volatile
        var onSnapshotUpdated: ((Map<String, Any>) -> Unit)? = null

        private val DIGIT_TEMPLATES: Map<Int, IntArray> = mapOf(
            0 to intArrayOf(
                0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0,
            ),
            1 to intArrayOf(
                0,0,1,0,0, 0,1,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,0,1,0,0, 0,1,1,1,0,
            ),
            2 to intArrayOf(
                0,1,1,1,0, 1,0,0,0,1, 0,0,0,0,1, 0,0,1,1,0, 0,1,0,0,0, 1,0,0,0,0, 1,1,1,1,1,
            ),
            3 to intArrayOf(
                0,1,1,1,0, 1,0,0,0,1, 0,0,0,0,1, 0,0,1,1,0, 0,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0,
            ),
            4 to intArrayOf(
                0,0,0,1,0, 0,0,1,1,0, 0,1,0,1,0, 1,0,0,1,0, 1,1,1,1,1, 0,0,0,1,0, 0,0,0,1,0,
            ),
            5 to intArrayOf(
                1,1,1,1,1, 1,0,0,0,0, 1,1,1,1,0, 0,0,0,0,1, 0,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0,
            ),
            6 to intArrayOf(
                0,1,1,1,0, 1,0,0,0,0, 1,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0,
            ),
            7 to intArrayOf(
                1,1,1,1,1, 0,0,0,0,1, 0,0,0,1,0, 0,0,1,0,0, 0,0,1,0,0, 0,1,0,0,0, 0,1,0,0,0,
            ),
            8 to intArrayOf(
                0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,0,
            ),
            9 to intArrayOf(
                0,1,1,1,0, 1,0,0,0,1, 1,0,0,0,1, 0,1,1,1,1, 0,0,0,0,1, 0,0,0,1,0, 0,1,1,0,0,
            ),
        )

        private val VALID_JP_SPEED_LIMITS = setOf(20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120)
    }

    private data class RawGuideItem(
        val interName: String,
        val distanceText: String,
        val remainTime: String,
        val itemBottom: Int,
        val trafficBounds: Rect?,
        val laneBounds: Rect?,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val workerExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "NavitimeVisionWorker").apply { isDaemon = true }
    }
    private var lastProcessMs: Long = 0L
    private var lastScreenshotMs: Long = 0L
    private var lastJpegEncodeMs: Long = 0L
    private val screenshotInFlight = AtomicBoolean(false)

    // Short-TTL visual cache so non-screenshot frames never erase lane/traffic/turn/speed-limit
    @Volatile private var lastVisualAtMs: Long = 0L
    @Volatile private var cachedNextTurnDir: String = ""
    @Volatile private var cachedTwoAheadDir: String = ""
    @Volatile private var cachedSpeedLimit: Int? = null
    private val cachedTrafficByInter = ConcurrentHashMap<String, String>()
    private val cachedLaneByInter = ConcurrentHashMap<String, Pair<Int, List<Int>>>()

    override fun onServiceConnected() {
        super.onServiceConnected()
        isRunning = true
        Log.i(TAG, "NavitimeAccessibilityService connected")
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        isRunning = false
        try {
            workerExecutor.shutdownNow()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg != NAVITIME_PKG) return

        val now = SystemClock.elapsedRealtime()
        if (now - lastProcessMs < 1400L) return
        lastProcessMs = now

        val root = findNavitimeRootWindow() ?: return
        try {
            parseWindow(root, now)
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to parse CAR NAVITIME window: ${e.message}")
        } finally {
            try {
                root.recycle()
            } catch (_: Exception) {
            }
        }
    }

    /**
     * Searches all interactive windows so split-screen or floating voice overlays
     * never prevent reading CAR NAVITIME's view tree.
     */
    private fun findNavitimeRootWindow(): AccessibilityNodeInfo? {
        try {
            val allWindows = windows
            if (allWindows != null) {
                for (w in allWindows) {
                    val r = w.root ?: continue
                    if (r.packageName?.toString() == NAVITIME_PKG) {
                        return r
                    }
                    r.recycle()
                }
            }
        } catch (_: Exception) {
        }
        val active = rootInActiveWindow
        if (active != null && active.packageName?.toString() == NAVITIME_PKG) {
            return active
        }
        active?.recycle()
        return null
    }

    private fun parseWindow(root: AccessibilityNodeInfo, nowMs: Long) {
        val nextDestName = firstTextById(root, "${ID_PREFIX}next_destination_name")
        val nextDestDist = firstTextById(root, "${ID_PREFIX}next_destination_distance")
        val twoAheadDist = firstTextById(root, "${ID_PREFIX}two_ahead_direction_distance")
        val arrivalTime = firstTextById(root, "${ID_PREFIX}arrival_time")
        val remainingDist = firstTextById(root, "${ID_PREFIX}remaining_dis_text")

        val nextTurnRect = firstBoundsById(root, "${ID_PREFIX}next_destination_direction_image")
        val twoAheadTurnRect = firstBoundsById(root, "${ID_PREFIX}two_ahead_direction_image")
        val speedLimitRect = firstBoundsById(root, "${ID_PREFIX}speed_limit_view")

        val items = mutableListOf<RawGuideItem>()
        val listNodes = root.findAccessibilityNodeInfosByViewId("${ID_PREFIX}express_guide_list_item")
        for (itemNode in listNodes) {
            val interName = firstTextById(itemNode, "${ID_PREFIX}inter_name")
            val distText = firstTextById(itemNode, "${ID_PREFIX}distance_from_current")
            val remainTime = firstTextById(itemNode, "${ID_PREFIX}remain_time")
            val itemRect = Rect()
            itemNode.getBoundsInScreen(itemRect)

            val trafficRect = firstBoundsById(itemNode, "${ID_PREFIX}traffic_info")
            val laneRect = firstBoundsById(itemNode, "${ID_PREFIX}next_intersection_lane_info")

            if (interName.isNotEmpty() || distText.isNotEmpty()) {
                items.add(
                    RawGuideItem(
                        interName = interName,
                        distanceText = distText,
                        remainTime = remainTime,
                        itemBottom = itemRect.bottom,
                        trafficBounds = trafficRect,
                        laneBounds = laneRect,
                    )
                )
            }
            itemNode.recycle()
        }

        items.sortByDescending { it.itemBottom }

        if (nextDestName.isEmpty() && items.isEmpty() && arrivalTime.isEmpty()) {
            return
        }

        val needsVisualSample = items.any { it.trafficBounds != null || it.laneBounds != null } ||
            nextTurnRect != null || speedLimitRect != null
        if (needsVisualSample &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            nowMs - lastScreenshotMs >= 2000L &&
            screenshotInFlight.compareAndSet(false, true)
        ) {
            lastScreenshotMs = nowMs
            try {
                // Run screenshot callback + pixel/JPEG work off the main thread
                takeScreenshot(
                    Display.DEFAULT_DISPLAY,
                    workerExecutor,
                    object : TakeScreenshotCallback {
                        override fun onSuccess(screenshot: ScreenshotResult) {
                            var swBitmap: Bitmap? = null
                            try {
                                val hwBitmap = Bitmap.wrapHardwareBuffer(
                                    screenshot.hardwareBuffer,
                                    screenshot.colorSpace
                                )
                                swBitmap = hwBitmap?.copy(Bitmap.Config.ARGB_8888, false)
                                hwBitmap?.recycle()
                            } catch (e: Throwable) {
                                Log.w(TAG, "Screenshot bitmap copy failed: ${e.message}")
                            } finally {
                                try {
                                    screenshot.hardwareBuffer.close()
                                } catch (_: Exception) {
                                }
                                screenshotInFlight.set(false)
                            }
                            try {
                                if (swBitmap != null && nowMs - lastJpegEncodeMs >= 4000L) {
                                    lastJpegEncodeMs = nowMs
                                    encodeLatestJpeg(swBitmap)
                                }
                                publishSnapshot(
                                    nextDestName = nextDestName,
                                    nextDestDist = nextDestDist,
                                    twoAheadDist = twoAheadDist,
                                    arrivalTime = arrivalTime,
                                    remainingDist = remainingDist,
                                    nextTurnRect = nextTurnRect,
                                    twoAheadTurnRect = twoAheadTurnRect,
                                    speedLimitRect = speedLimitRect,
                                    items = items,
                                    bitmap = swBitmap,
                                    nowMs = nowMs,
                                )
                            } catch (e: Throwable) {
                                Log.w(TAG, "Visual processing error: ${e.message}")
                            } finally {
                                swBitmap?.recycle()
                            }
                        }

                        override fun onFailure(errorCode: Int) {
                            screenshotInFlight.set(false)
                            publishSnapshot(
                                nextDestName = nextDestName,
                                nextDestDist = nextDestDist,
                                twoAheadDist = twoAheadDist,
                                arrivalTime = arrivalTime,
                                remainingDist = remainingDist,
                                nextTurnRect = nextTurnRect,
                                twoAheadTurnRect = twoAheadTurnRect,
                                speedLimitRect = speedLimitRect,
                                items = items,
                                bitmap = null,
                                nowMs = nowMs,
                            )
                        }
                    }
                )
            } catch (e: Throwable) {
                screenshotInFlight.set(false)
                publishSnapshot(
                    nextDestName = nextDestName,
                    nextDestDist = nextDestDist,
                    twoAheadDist = twoAheadDist,
                    arrivalTime = arrivalTime,
                    remainingDist = remainingDist,
                    nextTurnRect = nextTurnRect,
                    twoAheadTurnRect = twoAheadTurnRect,
                    speedLimitRect = speedLimitRect,
                    items = items,
                    bitmap = null,
                    nowMs = nowMs,
                )
            }
        } else {
            publishSnapshot(
                nextDestName = nextDestName,
                nextDestDist = nextDestDist,
                twoAheadDist = twoAheadDist,
                arrivalTime = arrivalTime,
                remainingDist = remainingDist,
                nextTurnRect = nextTurnRect,
                twoAheadTurnRect = twoAheadTurnRect,
                speedLimitRect = speedLimitRect,
                items = items,
                bitmap = null,
                nowMs = nowMs,
            )
        }
    }

    private fun encodeLatestJpeg(bmp: Bitmap) {
        var scaled: Bitmap? = null
        try {
            val target = if (bmp.width > 960) {
                val ratio = 960f / bmp.width
                scaled = Bitmap.createScaledBitmap(bmp, 960, (bmp.height * ratio).roundToInt(), true)
                scaled
            } else {
                bmp
            }
            val out = ByteArrayOutputStream()
            target.compress(Bitmap.CompressFormat.JPEG, 60, out)
            latestScreenJpeg = out.toByteArray()
            latestScreenJpegAtMs = System.currentTimeMillis()
        } catch (_: Throwable) {
        } finally {
            scaled?.recycle()
        }
    }

    private fun publishSnapshot(
        nextDestName: String,
        nextDestDist: String,
        twoAheadDist: String,
        arrivalTime: String,
        remainingDist: String,
        nextTurnRect: Rect?,
        twoAheadTurnRect: Rect?,
        speedLimitRect: Rect?,
        items: List<RawGuideItem>,
        bitmap: Bitmap?,
        nowMs: Long,
    ) {
        val visualCacheFresh = (nowMs - lastVisualAtMs) <= VISUAL_CACHE_TTL_MS

        val nextTurnDir = if (bitmap != null && nextTurnRect != null) {
            classifyTurnArrow(bitmap, nextTurnRect).also { cachedNextTurnDir = it }
        } else if (visualCacheFresh) {
            cachedNextTurnDir
        } else {
            ""
        }

        val twoAheadDir = if (bitmap != null && twoAheadTurnRect != null) {
            classifyTurnArrow(bitmap, twoAheadTurnRect).also { cachedTwoAheadDir = it }
        } else if (visualCacheFresh) {
            cachedTwoAheadDir
        } else {
            ""
        }

        val speedLimit = if (bitmap != null) {
            val detected = if (speedLimitRect != null) classifySpeedLimit(bitmap, speedLimitRect) else null
            cachedSpeedLimit = detected
            detected
        } else if (visualCacheFresh) {
            cachedSpeedLimit
        } else {
            null
        }

        if (bitmap != null) {
            lastVisualAtMs = nowMs
        }

        val parsedItems = items.map { item ->
            val key = item.interName.ifEmpty { item.distanceText }
            val traffic = if (bitmap != null && item.trafficBounds != null) {
                classifyTrafficBar(bitmap, item.trafficBounds).also {
                    if (key.isNotEmpty()) cachedTrafficByInter[key] = it
                }
            } else if (visualCacheFresh && key.isNotEmpty()) {
                cachedTrafficByInter[key] ?: "unknown"
            } else {
                "unknown"
            }

            val laneResult = if (bitmap != null && item.laneBounds != null) {
                parseLaneGuide(bitmap, item.laneBounds)?.also {
                    if (key.isNotEmpty()) cachedLaneByInter[key] = it
                }
            } else if (visualCacheFresh && item.laneBounds != null && key.isNotEmpty()) {
                cachedLaneByInter[key]
            } else {
                null
            }

            val map = mutableMapOf<String, Any>(
                "inter_name" to item.interName,
                "distance_text" to item.distanceText,
                "remain_time" to item.remainTime,
                "traffic" to traffic,
                "has_lane_guide" to (item.laneBounds != null),
            )
            if (laneResult != null) {
                map["lane_count"] = laneResult.first
                map["recommended_lanes"] = laneResult.second
                map["lane_summary"] = buildLaneSummary(laneResult.first, laneResult.second)
            }
            map
        }

        val snapshot = mutableMapOf<String, Any>(
            "timestamp_ms" to System.currentTimeMillis(),
            "next_destination_name" to nextDestName,
            "next_destination_distance" to nextDestDist,
            "next_turn_direction" to nextTurnDir,
            "two_ahead_distance" to twoAheadDist,
            "two_ahead_direction" to twoAheadDir,
            "arrival_time" to arrivalTime,
            "remaining_distance_km" to remainingDist,
            "upcoming_intersections" to parsedItems,
        )
        if (speedLimit != null) {
            snapshot["speed_limit_kmh"] = speedLimit
        }
        latestSnapshot = snapshot
        mainHandler.post {
            onSnapshotUpdated?.invoke(snapshot)
        }
    }

    private fun readRegionPixels(bmp: Bitmap, rect: Rect): Pair<IntArray, Rect>? {
        val x0 = rect.left.coerceIn(0, bmp.width - 1)
        val x1 = rect.right.coerceIn(x0 + 1, bmp.width)
        val y0 = rect.top.coerceIn(0, bmp.height - 1)
        val y1 = rect.bottom.coerceIn(y0 + 1, bmp.height)
        val w = x1 - x0
        val h = y1 - y0
        if (w <= 0 || h <= 0) return null
        val buf = IntArray(w * h)
        bmp.getPixels(buf, 0, w, x0, y0, w, h)
        return Pair(buf, Rect(0, 0, w, h))
    }

    private fun classifyTurnArrow(bmp: Bitmap, rect: Rect): String {
        val (pixels, r) = readRegionPixels(bmp, rect) ?: return ""
        val w = r.width()
        val h = r.height()
        if (w < 8 || h < 8) return ""

        val midY = h / 2
        var topXSum = 0.0
        var topCount = 0
        var botXSum = 0.0
        var botCount = 0
        for (py in 0 until h) {
            val rowOff = py * w
            for (px in 0 until w) {
                val c = pixels[rowOff + px]
                if (Color.red(c) > 200 && Color.green(c) > 200 && Color.blue(c) > 200) {
                    val nx = px.toDouble() / w
                    if (py < midY) {
                        topXSum += nx; topCount++
                    } else {
                        botXSum += nx; botCount++
                    }
                }
            }
        }
        if (topCount < 6 || botCount < 6) return ""
        val delta = (topXSum / topCount) - (botXSum / botCount)
        return when {
            delta <= -0.18 -> "左转"
            delta <= -0.07 -> "向左前方行驶"
            delta >= 0.18 -> "右转"
            delta >= 0.07 -> "向右前方行驶"
            else -> "直行"
        }
    }

    private fun classifySpeedLimit(bmp: Bitmap, rect: Rect): Int? {
        val (pixels, r) = readRegionPixels(bmp, rect) ?: return null
        val w = r.width()
        val h = r.height()
        if (w < 20 || h < 20) return null

        var redBorderPx = 0
        for (px in 0 until w) {
            for (py in listOf(3.coerceAtMost(h - 1), (h - 4).coerceAtLeast(0))) {
                val c = pixels[py * w + px]
                if (Color.red(c) > 150 && Color.green(c) < 90 && Color.blue(c) < 90) {
                    redBorderPx++
                }
            }
        }
        if (redBorderPx < 4) return null

        val ix0 = (w * 0.16f).toInt()
        val ix1 = w - (w * 0.16f).toInt()
        val iy0 = (h * 0.22f).toInt()
        val iy1 = h - (h * 0.22f).toInt()
        if (ix1 - ix0 < 10 || iy1 - iy0 < 10) return null

        val colCounts = IntArray(ix1 - ix0)
        for (px in ix0 until ix1) {
            var cnt = 0
            for (py in iy0 until iy1) {
                val c = pixels[py * w + px]
                if (Color.red(c) < 115 && Color.green(c) < 115 && Color.blue(c) < 115) cnt++
            }
            colCounts[px - ix0] = cnt
        }

        val spans = mutableListOf<Pair<Int, Int>>()
        var start = -1
        for (i in colCounts.indices) {
            if (colCounts[i] >= 2) {
                if (start == -1) start = i
            } else if (start != -1) {
                if (i - start >= 3) spans.add(Pair(ix0 + start, ix0 + i))
                start = -1
            }
        }
        if (start != -1 && colCounts.size - start >= 3) {
            spans.add(Pair(ix0 + start, ix1))
        }
        if (spans.size !in 2..3) return null

        val digits = StringBuilder()
        for ((sx0, sx1) in spans) {
            val matched = matchSingleDigit(pixels, w, sx0, sx1, iy0, iy1) ?: return null
            digits.append(matched)
        }
        val value = digits.toString().toIntOrNull() ?: return null
        return if (value in VALID_JP_SPEED_LIMITS) value else null
    }

    private fun matchSingleDigit(
        pixels: IntArray,
        stride: Int,
        sx0: Int,
        sx1: Int,
        iy0: Int,
        iy1: Int,
    ): Int? {
        var top = iy1
        var bottom = iy0
        for (py in iy0 until iy1) {
            val rowOff = py * stride
            for (px in sx0 until sx1) {
                val c = pixels[rowOff + px]
                if (Color.red(c) < 115 && Color.green(c) < 115 && Color.blue(c) < 115) {
                    if (py < top) top = py
                    if (py > bottom) bottom = py
                }
            }
        }
        val dw = sx1 - sx0
        val dh = bottom - top + 1
        if (dw < 3 || dh < 6) return null
        if (dw.toFloat() / dh < 0.36f) return 1

        val grid = IntArray(35)
        for (gy in 0 until 7) {
            val py = (top + ((gy + 0.5f) * dh / 7f).toInt()).coerceIn(top, bottom)
            val rowOff = py * stride
            for (gx in 0 until 5) {
                val px = (sx0 + ((gx + 0.5f) * dw / 5f).toInt()).coerceIn(sx0, sx1 - 1)
                val c = pixels[rowOff + px]
                grid[gy * 5 + gx] =
                    if (Color.red(c) < 120 && Color.green(c) < 120 && Color.blue(c) < 120) 1 else 0
            }
        }

        var bestDigit = -1
        var bestScore = 0.0
        for ((digit, tpl) in DIGIT_TEMPLATES) {
            var matches = 0
            for (i in 0 until 35) {
                if (grid[i] == tpl[i]) matches++
            }
            val score = matches / 35.0
            if (score > bestScore) {
                bestScore = score
                bestDigit = digit
            }
        }
        return if (bestScore >= 0.71) bestDigit else null
    }

    private fun classifyTrafficBar(bmp: Bitmap, rect: Rect): String {
        val (pixels, r) = readRegionPixels(bmp, rect) ?: return "unknown"
        val w = r.width()
        val h = r.height()
        val cx = w / 2
        val stepY = (h / 8).coerceAtLeast(1)
        var redCount = 0
        var orangeCount = 0
        var cyanCount = 0
        var y = stepY / 2
        while (y < h) {
            val px = pixels[y * w + cx]
            val red = Color.red(px)
            val green = Color.green(px)
            val blue = Color.blue(px)
            when {
                red > 170 && green < 95 && blue < 95 -> redCount++
                red > 180 && green in 95..200 && blue < 95 -> orangeCount++
                blue > 145 && green > 135 && red < 115 -> cyanCount++
            }
            y += stepY
        }
        return when {
            redCount >= 2 -> "congested"
            orangeCount >= 2 -> "slow"
            cyanCount >= 2 -> "smooth"
            else -> "unknown"
        }
    }

    private fun parseLaneGuide(bmp: Bitmap, rect: Rect): Pair<Int, List<Int>>? {
        val (pixels, r) = readRegionPixels(bmp, rect) ?: return null
        val w = r.width()
        val h = r.height()
        if (w < 10 || h < 10) return null

        val estSlotW = (h * 0.75f).coerceAtLeast(10f)
        val laneCount = (w / estSlotW).roundToInt().coerceIn(1, 8)
        val slotW = w.toFloat() / laneCount
        val recommended = mutableListOf<Int>()

        for (i in 0 until laneCount) {
            val sx0 = ((i * slotW).toInt() + 1).coerceIn(0, w - 1)
            val sx1 = (((i + 1) * slotW).toInt() - 1).coerceIn(sx0 + 1, w)
            var blueBg = 0
            var nonWhite = 0
            for (py in 2 until (h - 2).coerceAtLeast(3)) {
                val rowOff = py * w
                for (px in sx0 until sx1) {
                    val c = pixels[rowOff + px]
                    val red = Color.red(c)
                    val green = Color.green(c)
                    val blue = Color.blue(c)
                    if (red > 205 && green > 205 && blue > 205) continue
                    nonWhite++
                    if (blue > red + 35 && blue > 120) blueBg++
                }
            }
            if (nonWhite > 0 && blueBg.toFloat() / nonWhite >= 0.25f) {
                recommended.add(i + 1)
            }
        }
        return Pair(laneCount, recommended)
    }

    private fun buildLaneSummary(laneCount: Int, recommended: List<Int>): String {
        if (recommended.isEmpty()) return "共${laneCount}条车道"
        if (recommended.size == laneCount) return "共${laneCount}条车道，全部可通行"
        if (recommended.size == 1) {
            val lane = recommended.first()
            return when {
                lane == 1 -> "共${laneCount}条车道，请走最左侧第1车道"
                lane == laneCount -> "共${laneCount}条车道，请走最右侧第${lane}车道"
                else -> "共${laneCount}条车道，请走中间第${lane}车道"
            }
        }
        val joined = recommended.joinToString("、")
        val sideHint = when {
            recommended.first() == 1 -> "左侧"
            recommended.last() == laneCount -> "右侧"
            else -> "中间"
        }
        return "共${laneCount}条车道，请走${sideHint}第${joined}车道"
    }

    private fun firstTextById(root: AccessibilityNodeInfo, fullId: String): String {
        val nodes = root.findAccessibilityNodeInfosByViewId(fullId)
        var text = ""
        for (n in nodes) {
            if (text.isEmpty()) {
                val t = n.text?.toString()?.trim() ?: ""
                if (t.isNotEmpty()) text = t
            }
            n.recycle()
        }
        return text
    }

    private fun firstBoundsById(root: AccessibilityNodeInfo, fullId: String): Rect? {
        val nodes = root.findAccessibilityNodeInfosByViewId(fullId)
        var result: Rect? = null
        for (n in nodes) {
            if (result == null) {
                val r = Rect()
                n.getBoundsInScreen(r)
                if (r.width() > 0 && r.height() > 0) result = r
            }
            n.recycle()
        }
        return result
    }
}
