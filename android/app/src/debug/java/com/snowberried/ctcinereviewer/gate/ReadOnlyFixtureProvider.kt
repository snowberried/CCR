package com.snowberried.ctcinereviewer.gate

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.atomic.AtomicInteger
import org.json.JSONObject

class ReadOnlyFixtureProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") {
            writeOpenCount.incrementAndGet()
            throw FileNotFoundException("WRITE_MODE_FORBIDDEN")
        }
        readOpenCount.incrementAndGet()
        val name = uri.lastPathSegment?.takeIf { FIXTURE_NAME.matches(it) }
            ?: throw FileNotFoundException("INVALID_FIXTURE_NAME")
        val cacheDir = File(requireNotNull(context).cacheDir, "frame-accuracy-fixtures").apply { mkdirs() }
        val local = cacheFile(requireNotNull(context), cacheDir, name)
        if (!local.isFile) {
            requireNotNull(context).assets.open("${assetDirectory(name)}/$name").use { input ->
                local.outputStream().use(input::copyTo)
            }
        }
        return ParcelFileDescriptor.open(local, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = "video/mp4"
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    companion object {
        val readOpenCount = AtomicInteger()
        val writeOpenCount = AtomicInteger()
        private val FIXTURE_NAME = Regex("[a-z0-9-]+\\.mp4")

        private fun assetDirectory(name: String): String =
            if (name.startsWith("720p-") || name.startsWith("1080p-")) {
                "representative-resolution"
            } else {
                "frame-accuracy"
            }

        private fun cacheFile(context: android.content.Context, directory: File, name: String): File {
            if (!name.startsWith("720p-") && !name.startsWith("1080p-")) return File(directory, name)
            val manifestName = name.removeSuffix(".mp4")
            val sourceSha = context.assets.open("representative-resolution/$manifestName.json")
                .bufferedReader()
                .use { JSONObject(it.readText()).getString("sourceSha256") }
                .takeIf { it.matches(Regex("[a-f0-9]{64}")) }
                ?: throw FileNotFoundException("INVALID_FIXTURE_SHA")
            return File(directory, "$manifestName-$sourceSha.mp4")
        }
    }
}
