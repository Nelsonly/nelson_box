package com.nelsonbox.nelson_box_app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingText = extractText(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nelsonbox/share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeSharedText") {
                    result.success(pendingText)
                    pendingText = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    // App 已在运行时，再次从“分享”或文字选择菜单进入
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val text = extractText(intent) ?: return
        channel?.invokeMethod("sharedText", text) ?: run { pendingText = text }
    }

    private fun extractText(intent: Intent?): String? = when (intent?.action) {
        Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
        Intent.ACTION_PROCESS_TEXT -> intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        else -> null
    }
}
