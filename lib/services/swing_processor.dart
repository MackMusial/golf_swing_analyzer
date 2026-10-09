import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:path_provider/path_provider.dart';

import '../analysis/swing_analyzer.dart';
import '../models/swing_models.dart';

typedef ProgressCallback = void Function(double fraction, String message);

/// Pulls frames out of a video (native code), runs pose detection on each,
/// then hands the poses to the analyzer.
///
/// Long videos get two passes: a coarse scan of the whole clip to find where
/// the swing is, then a ~30 fps pass over just that window.
class SwingProcessor {
  static const _channel = MethodChannel('golf_swing_analyzer/frames');

  /// Upper bound on frames in the detailed pass.
  static const maxFrames = 150;
  static const minIntervalMs = 33; // ~30 fps
  static const _coarseFrames = 90;
  static const _batchSize = 6;

  /// Videos this short skip the coarse scan and go straight to the detailed pass.
  static const _shortVideoMs = 5000;

  Future<SwingAnalysis> process(
    String videoPath,
    SwingSettings settings, {
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(0, 'Reading video…');
    final info = await _channel
        .invokeMapMethod<String, dynamic>('probe', {'path': videoPath});
    final durationMs = (info?['durationMs'] as num?)?.toInt() ?? 0;
    if (durationMs <= 0) {
      throw Exception('Could not read the video length.');
    }

    final outDir = Directory(
        '${(await getTemporaryDirectory()).path}/swing_${DateTime.now().millisecondsSinceEpoch}');
    await outDir.create(recursive: true);

    final detector = PoseDetector(
      options: PoseDetectorOptions(
        mode: PoseDetectionMode.single,
        model: PoseDetectionModel.accurate,
      ),
    );

    try {
      var start = 0, end = durationMs;
      var fineShare = 1.0;

      if (durationMs > _shortVideoMs) {
        fineShare = 0.6;
        final interval = math.max(100, durationMs ~/ _coarseFrames);
        final coarse = await _track(
          detector,
          videoPath,
          outDir,
          [for (var t = 0; t < durationMs; t += interval) t],
          (p) => onProgress?.call(p * (1 - fineShare), 'Finding your swing…'),
        );
        (start, end) = _swingWindow(coarse, durationMs);
      }

      final interval =
          math.max(minIntervalMs, ((end - start) / maxFrames).ceil());
      final times = [for (var t = start; t < end; t += interval) t];
      final frames = await _track(
        detector,
        videoPath,
        outDir,
        times,
        (p) => onProgress?.call(
          (1 - fineShare) + p * fineShare,
          'Tracking your body… ${(p * times.length).round()}/${times.length} frames',
        ),
      );

      onProgress?.call(1, 'Analyzing your swing…');
      return analyzeSwing(
        videoPath: videoPath,
        settings: settings,
        rawFrames: frames,
      );
    } finally {
      await detector.close();
    }
  }

  /// Picks the part of the video that contains the swing, padded a little.
  (int, int) _swingWindow(List<PoseFrame> coarse, int durationMs) {
    final posed = coarse.where((f) => f.hasPose).toList();
    int clampMs(num t) => t.round().clamp(0, durationMs);

    // Best case: the coarse frames are enough to spot the whole swing.
    final keys = posed.length >= 8 ? detectKeyFrames(smoothFrames(posed)) : null;
    if (keys != null) {
      final a = posed[keys.address].timeMs, f = posed[keys.finish].timeMs;
      final pad = math.max(600, (f - a) * 0.25);
      return (clampMs(a - pad), clampMs(f + pad));
    }

    // Otherwise centre a window on the biggest jump in hand position.
    if (posed.length < 2) return (0, durationMs);
    var bestT = posed.first.timeMs;
    var bestMove = -1.0;
    for (var i = 1; i < posed.length; i++) {
      final move = (handPos(posed[i]) - handPos(posed[i - 1])).distance /
          math.max(1.0, torsoLength(posed[i]));
      if (move > bestMove) {
        bestMove = move;
        bestT = (posed[i].timeMs + posed[i - 1].timeMs) ~/ 2;
      }
    }
    return (clampMs(bestT - 2500), clampMs(bestT + 2000));
  }

  /// Extracts frames at [times] and runs pose detection on each.
  Future<List<PoseFrame>> _track(
    PoseDetector detector,
    String videoPath,
    Directory outDir,
    List<int> times,
    void Function(double fraction) onProgress,
  ) async {
    final result = <PoseFrame>[];
    for (var i = 0; i < times.length; i += _batchSize) {
      final batch = times.sublist(i, math.min(i + _batchSize, times.length));
      final extracted = await _channel.invokeListMethod<Map>(
            'extractFrames',
            {
              'path': videoPath,
              'timesMs': batch,
              'outDir': outDir.path,
              'maxDimension': 720,
            },
          ) ??
          const [];

      for (final frame in extracted) {
        final imagePath = frame['path'] as String;
        final poses =
            await detector.processImage(InputImage.fromFilePath(imagePath));
        result.add(PoseFrame(
          timeMs: (frame['timeMs'] as num).toInt(),
          imagePath: imagePath,
          width: (frame['width'] as num).toInt(),
          height: (frame['height'] as num).toInt(),
          joints: poses.isEmpty
              ? null
              : {
                  for (final lm in poses.first.landmarks.values)
                    lm.type: Joint(lm.x, lm.y, lm.likelihood),
                },
        ));
      }
      onProgress(math.min(i + _batchSize, times.length) / times.length);
    }
    return result;
  }
}
