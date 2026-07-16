package com.snowberried.ctcinereviewer.benchmark

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException
import org.json.JSONObject

class BenchmarkFixtureProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("WRITE_MODE_FORBIDDEN")
        val name = validatedName(uri.lastPathSegment)
        return ParcelFileDescriptor.open(
            prepareFixture(requireNotNull(context), name),
            ParcelFileDescriptor.MODE_READ_ONLY,
        )
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
        private val FIXTURE_NAME = Regex("[a-z0-9-]+\\.mp4")

        fun prepare(context: Context, names: Iterable<String>) {
            names.forEach { prepareFixture(context, validatedName(it)) }
        }

        private fun prepareFixture(context: Context, name: String): File {
            val directory = File(context.cacheDir, "benchmark-fixtures").apply { mkdirs() }
            val destination = cacheFile(context, directory, name)
            if (!destination.isFile) {
                context.assets.open("${assetDirectory(name)}/$name").use { input ->
                    destination.outputStream().use(input::copyTo)
                }
            }
            return destination
        }

        private fun validatedName(name: String?): String =
            name?.takeIf(FIXTURE_NAME::matches) ?: throw FileNotFoundException("INVALID_FIXTURE_NAME")

        private fun assetDirectory(name: String): String =
            if (name.startsWith("720p-") || name.startsWith("1080p-")) {
                "representative-resolution"
            } else {
                "frame-accuracy"
            }

        private fun cacheFile(context: Context, directory: File, name: String): File {
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
