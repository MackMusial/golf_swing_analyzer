import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:path_provider/path_provider.dart';

import '../analysis/impact_sound.dart';
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

  /// Frame rate of the video being processed.
  double _fps = 30;

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
    final fps = (info?['fps'] as num?)?.toDouble() ?? 30;
    _fps = fps;

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

      onProgress?.call(1, 'Pinpointing contact…');
      final (allFrames, strikeMs) = await _refineImpact(
          detector, videoPath, outDir, frames, fps,
          sampleIntervalMs: interval);

      onProgress?.call(1, 'Analyzing your swing…');
      return analyzeSwing(
        videoPath: videoPath,
        settings: settings,
        rawFrames: allFrames,
        impactSoundMs: strikeMs,
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

  /// At ~30 samples a second the club moves a long way between frames, so a
  /// frame or two off at impact puts the club nowhere near the ball. This
  /// finds contact (from the strike sound if there is one, else the hands)
  /// and adds every real video frame around it.
  ///
  /// Returns all frames in time order, plus the strike time if it was heard.
  Future<(List<PoseFrame>, int?)> _refineImpact(
    PoseDetector detector,
    String videoPath,
    Directory outDir,
    List<PoseFrame> frames,
    double fps, {
    required int sampleIntervalMs,
  }) async {
    final posed = frames.where((f) => f.hasPose).toList();
    final keys = posed.length >= 8 ? detectKeyFrames(smoothFrames(posed)) : null;
    if (keys == null) return (frames, null);

    final topMs = posed[keys.top].timeMs;
    final handImpactMs = posed[keys.impact].timeMs;
    final finishMs = posed[keys.finish].timeMs;

    int? strikeMs;
    try {
      final env = await _channel.invokeMapMethod<String, dynamic>(
        'audioEnvelope',
        {'path': videoPath, 'startMs': topMs, 'endMs': finishMs, 'hopMs': 2},
      );
      final values = env?['values'] as List?;
      if (env != null && values != null) {
        strikeMs = findStrikeMs(
          AudioEnvelope(
            startMs: (env['startMs'] as num).toInt(),
            hopMs: (env['hopMs'] as num).toDouble(),
            values: values.cast<double>(),
          ),
          // Late downswing to mid follow-through: skips any click near the
          // top (another golfer, a cough) but allows for the hands being off.
          fromMs: topMs + ((handImpactMs - topMs) * 0.3).round(),
          toMs: handImpactMs + ((finishMs - handImpactMs) * 0.5).round(),
          expectedMs: handImpactMs,
        );
      }
    } on PlatformException {
      // No audio track or it couldn't be decoded: fall back to the hands.
    }

    final center = strikeMs ?? handImpactMs;
    final frameMs = 1000 / fps;
    final span = math.max(120, sampleIntervalMs * 2.5);
    // Whole video frames per step, at most ~40 extra frames.
    final stepFrames = math.max(1, (span * 2 / 40 / frameMs).ceil());
    final centerFrame = (center / frameMs).floor();
    final reach = (span / frameMs).ceil();
    final have = frames.map((f) => f.timeMs).toList();
    final extra = <int>[
      for (var k = centerFrame - reach; k <= centerFrame + reach; k += stepFrames)
        // +1ms lands squarely on frame k rather than between two frames.
        if (k >= 0)
          if ((k * frameMs).round() + 1 case final t
              when have.every((h) => (h - t).abs() > frameMs * stepFrames / 2))
            t,
    ];
    if (extra.isEmpty) return (frames, strikeMs);

    final dense = await _track(detector, videoPath, outDir, extra, (_) {});
    final all = [...frames, ...dense]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return (all, strikeMs);
  }

  /// Extracts frames at [times] and runs pose detection on each.
  Future<List<PoseFrame>> _track(
    PoseDetector detector,
    String videoPath,
    Directory outDir,
    List<int> times,
    void Function(double fraction) onProgress,
  ) async {
    // Snap each time onto a real video frame (+1ms to land inside it). The
    // decoder returns the nearest frame anyway; snapping keeps our timestamps
    // honest, which matters when matching the strike sound to a frame.
    final frameMs = 1000 / _fps;
    times = {for (final t in times) ((t / frameMs).round() * frameMs).round() + 1}
        .toList()
      ..sort();

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
