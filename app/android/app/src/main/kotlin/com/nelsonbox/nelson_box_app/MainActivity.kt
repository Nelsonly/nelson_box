package com.nelsonbox.nelson_box_app

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Parcelable
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingText: String? = null

    // 分享进来的文件：复制到 cacheDir 后的路径
    private val pendingFiles = mutableListOf<String>()
    private var dartReady = false
    private val mainHandler = Handler(Looper.getMainLooper())

    // Android 9 及以下保存到“下载”需要存储权限：等待授权结果的请求
    private val pendingPermission = mutableListOf<MethodChannel.Result>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        handleShareIntent(intent, fromNewIntent = false)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nelsonbox/share").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeSharedText" -> {
                        result.success(pendingText)
                        pendingText = null
                    }
                    "takeSharedFiles" -> {
                        dartReady = true
                        result.success(ArrayList(pendingFiles))
                        pendingFiles.clear()
                    }
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "ensureStoragePermission" -> ensureStoragePermission(result)
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name")
                        if (path == null || name == null) result.error("bad_args", "缺少参数", null)
                        else saveToDownloads(File(path), safeName(name), result)
                    }
                    "openFile" -> {
                        val uri = call.argument<String>("uri")
                        if (uri.isNullOrEmpty()) result.error("bad_args", "缺少参数", null)
                        else openFile(Uri.parse(uri), call.argument<String>("name") ?: "", result)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    // App 已在运行时，再次从“分享”或文字选择菜单进入
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent, fromNewIntent = true)
    }

    private fun handleShareIntent(intent: Intent?, fromNewIntent: Boolean) {
        val uris = extractStreams(intent)
        if (uris.isNotEmpty()) {
            // 文件分享优先（这类分享附带的 EXTRA_TEXT 一般只是标题/说明）
            copySharedFiles(uris)
            return
        }
        val text = extractText(intent) ?: return
        if (fromNewIntent) {
            channel?.invokeMethod("sharedText", text) ?: run { pendingText = text }
        } else {
            pendingText = text
        }
    }

    private fun extractText(intent: Intent?): String? = when (intent?.action) {
        Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
        Intent.ACTION_PROCESS_TEXT -> intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        else -> null
    }

    @Suppress("DEPRECATION")
    private fun extractStreams(intent: Intent?): List<Uri> = when (intent?.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM) as? Uri
        )
        Intent.ACTION_SEND_MULTIPLE -> (
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableArrayListExtra<Parcelable>(Intent.EXTRA_STREAM)?.filterIsInstance<Uri>()
        ).orEmpty()
        else -> emptyList()
    }

    /** 在后台线程把分享的 content:// 文件复制到 cacheDir/shared/<时间>_<序号>/<原文件名>，再交给 Dart 上传 */
    private fun copySharedFiles(uris: List<Uri>) {
        val resolver = applicationContext.contentResolver
        Thread {
            val stamp = System.currentTimeMillis()
            val paths = uris.mapIndexedNotNull { i, uri ->
                try {
                    val dir = File(cacheDir, "shared/${stamp}_$i").apply { mkdirs() }
                    val out = File(dir, safeName(displayName(uri) ?: uri.lastPathSegment ?: "file"))
                    resolver.openInputStream(uri)?.use { input ->
                        out.outputStream().use { input.copyTo(it) }
                    } ?: return@mapIndexedNotNull null
                    out.absolutePath
                } catch (e: Exception) {
                    null
                }
            }
            if (paths.isEmpty()) return@Thread
            mainHandler.post {
                val ch = channel
                if (dartReady && ch != null) ch.invokeMethod("sharedFiles", ArrayList(paths))
                else pendingFiles.addAll(paths)
            }
        }.start()
    }

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    private fun safeName(name: String): String =
        name.replace(Regex("[/\\\\:*?\"<>|\\x00-\\x1f]"), "_").trim().trimStart('.').ifEmpty { "file" }.take(200)

    // ---------- 收到的文件：存到 下载/NelsonBox/ ----------
    private fun ensureStoragePermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingPermission.add(result)
        if (pendingPermission.size == 1) {
            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQ_STORAGE)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_STORAGE) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission.forEach { it.success(granted) }
        pendingPermission.clear()
    }

    private fun mimeOf(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"

    /** 在后台线程把缓存里的临时文件复制到公共“下载/NelsonBox”，返回 {uri, name} */
    private fun saveToDownloads(src: File, name: String, result: MethodChannel.Result) {
        Thread {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val resolver = applicationContext.contentResolver
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, name)
                        put(MediaStore.Downloads.MIME_TYPE, mimeOf(name))
                        put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/NelsonBox")
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("无法创建文件")
                    try {
                        resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                            ?: throw IllegalStateException("无法写入文件")
                        resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
                    } catch (e: Exception) {
                        resolver.delete(uri, null, null)
                        throw e
                    }
                    // 同名时系统会自动改名，读回实际文件名
                    val finalName = resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)
                        ?.use { c -> if (c.moveToFirst()) c.getString(0) else null } ?: name
                    mainHandler.post { result.success(mapOf("uri" to uri.toString(), "name" to finalName)) }
                } else {
                    @Suppress("DEPRECATION")
                    val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "NelsonBox")
                    if (!dir.isDirectory && !dir.mkdirs()) throw IllegalStateException("无法创建 下载/NelsonBox 目录")
                    val dest = uniqueFile(dir, name)
                    src.inputStream().use { input -> dest.outputStream().use { input.copyTo(it) } }
                    // 让系统媒体库收录，并拿到可以打开的 content:// URI
                    MediaScannerConnection.scanFile(applicationContext, arrayOf(dest.absolutePath), arrayOf(mimeOf(name))) { _, uri ->
                        mainHandler.post {
                            result.success(mapOf("uri" to (uri ?: Uri.fromFile(dest)).toString(), "name" to dest.name))
                        }
                    }
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("save_failed", e.message ?: "保存失败", null) }
            }
        }.start()
    }

    /** 同名时加 " (1)"、" (2)"… */
    private fun uniqueFile(dir: File, name: String): File {
        var f = File(dir, name)
        if (!f.exists()) return f
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (f.exists()) f = File(dir, "$base ($i)$ext").also { i++ }
        return f
    }

    private fun openFile(uri: Uri, name: String, result: MethodChannel.Result) {
        val type = contentResolver.getType(uri) ?: mimeOf(name)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, type)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(Intent.createChooser(intent, "打开文件").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error("no_app", "没有可以打开此文件的应用", null)
        } catch (e: Exception) {
            result.error("open_failed", "无法打开：${e.message}", null)
        }
    }

    companion object {
        private const val REQ_STORAGE = 1001
    }
}
