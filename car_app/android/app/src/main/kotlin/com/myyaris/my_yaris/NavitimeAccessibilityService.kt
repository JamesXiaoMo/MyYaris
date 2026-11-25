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
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Reads live navigation cues (upcoming intersections, lane guidance boxes, VICS traffic
 * color bars, ETA, remaining distance) directly from CAR NAVITIME when it is in the foreground.
 * Uses Android 11+ AccessibilityService.takeScreenshot() for silent color/lane sampling
 * without any MediaProjection confirmation dialogs.
 */
class NavitimeAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "NavitimeGuide"
        private const val NAVITIME_PKG = "com.navitime.local.carnavitime"
        private const val ID_PREFIX = "$NAVITIME_PKG:id/"

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var latestSnapshot: Map<String, Any>? = null
            private set

        @Volatile
        var onSnapshotUpdated: ((Map<String, Any>) -> Unit)? = null
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
    private var lastProcessMs: Long = 0L
    private var lastScreenshotMs: Long = 0L
    private val screenshotInFlight = AtomicBoolean(false)

    override fun onServiceConnected() {
        super.onServiceConnected()
        isRunning = true
        Log.i(TAG, "NavitimeAccessibilityService connected")
    }

    override fun onInterrupt() {
        // No-op
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val pkg = event.packageName?.toString() ?: return
        if (pkg != NAVITIME_PKG) return

        val now = SystemClock.elapsedRealtime()
        if (now - lastProcessMs < 1400L) return
        lastProcessMs = now

        val root = rootInActiveWindow ?: return
        try {
            parseWindow(root, now)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse CAR NAVITIME window: ${e.message}")
        } finally {
            root.recycle()
        }
    }

    private fun parseWindow(root: AccessibilityNodeInfo, nowMs: Long) {
        val nextDestName = firstTextById(root, "${ID_PREFIX}next_destination_name")
        val nextDestDist = firstTextById(root, "${ID_PREFIX}next_destination_distance")
        val twoAheadDist = firstTextById(root, "${ID_PREFIX}two_ahead_direction_distance")
        val arrivalTime = firstTextById(root, "${ID_PREFIX}arrival_time")
        val remainingDist = firstTextById(root, "${ID_PREFIX}remaining_dis_text")

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

        // CAR NAVITIME renders the nearest intersection at the BOTTOM of the list.
        items.sortByDescending { it.itemBottom }

        if (nextDestName.isEmpty() && items.isEmpty() && arrivalTime.isEmpty()) {
            return
        }

        val needsVisualSample = items.any { it.trafficBounds != null || it.laneBounds != null }
        if (needsVisualSample &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            nowMs - lastScreenshotMs >= 2000L &&
            screenshotInFlight.compareAndSet(false, true)
        ) {
            lastScreenshotMs = nowMs
            try {
                takeScreenshot(
                    Display.DEFAULT_DISPLAY,
                    mainExecutor,
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
                            } catch (e: Exception) {
                                Log.w(TAG, "Screenshot bitmap copy failed: ${e.message}")
                            } finally {
                                try {
                                    screenshot.hardwareBuffer.close()
                                } catch (_: Exception) {
                                }
                                screenshotInFlight.set(false)
                            }
                            try {
                                publishSnapshot(
                                    nextDestName = nextDestName,
                                    nextDestDist = nextDestDist,
                                    twoAheadDist = twoAheadDist,
                                    arrivalTime = arrivalTime,
                                    remainingDist = remainingDist,
                                    items = items,
                                    bitmap = swBitmap,
                                )
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
                                items = items,
                                bitmap = null,
                            )
                        }
                    }
                )
            } catch (e: Exception) {
                screenshotInFlight.set(false)
                publishSnapshot(
                    nextDestName = nextDestName,
                    nextDestDist = nextDestDist,
                    twoAheadDist = twoAheadDist,
                    arrivalTime = arrivalTime,
                    remainingDist = remainingDist,
                    items = items,
                    bitmap = null,
                )
            }
        } else {
            publishSnapshot(
                nextDestName = nextDestName,
                nextDestDist = nextDestDist,
                twoAheadDist = twoAheadDist,
                arrivalTime = arrivalTime,
                remainingDist = remainingDist,
                items = items,
                bitmap = null,
            )
        }
    }

    private fun publishSnapshot(
        nextDestName: String,
        nextDestDist: String,
        twoAheadDist: String,
        arrivalTime: String,
        remainingDist: String,
        items: List<RawGuideItem>,
        bitmap: Bitmap?,
    ) {
        val parsedItems = items.map { item ->
            val traffic = if (bitmap != null && item.trafficBounds != null) {
                classifyTrafficBar(bitmap, item.trafficBounds)
            } else {
                "unknown"
            }
            val laneResult = if (bitmap != null && item.laneBounds != null) {
                parseLaneGuide(bitmap, item.laneBounds)
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

        val snapshot = mapOf<String, Any>(
            "timestamp_ms" to System.currentTimeMillis(),
            "next_destination_name" to nextDestName,
            "next_destination_distance" to nextDestDist,
            "two_ahead_distance" to twoAheadDist,
            "arrival_time" to arrivalTime,
            "remaining_distance_km" to remainingDist,
            "upcoming_intersections" to parsedItems,
        )
        latestSnapshot = snapshot
        mainHandler.post {
            onSnapshotUpdated?.invoke(snapshot)
        }
    }

    private fun classifyTrafficBar(bmp: Bitmap, rect: Rect): String {
        val x0 = rect.left.coerceIn(0, bmp.width - 1)
        val x1 = rect.right.coerceIn(x0 + 1, bmp.width)
        val y0 = rect.top.coerceIn(0, bmp.height - 1)
        val y1 = rect.bottom.coerceIn(y0 + 1, bmp.height)
        if (x1 <= x0 || y1 <= y0) return "unknown"

        val cx = (x0 + x1) / 2
        val stepY = ((y1 - y0) / 8).coerceAtLeast(1)
        var redCount = 0
        var orangeCount = 0
        var cyanCount = 0
        var y = y0 + stepY / 2
        while (y < y1) {
            val px = bmp.getPixel(cx, y)
            val r = Color.red(px)
            val g = Color.green(px)
            val b = Color.blue(px)
            when {
                r > 170 && g < 95 && b < 95 -> redCount++
                r > 180 && g in 95..200 && b < 95 -> orangeCount++
                b > 145 && g > 135 && r < 115 -> cyanCount++
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
        val x0 = rect.left.coerceIn(0, bmp.width - 1)
        val x1 = rect.right.coerceIn(x0 + 1, bmp.width)
        val y0 = rect.top.coerceIn(0, bmp.height - 1)
        val y1 = rect.bottom.coerceIn(y0 + 1, bmp.height)
        val w = x1 - x0
        val h = y1 - y0
        if (w < 10 || h < 10) return null

        // CAR NAVITIME lane icons are ~18px wide by 24px tall (aspect ratio ~0.75 per lane).
        val estSlotW = (h * 0.75f).coerceAtLeast(10f)
        val laneCount = (w / estSlotW).roundToInt().coerceIn(1, 8)
        val slotW = w.toFloat() / laneCount
        val recommended = mutableListOf<Int>()

        for (i in 0 until laneCount) {
            val sx0 = (x0 + (i * slotW).toInt() + 1).coerceIn(x0, x1 - 1)
            val sx1 = (x0 + ((i + 1) * slotW).toInt() - 1).coerceIn(sx0 + 1, x1)
            var blueBg = 0
            var nonWhite = 0
            for (py in (y0 + 2) until (y1 - 2).coerceAtLeast(y0 + 3)) {
                for (px in sx0 until sx1) {
                    val c = bmp.getPixel(px, py)
                    val r = Color.red(c)
                    val g = Color.green(c)
                    val b = Color.blue(c)
                    // Skip bright white arrow foreground pixels
                    if (r > 205 && g > 205 && b > 205) continue
                    nonWhite++
                    // Highlighted recommended lane has vivid blue background
                    if (b > r + 35 && b > 120) {
                        blueBg++
                    }
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
                if (r.width() > 0 && r.height() > 0) {
                    result = r
                }
            }
            n.recycle()
        }
        return result
    }
}
