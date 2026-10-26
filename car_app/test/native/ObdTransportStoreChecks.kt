package com.myyaris.my_yaris

import java.io.File
import java.nio.file.Files
import java.util.zip.ZipFile

fun main() {
    val root = Files.createTempDirectory("obd-store-checks").toFile()
    var assertions = 0
    fun verify(value: Boolean) { check(value); assertions++ }
    fun fails(work: () -> Unit) { var failed = false; try { work() } catch (_: Exception) { failed = true }; verify(failed) }
    try {
        val storeRoot = File(root, "logs")
        val store = ObdTransportStore(storeRoot, segmentBytes = 64, sessionBytes = 256, maxSessions = 2, totalBytes = 512)
        val lines = (1..4).map { "{\"event_seq\":$it,\"data\":\"001122334455\"}" }
        lines.forEachIndexed { i, line -> store.append("100", i.toLong() + 1, line) }
        val original = lines.joinToString("\n", postfix = "\n").toByteArray()
        verify(storeRoot.resolve("100").listFiles()!!.count { it.extension == "jsonl" } > 1)
        verify(store.snapshot("100").contentEquals(original))
        fails { store.append("100", 4, "duplicate") }
        store.close("100")
        fails { store.append("100", 5, "after close") }
        store.append("200", 1, "second"); store.close("200")
        store.append("300", 1, "third"); store.close("300")
        fails { store.snapshot("100") }
        verify(store.snapshot("200").toString(Charsets.UTF_8) == "second\n")
        verify(storeRoot.listFiles()!!.size == 2)
        fails { store.append("../escape", 1, "bad") }
        fails { store.append("400", 1, "bad\nline") }

        val active = ObdTransportStore(File(root, "active"), 64, 128, 1, 128)
        active.append("1", 1, "kept")
        fails { active.append("2", 1, "cannot evict active") }
        verify(active.snapshot("1").toString(Charsets.UTF_8) == "kept\n")
        fails { active.append("1", 2, "x".repeat(65)) }
        verify(active.snapshot("1").toString(Charsets.UTF_8) == "kept\n")
        val fileRoot = File(root, "file-instead-of-directory").apply { writeText("untouched") }
        fails { ObdTransportStore(fileRoot).append("1", 1, "write must fail") }
        verify(fileRoot.readText() == "untouched")

        val bundleRoot = File(root, "bundles")
        val writer = ObdDiagnosticBundleWriter(bundleRoot, { map -> "{\"integrity\":\"${map["integrity"]}\"}" }, maxBundles = 2)
        bundleRoot.mkdirs()
        File(bundleRoot, "abandoned.zip.tmp").writeText("unfinished")
        val storage = mapOf<String, Any?>("flush_complete" to true, "truncated" to false, "capture_end_event" to 3)
        val expected = original.toString(Charsets.UTF_8)
        val complete = writer.write("{\"items\":[]}", "report", expected, original, "100", storage, mapOf("version_name" to "test"))
        verify(!File(bundleRoot, "abandoned.zip.tmp").exists())
        verify(complete.complete)
        verify(complete.manifest["native_matches_app_events"] == true)
        ZipFile(complete.path).use { zip ->
            verify(zip.size() == 4)
            verify(zip.getInputStream(zip.getEntry("transport.jsonl")).readBytes().contentEquals(original))
            verify(zip.getInputStream(zip.getEntry("report.json")).reader().readText().contains("export_manifest"))
            verify(zip.getInputStream(zip.getEntry("report.md")).reader().readText().contains("完整性清单"))
        }
        val partial = writer.write("{}", "report", expected, "partial\n".toByteArray(), "100", storage, emptyMap())
        verify(!partial.complete)
        verify(partial.manifest["integrity"] == "incomplete")
        ZipFile(partial.path).use { zip ->
            verify(zip.getInputStream(zip.getEntry("transport.jsonl")).reader().readText() == "partial\n")
            verify(zip.getInputStream(zip.getEntry("app-observed.jsonl")).reader().readText() == expected)
        }
        val missing = writer.write("{}", "report", expected, null, "999", storage, emptyMap())
        verify(!missing.complete && missing.manifest["native_journal_available"] == false)
        verify(bundleRoot.listFiles()!!.count { it.extension == "zip" } == 2)
        val truncated = writer.write("{}", "report", expected, original, "100", storage + ("truncated" to true), emptyMap())
        verify(!truncated.complete && truncated.manifest["integrity"] == "truncated")
        val pending = writer.write("{}", "report", expected, original, "100", storage + ("flush_complete" to false), emptyMap())
        verify(!pending.complete)
        verify(bundleRoot.listFiles()!!.sumOf { it.length() } <= 32 * 1024 * 1024)
        println("Native store/bundle checks passed: $assertions assertions; real files, rotation, failure and ZIP byte equality")
    } finally { root.deleteRecursively() }
}
