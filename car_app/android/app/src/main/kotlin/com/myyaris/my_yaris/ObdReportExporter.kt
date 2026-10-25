package com.myyaris.my_yaris

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.io.FileOutputStream
import java.util.concurrent.Executors

/** Explicit local export. noBackupFilesDir is private and excluded from Android backup. */
object ObdReportExporter {
    private val journalWriter = Executors.newSingleThreadExecutor()
    fun register(activity: Activity, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.myyaris.my_yaris/obd_reports")
            .setMethodCallHandler { call, result ->
                if (call.method == "appendTransport") {
                    val session = call.argument<String>("session")
                    val event = call.argument<String>("event")
                    if (session == null || !session.matches(Regex("[0-9]+")) ||
                        event == null || event.contains('\n')) {
                        result.error("JOURNAL_INVALID", "无效日志记录", null)
                        return@setMethodCallHandler
                    }
                    // Keep disk/fsync work off the UI/BLE delivery thread, in order.
                    journalWriter.execute {
                        try {
                            val directory = File(activity.noBackupFilesDir, "obd_reports").apply { mkdirs() }
                            FileOutputStream(File(directory, "transport_$session.jsonl"), true).use {
                                it.write((event + "\n").toByteArray(Charsets.UTF_8))
                                it.fd.sync()
                            }
                            activity.runOnUiThread { result.success(null) }
                        } catch (e: Exception) {
                            activity.runOnUiThread { result.error("JOURNAL_FAILED", "私有日志保存失败", null) }
                        }
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "export") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val json = requireNotNull(call.argument<String>("json"))
                    val markdown = requireNotNull(call.argument<String>("markdown"))
                    val directory = File(activity.noBackupFilesDir, "obd_reports").apply { mkdirs() }
                    val id = "obd_${System.currentTimeMillis()}_${UUID.randomUUID()}"
                    val saved = listOf(File(directory, "$id.json"), File(directory, "$id.md"))
                    saved[0].writeText(json, Charsets.UTF_8)
                    saved[1].writeText(markdown, Charsets.UTF_8)
                    if (call.argument<Boolean>("share") == true) {
                        val cache = File(activity.cacheDir, "obd_reports").apply { mkdirs() }
                        // Expire previous temporary grants/files on the next explicit share.
                        cache.listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - 86400000L }
                            ?.forEach { it.delete() }
                        val uris = ArrayList(saved.map { file ->
                            val copy = File(cache, file.name)
                            file.copyTo(copy, overwrite = true)
                            FileProvider.getUriForFile(activity, "${activity.packageName}.obd_reports", copy)
                        })
                        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                            type = "text/plain"
                            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                            clipData = ClipData.newRawUri("OBD report", uris[0]).apply {
                                addItem(ClipData.Item(uris[1]))
                            }
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        activity.startActivity(Intent.createChooser(intent, "分享 OBD 报告（含敏感车辆数据）"))
                    }
                    result.success(directory.absolutePath + "/" + id)
                } catch (e: Exception) {
                    result.error("EXPORT_FAILED", e.message ?: "本地导出失败", null)
                }
            }
    }
}
