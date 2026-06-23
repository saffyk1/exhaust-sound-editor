// android/app/src/main/kotlin/com/example/exhaust_studio/MainActivity.kt
// Place this file at the exact path shown above (replace com/example/exhaust_studio
// with your actual package path if different).

package com.example.exhaust_studio

import android.os.Environment
import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "exhaust_studio/media"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                // Returns the absolute path to /sdcard/Movies (public)
                "getPublicMoviesDir" -> {
                    val moviesDir = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_MOVIES
                    )
                    result.success(moviesDir.absolutePath)
                }

                // Sends ACTION_MEDIA_SCANNER_SCAN_FILE so Gallery picks up the new video
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            arrayOf(path),
                            arrayOf("video/mp4"),
                        ) { _, _ -> result.success(null) }
                    } else {
                        result.error("INVALID_PATH", "path argument is null", null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
