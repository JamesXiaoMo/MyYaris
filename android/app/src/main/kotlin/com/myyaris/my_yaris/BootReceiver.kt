package com.myyaris.my_yaris

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "MyYarisBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        Log.i(TAG, "Received broadcast action on boot: $action")

        // 1. Immediately start foreground service to keep process alive
        try {
            KeepAliveService.start(context)
            Log.i(TAG, "Started KeepAliveService from BootReceiver")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start KeepAliveService: ${e.message}")
        }

        // 2. Launch MainActivity to start Flutter engine and resume polling
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launchIntent.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        }
        try {
            context.startActivity(launchIntent)
            Log.i(TAG, "Launched MainActivity successfully on boot")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch MainActivity on boot: ${e.message}")
        }
    }
}
