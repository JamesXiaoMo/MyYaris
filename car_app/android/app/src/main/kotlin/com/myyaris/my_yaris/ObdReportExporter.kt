package com.myyaris.my_yaris

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** All app-private file operations and export barriers share one ordered worker. */
object ObdReportExporter {
    private val worker = Executors.newSingleThreadExecutor()
    fun register(activity: Activity, engine: FlutterEngine) {
        val store = ObdTransportStore(File(activity.noBackupFilesDir, "obd_transport_sessions"))
        val bundles = ObdDiagnosticBundleWriter(File(activity.noBackupFilesDir, "obd_bundles"), { JSONObject(it).toString() })
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.myyaris.my_yaris/obd_reports")
            .setMethodCallHandler { call, result ->
                if (call.method !in listOf("appendTransport", "closeTransport", "export")) {
                    result.notImplemented(); return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        when (call.method) {
                            "appendTransport" -> {
                                store.append(requireNotNull(call.argument<String>("session")),
                                    requireNotNull(call.argument<Number>("sequence")).toLong(),
                                    requireNotNull(call.argument<String>("event")))
                                activity.runOnUiThread { result.success(null) }
                            }
                            "closeTransport" -> {
                                store.close(requireNotNull(call.argument<String>("session")))
                                activity.runOnUiThread { result.success(null) }
                            }
                            "export" -> {
                                val session = call.argument<String>("session")
                                val read = if (session != null) runCatching { store.snapshot(session) } else null
                                val actual = read?.getOrNull()
                                val snapshotError = read?.exceptionOrNull()?.let {
                                    if (it is IllegalStateException) "session_missing_or_evicted" else it.javaClass.simpleName
                                }
                                val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
                                val app = mapOf("package" to activity.packageName, "version_name" to info.versionName,
                                    "version_code" to if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong())
                                val bundle = bundles.write(requireNotNull(call.argument<String>("json")),
                                    requireNotNull(call.argument<String>("markdown")),
                                    call.argument<String>("expectedJournal") ?: "", actual, session,
                                    (call.argument<Map<String, Any?>>("storage") ?: emptyMap()) + ("native_snapshot_error" to snapshotError), app)
                                // Copy/prune on the ordered worker; only the Android chooser uses the UI thread.
                                val shareFile = if (call.argument<Boolean>("share") == true) {
                                    val cache = File(activity.cacheDir, "obd_reports").apply { mkdirs() }
                                    cache.listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - 86400000L }?.forEach { check(it.delete()) }
                                    val old = cache.listFiles()?.filter { it.name.endsWith(".zip") }?.sortedBy { it.lastModified() }?.toMutableList() ?: mutableListOf()
                                    var bytes = old.sumOf { it.length() }
                                    while (old.size >= 8 || bytes + File(bundle.path).length() > 32 * 1024 * 1024) {
                                        val file = old.removeAt(0); val n = file.length(); check(file.delete()); bytes -= n
                                    }
                                    val copy = File(cache, File(bundle.path).name)
                                    File(bundle.path).copyTo(copy, overwrite = false)
                                    copy
                                } else null
                                activity.runOnUiThread {
                                    try {
                                        if (shareFile != null) {
                                            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.obd_reports", shareFile)
                                            val intent = Intent(Intent.ACTION_SEND).apply {
                                                type = "application/zip"; putExtra(Intent.EXTRA_STREAM, uri)
                                                clipData = ClipData.newRawUri("OBD diagnostic bundle", uri)
                                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                            }
                                            activity.startActivity(Intent.createChooser(intent, "分享诊断包（含原始车辆数据）"))
                                        }
                                        result.success(mapOf("path" to bundle.path, "complete" to bundle.complete,
                                            "integrity" to bundle.manifest["integrity"]))
                                    } catch (e: Exception) { result.error("EXPORT_FAILED", "诊断包分享失败", null) }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        activity.runOnUiThread { result.error(if (call.method == "export") "EXPORT_FAILED" else "JOURNAL_FAILED", e.javaClass.simpleName, null) }
                    }
                }
            }
    }
}
