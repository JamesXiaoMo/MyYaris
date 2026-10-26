package com.myyaris.my_yaris

import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** JVM-only file/rotation policy, also exercised against real temporary files in host tests. */
class ObdTransportStore(
    private val root: File,
    private val segmentBytes: Long = 256 * 1024,
    private val sessionBytes: Long = 2 * 1024 * 1024,
    private val maxSessions: Int = 8,
    private val totalBytes: Long = 16 * 1024 * 1024
) {
    private data class State(var sequence: Long = 0, var bytes: Long = 0, var part: Int = 0, var closed: Boolean = false)
    private val states = mutableMapOf<String, State>()
    private fun directory(session: String): File {
        require(session.matches(Regex("[0-9]+")))
        return File(root, session)
    }
    private fun parts(dir: File) = dir.listFiles()?.filter { it.name.matches(Regex("part_[0-9]+\\.jsonl")) }?.sortedBy { it.name } ?: emptyList()
    private fun usage(dir: File) = parts(dir).sumOf { it.length() }

    @Synchronized
    fun append(session: String, sequence: Long, event: String) {
        require(!event.contains('\n') && !event.contains('\r'))
        val bytes = (event + "\n").toByteArray(Charsets.UTF_8)
        require(bytes.size <= segmentBytes) { "event_capacity" }
        val dir = directory(session)
        val state = states.getOrPut(session) {
            require(!dir.exists()) { "session_already_exists" }
            require(root.exists() || root.mkdirs())
            pruneForNewSession()
            require(dir.mkdir())
            State()
        }
        check(!state.closed) { "session_closed" }
        require(sequence > state.sequence) { "sequence_order" }
        check(state.bytes + bytes.size <= sessionBytes) { "session_capacity" }
        var file = File(dir, "part_${state.part.toString().padStart(4, '0')}.jsonl")
        if (file.length() > 0 && file.length() + bytes.size > segmentBytes) {
            state.part++
            file = File(dir, "part_${state.part.toString().padStart(4, '0')}.jsonl")
        }
        FileOutputStream(file, true).use { it.write(bytes); it.fd.sync() }
        state.bytes += bytes.size
        state.sequence = sequence
    }

    @Synchronized
    fun close(session: String) { states[session]?.closed = true }

    @Synchronized
    fun snapshot(session: String): ByteArray {
        val dir = directory(session)
        check(dir.isDirectory) { "session_missing_or_evicted" }
        return ByteArrayOutputStream().use { output ->
            parts(dir).forEach { file -> file.inputStream().use { it.copyTo(output) } }
            output.toByteArray()
        }
    }

    private fun pruneForNewSession() {
        val dirs = root.listFiles()?.filter { it.isDirectory && it.name.matches(Regex("[0-9]+")) }
            ?.sortedBy { it.name }?.toMutableList() ?: mutableListOf()
        var bytes = dirs.sumOf { usage(it) }
        while (dirs.size >= maxSessions || bytes + sessionBytes > totalBytes) {
            val old = dirs.firstOrNull { states[it.name]?.closed != false } ?: error("active_session_capacity")
            val oldBytes = usage(old)
            check(old.deleteRecursively()) { "retention_delete_failed" }
            states.remove(old.name); dirs.remove(old); bytes -= oldBytes
        }
    }
}

data class ObdBundleResult(val path: String, val complete: Boolean, val manifest: Map<String, Any?>)

/** Produces an inspectable bundle; partial native data is never called a complete journal. */
class ObdDiagnosticBundleWriter(
    private val root: File,
    private val encode: (Map<String, Any?>) -> String,
    private val maxBundles: Int = 8,
    private val maxBytes: Long = 32 * 1024 * 1024
) {
    fun write(json: String, markdown: String, expected: String, actual: ByteArray?,
              session: String?, storage: Map<String, Any?>, app: Map<String, Any?>): ObdBundleResult {
        require(root.exists() || root.mkdirs())
        // A crash can leave only an unfinished bundle in this dedicated directory.
        // Remove stale temporary files before reserving capacity for another export.
        root.listFiles()?.filter { it.name.endsWith(".zip.tmp") }?.forEach { check(it.delete()) }
        val observed = expected.toByteArray(Charsets.UTF_8)
        val match = actual != null && observed.contentEquals(actual)
        val complete = match && storage["flush_complete"] == true && storage["truncated"] != true
        val integrity = if (storage["truncated"] == true) "truncated" else if (complete) "complete_within_window" else "incomplete"
        val manifest = linkedMapOf<String, Any?>(
            "bundle_schema" to 1, "session_id" to session, "integrity" to integrity,
            "native_journal_available" to (actual != null), "native_matches_app_events" to match,
            "native_bytes" to actual?.size, "app_event_bytes" to observed.size,
            "native_sha256" to actual?.let { sha256(it) }, "app_event_sha256" to sha256(observed),
            "storage" to storage, "installed_app" to app,
            "observation_layer" to "app_callbacks_not_HCI_or_CAN_capture",
            "files" to (listOf("report.json", "report.md", "transport.jsonl", "manifest.json") +
                if (!match) listOf("app-observed.jsonl") else emptyList())
        )
        // Include the same manifest in both report formats, without re-labelling app events native.
        val manifestJson = encode(manifest)
        val reportJson = json.trim().removeSuffix("}") + ",\"export_manifest\":" + manifestJson + "}"
        val reportMd = markdown + "\n## 诊断包完整性清单\n\n    " + manifestJson + "\n"
        val files = linkedMapOf("report.json" to reportJson.toByteArray(Charsets.UTF_8),
            "report.md" to reportMd.toByteArray(Charsets.UTF_8),
            "transport.jsonl" to (actual ?: byteArrayOf()), "manifest.json" to manifestJson.toByteArray(Charsets.UTF_8))
        if (!match) files["app-observed.jsonl"] = observed
        val reserve = files.values.sumOf { it.size.toLong() } + 65536
        check(reserve <= maxBytes) { "bundle_capacity" }
        val old = root.listFiles()?.filter { it.name.endsWith(".zip") }?.sortedBy { it.lastModified() }?.toMutableList() ?: mutableListOf()
        var usage = old.sumOf { it.length() }
        while (old.size >= maxBundles || usage + reserve > maxBytes) {
            val file = old.removeAt(0); val n = file.length()
            check(file.delete()); usage -= n
        }
        val file = File(root, "obd_${System.currentTimeMillis()}_${UUID.randomUUID()}.zip")
        val temp = File(root, file.name + ".tmp")
        try {
            FileOutputStream(temp).use { output ->
                val zip = ZipOutputStream(output)
                files.forEach { (name, bytes) -> zip.putNextEntry(ZipEntry(name)); zip.write(bytes); zip.closeEntry() }
                zip.finish(); zip.flush(); output.fd.sync(); zip.close()
            }
            check(temp.renameTo(file))
        } catch (e: Exception) { temp.delete(); throw e }
        return ObdBundleResult(file.absolutePath, complete, manifest)
    }

    companion object {
        fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
