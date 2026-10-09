package com.mackmusial.golf_swing_analyzer

import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/** Hosts the "golf_swing_analyzer/frames" channel: exact-frame extraction from a video file. */
class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "golf_swing_analyzer/frames")
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("BAD_ARGS", "path is required", null)
                    return@setMethodCallHandler
                }
                executor.execute {
                    try {
                        val value: Any = when (call.method) {
                            "probe" -> probe(path)
                            "extractFrames" -> extractFrames(
                                path,
                                call.argument<List<Int>>("timesMs") ?: emptyList(),
                                call.argument<String>("outDir")!!,
                                call.argument<Int>("maxDimension") ?: 720,
                            )
                            else -> {
                                runOnUiThread { result.notImplemented() }
                                return@execute
                            }
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("FRAME_ERROR", e.message, null) }
                    }
                }
            }
    }

    private fun <T> withRetriever(path: String, block: (MediaMetadataRetriever) -> T): T {
        val mmr = MediaMetadataRetriever()
        try {
            mmr.setDataSource(path)
            return block(mmr)
        } finally {
            mmr.release()
        }
    }

    /** Display size of the video, with rotation metadata applied. */
    private fun displaySize(mmr: MediaMetadataRetriever): Pair<Int, Int> {
        val w = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 0
        val h = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 0
        return if (rotation(mmr) % 180 == 90) Pair(h, w) else Pair(w, h)
    }

    private fun rotation(mmr: MediaMetadataRetriever): Int =
        mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0

    private fun probe(path: String): Map<String, Any> = withRetriever(path) { mmr ->
        val (w, h) = displaySize(mmr)
        mapOf(
            "durationMs" to (mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L),
            "width" to w,
            "height" to h,
        )
    }

    private fun extractFrames(
        path: String,
        timesMs: List<Int>,
        outDir: String,
        maxDimension: Int,
    ): List<Map<String, Any>> = withRetriever(path) { mmr ->
        val (dispW, dispH) = displaySize(mmr)
        val rot = rotation(mmr)
        val frames = mutableListOf<Map<String, Any>>()

        for (t in timesMs) {
            // OPTION_CLOSEST decodes the exact frame, not just the nearest keyframe.
            var bitmap = mmr.getFrameAtTime(t * 1000L, MediaMetadataRetriever.OPTION_CLOSEST) ?: continue

            // Some devices return frames without the rotation applied. Fix that up.
            val wantPortrait = dispH > dispW
            val isPortrait = bitmap.height > bitmap.width
            if (rot % 180 == 90 && wantPortrait != isPortrait) {
                bitmap = rotate(bitmap, rot)
            }
            if (max(bitmap.width, bitmap.height) > maxDimension) {
                val s = maxDimension.toFloat() / max(bitmap.width, bitmap.height)
                val scaled = Bitmap.createScaledBitmap(
                    bitmap, (bitmap.width * s).roundToInt(), (bitmap.height * s).roundToInt(), true,
                )
                if (scaled != bitmap) bitmap.recycle()
                bitmap = scaled
            }

            val file = File(outDir, "frame_$t.jpg")
            FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            frames.add(
                mapOf("path" to file.absolutePath, "timeMs" to t, "width" to bitmap.width, "height" to bitmap.height),
            )
            bitmap.recycle()
        }
        frames
    }

    private fun rotate(src: Bitmap, degrees: Int): Bitmap {
        val m = Matrix().apply { postRotate(degrees.toFloat()) }
        val out = Bitmap.createBitmap(src, 0, 0, src.width, src.height, m, true)
        if (out != src) src.recycle()
        return out
    }
}
