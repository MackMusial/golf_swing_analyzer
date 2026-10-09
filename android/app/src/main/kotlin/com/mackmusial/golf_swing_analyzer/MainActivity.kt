package com.mackmusial.golf_swing_analyzer

import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Hosts the "golf_swing_analyzer/frames" channel: exact-frame extraction from a
 * video file, plus an audio "click energy" envelope for finding the strike.
 */
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
                        val value: Any? = when (call.method) {
                            "probe" -> probe(path)
                            "extractFrames" -> extractFrames(
                                path,
                                call.argument<List<Int>>("timesMs") ?: emptyList(),
                                call.argument<String>("outDir")!!,
                                call.argument<Int>("maxDimension") ?: 720,
                            )
                            "audioEnvelope" -> audioEnvelope(
                                path,
                                call.argument<Int>("startMs") ?: 0,
                                call.argument<Int>("endMs") ?: 0,
                                call.argument<Int>("hopMs") ?: 2,
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
        val durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
        mapOf(
            "durationMs" to durationMs,
            "width" to w,
            "height" to h,
            "fps" to frameRate(path, mmr, durationMs),
        )
    }

    /** Frames per second of the video track; 30 if the file doesn't say. */
    private fun frameRate(path: String, mmr: MediaMetadataRetriever, durationMs: Long): Double {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true &&
                    f.containsKey(MediaFormat.KEY_FRAME_RATE)
                ) {
                    val fps = try {
                        f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
                    } catch (e: ClassCastException) {
                        f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble()
                    }
                    if (fps > 0) return fps
                }
            }
        } catch (e: Exception) {
            // Fall through to the frame count below.
        } finally {
            ex.release()
        }
        if (Build.VERSION.SDK_INT >= 28 && durationMs > 0) {
            val count = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT)?.toDoubleOrNull()
            if (count != null && count > 0) return count * 1000.0 / durationMs
        }
        return 30.0
    }

    /**
     * Click energy of the audio between [startMs] and [endMs]: for each [hopMs]
     * slice, the mean squared change between consecutive (mono) samples. That
     * high-passes the sound, so a club striking a ball stands far above wind
     * and voices. Returns null if the video has no audio track.
     */
    private fun audioEnvelope(path: String, startMs: Int, endMs: Int, hopMs: Int): Map<String, Any>? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(path)
            var format: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    ex.selectTrack(i)
                    format = f
                    break
                }
            }
            if (format == null) return null

            val hops = maxOf(1, (endMs - startMs) / hopMs)
            val sums = DoubleArray(hops)
            val counts = IntArray(hops)
            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var floatPcm = false
            var prev = 0.0
            var havePrev = false

            ex.seekTo(startMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(format, null, null, 0)
            codec.start()

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            while (true) {
                if (!inputDone) {
                    val inIdx = codec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val size = ex.readSampleData(codec.getInputBuffer(inIdx)!!, 0)
                        if (size < 0 || ex.sampleTime > (endMs + 200) * 1000L) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, size, ex.sampleTime, 0)
                            ex.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val of = codec.outputFormat
                    sampleRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    floatPcm = of.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        of.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                } else if (outIdx >= 0) {
                    if (info.size > 0) {
                        val buf = codec.getOutputBuffer(outIdx)!!.order(ByteOrder.nativeOrder())
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val n = info.size / ((if (floatPcm) 4 else 2) * channels)
                        val t0 = info.presentationTimeUs / 1000.0
                        for (k in 0 until n) {
                            var s = 0.0
                            for (c in 0 until channels) {
                                s += if (floatPcm) buf.float.toDouble() else buf.short / 32768.0
                            }
                            s /= channels
                            if (havePrev) {
                                val idx = ((t0 + k * 1000.0 / sampleRate - startMs) / hopMs).toInt()
                                if (idx in 0 until hops) {
                                    val d = s - prev
                                    sums[idx] += d * d
                                    counts[idx]++
                                }
                            }
                            prev = s
                            havePrev = true
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            return mapOf(
                "startMs" to startMs,
                "hopMs" to hopMs,
                "values" to DoubleArray(hops) { if (counts[it] > 0) sums[it] / counts[it] else 0.0 },
            )
        } finally {
            try {
                codec?.stop()
            } catch (e: IllegalStateException) {
                // Never started.
            }
            codec?.release()
            ex.release()
        }
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
