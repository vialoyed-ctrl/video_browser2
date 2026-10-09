package com.example.video_browser

import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.video_browser/media_utils"
    private val UPDATE_CHANNEL = "com.example.video_browser/app_updates"
    private val TAG = "MediaUtils"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "canInstallUnknownApps" -> {
                        result.success(
                            Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls()
                        )
                    }
                    "requestInstallPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val intent = Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES
                                ).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (error: Exception) {
                                result.error("INSTALL_PERMISSION_ERROR", error.message, null)
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_APK_PATH", "APK path is required", null)
                        } else {
                            val apk = File(path)
                            if (!apk.isFile || apk.length() == 0L) {
                                result.error("APK_NOT_FOUND", "APK file is missing", null)
                            } else if (
                                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                                !packageManager.canRequestPackageInstalls()
                            ) {
                                result.error(
                                    "INSTALL_PERMISSION_REQUIRED",
                                    "Allow this app to install unknown apps first",
                                    null
                                )
                            } else {
                                try {
                                    val apkUri = FileProvider.getUriForFile(
                                        this,
                                        "$packageName.updateprovider",
                                        apk
                                    )
                                    val installIntent = Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(
                                            apkUri,
                                            "application/vnd.android.package-archive"
                                        )
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    startActivity(installIntent)
                                    result.success(true)
                                } catch (error: Exception) {
                                    result.error("INSTALL_APK_ERROR", error.message, null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isManageStorageGranted" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(Environment.isExternalStorageManager())
                    } else {
                        result.success(true)
                    }
                }
                "requestManageStoragePermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                data = Uri.parse("package:$packageName")
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("PERMISSION_ERROR", e2.message, null)
                            }
                        }
                    } else {
                        result.success(true)
                    }
                }
                "remuxTsToMp4" -> {
                    val inputPath = call.argument<String>("inputPath")
                    val outputPath = call.argument<String>("outputPath")
                    if (inputPath == null || outputPath == null) {
                        result.error("INVALID_ARGS", "inputPath and outputPath required", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val success = remuxTsToMp4(inputPath, outputPath)
                        runOnUiThread {
                            result.success(success)
                        }
                    }.start()
                }
                "scanFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            arrayOf(path),
                            arrayOf("video/mp4"),
                            null
                        )
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun remuxTsToMp4(inputPath: String, outputPath: String): Boolean {
        var extractor: MediaExtractor? = null
        var muxer: MediaMuxer? = null
        val outFile = File(outputPath)
        try {
            val inFile = File(inputPath)
            if (!inFile.exists() || inFile.length() == 0L) {
                Log.e(TAG, "Input file does not exist or empty: $inputPath")
                return false
            }

            // Ensure parent directory exists
            outFile.parentFile?.mkdirs()
            if (outFile.exists()) {
                outFile.delete()
            }

            extractor = MediaExtractor()
            extractor.setDataSource(inputPath)

            val trackCount = extractor.trackCount
            if (trackCount == 0) {
                Log.e(TAG, "No tracks found in input file: $inputPath")
                return false
            }

            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val indexMap = HashMap<Int, Int>()
            val isAudioTrack = HashMap<Int, Boolean>()

            for (i in 0 until trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                    extractor.selectTrack(i)
                    val dstIndex = muxer.addTrack(format)
                    indexMap[i] = dstIndex
                    isAudioTrack[i] = mime.startsWith("audio/")
                }
            }

            if (indexMap.isEmpty()) {
                Log.e(TAG, "No audio or video track supported in: $inputPath")
                return false
            }

            muxer.start()

            val maxBufferSize = 2 * 1024 * 1024 // 2MB
            val buffer = ByteBuffer.allocate(maxBufferSize)
            val bufferInfo = MediaCodec.BufferInfo()

            var lastVideoPts = -1L
            var lastAudioPts = -1L

            while (true) {
                val trackIndex = extractor.sampleTrackIndex
                if (trackIndex < 0) break

                val dstTrack = indexMap[trackIndex]
                if (dstTrack == null) {
                    extractor.advance()
                    continue
                }

                bufferInfo.offset = 0
                val sampleSize = extractor.readSampleData(buffer, 0)
                if (sampleSize < 0) break

                bufferInfo.size = sampleSize
                var pts = extractor.sampleTime
                val isAudio = isAudioTrack[trackIndex] == true

                if (isAudio) {
                    if (pts <= lastAudioPts) {
                        pts = lastAudioPts + 1000L
                    }
                    lastAudioPts = pts
                } else {
                    if (pts <= lastVideoPts) {
                        pts = lastVideoPts + 1000L
                    }
                    lastVideoPts = pts
                }

                bufferInfo.presentationTimeUs = pts
                bufferInfo.flags = extractor.sampleFlags

                muxer.writeSampleData(dstTrack, buffer, bufferInfo)
                extractor.advance()
            }

            muxer.stop()
            muxer.release()
            muxer = null

            extractor.release()
            extractor = null

            val success = outFile.exists() && outFile.length() > 0L
            if (success) {
                Log.i(TAG, "Successfully remuxed $inputPath to $outputPath (${outFile.length()} bytes)")
                MediaScannerConnection.scanFile(
                    applicationContext,
                    arrayOf(outputPath),
                    arrayOf("video/mp4"),
                    null
                )
            }
            return success
        } catch (e: Exception) {
            Log.e(TAG, "remuxTsToMp4 failed: ${e.message}", e)
            try {
                if (outFile.exists() && outFile.length() == 0L) {
                    outFile.delete()
                }
            } catch (ignored: Exception) {}
            return false
        } finally {
            try { extractor?.release() } catch (ignored: Exception) {}
            try { muxer?.release() } catch (ignored: Exception) {}
        }
    }
}
