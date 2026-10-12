package com.myyaris.my_yaris

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

class NavTransitionActivity : Activity() {
    companion object {
        const val EXTRA_GEO_URI = "extra_geo_uri"
        const val EXTRA_TITLE = "extra_title"
        const val TRANSITION_DELAY_MS = 600L
    }

    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)

        val rawGeoUri = intent.getStringExtra(EXTRA_GEO_URI)?.trim()
        val rawTitle = intent.getStringExtra(EXTRA_TITLE)?.trim()?.take(100)

        if (rawGeoUri.isNullOrBlank() || !isValidGeoUri(rawGeoUri)) {
            finish()
            overridePendingTransition(0, 0)
            return
        }
        val geoUri = rawGeoUri
        val title = rawTitle

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(0xFF141218.toInt())
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val progressBar = ProgressBar(this).apply {
            indeterminateDrawable?.setTint(0xFF4A90E2.toInt())
        }

        val titleView = TextView(this).apply {
            text = "正在同步目的地至 CAR NAVITIME..."
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 18f
            setPadding(0, 32, 0, 8)
            gravity = Gravity.CENTER
        }

        layout.addView(progressBar)
        layout.addView(titleView)

        if (!title.isNullOrBlank()) {
            val destView = TextView(this).apply {
                text = title
                setTextColor(0xFF9E9E9E.toInt())
                textSize = 14f
                gravity = Gravity.CENTER
            }
            layout.addView(destView)
        }

        setContentView(layout)

        handler.postDelayed({
            try {
                val navIntent = Intent(Intent.ACTION_VIEW, Uri.parse(geoUri)).apply {
                    setPackage("com.navitime.local.carnavitime")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(navIntent)
            } catch (_: Exception) {
            } finally {
                finish()
                overridePendingTransition(0, 0)
            }
        }, TRANSITION_DELAY_MS)
    }

    override fun finish() {
        super.finish()
        overridePendingTransition(0, 0)
    }

    private fun isValidGeoUri(uriString: String): Boolean {
        // Strict format: geo:0,0?q=lat,lon or geo:lat,lon?q=lat,lon or geo:lat,lon
        val regex = Regex("""^geo:(?:([+-]?\d+(?:\.\d+)?),([+-]?\d+(?:\.\d+)?))?(?:\?q=([+-]?\d+(?:\.\d+)?),([+-]?\d+(?:\.\d+)?))?$""")
        val match = regex.matchEntire(uriString) ?: return false

        val qLat = match.groups[3]?.value?.toDoubleOrNull()
        val qLon = match.groups[4]?.value?.toDoubleOrNull()
        val baseLat = match.groups[1]?.value?.toDoubleOrNull()
        val baseLon = match.groups[2]?.value?.toDoubleOrNull()

        val lat = qLat ?: baseLat ?: return false
        val lon = qLon ?: baseLon ?: return false

        return lat in -90.0..90.0 && lon in -180.0..180.0
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
