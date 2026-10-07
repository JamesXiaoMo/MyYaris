package com.myyaris.my_yaris

import android.content.ComponentName
import android.content.Context
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.util.Log

class MediaControlNotificationListenerService : NotificationListenerService() {

    companion object {
        private const val TAG = "MediaControlService"
        const val CLOUDMUSIC_PACKAGE = "com.netease.cloudmusic"

        var instance: MediaControlNotificationListenerService? = null
            private set

        fun isPermissionGranted(context: Context): Boolean {
            val enabledListeners = Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ) ?: ""
            val myComponent = ComponentName(context, MediaControlNotificationListenerService::class.java).flattenToString()
            val shortComponent = ComponentName(context, MediaControlNotificationListenerService::class.java).flattenToShortString()
            return enabledListeners.split(":").any {
                it.equals(myComponent, ignoreCase = true) ||
                it.equals(shortComponent, ignoreCase = true) ||
                (it.contains(context.packageName) && it.contains("MediaControlNotificationListenerService"))
            }
        }

        fun getActiveControllers(context: Context): List<MediaController> {
            val mgr = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
                ?: return emptyList()
            return try {
                val component = ComponentName(context, MediaControlNotificationListenerService::class.java)
                mgr.getActiveSessions(component) ?: emptyList()
            } catch (e: SecurityException) {
                Log.w(TAG, "Notification listener permission not granted: ${e.message}")
                emptyList()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to get active sessions: ${e.message}")
                emptyList()
            }
        }

        fun getCloudMusicController(context: Context): MediaController? {
            val controllers = getActiveControllers(context)
            return controllers.firstOrNull { it.packageName == CLOUDMUSIC_PACKAGE }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i(TAG, "MediaControlNotificationListenerService connected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (instance == this) {
            instance = null
        }
        Log.i(TAG, "MediaControlNotificationListenerService disconnected")
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }
}
