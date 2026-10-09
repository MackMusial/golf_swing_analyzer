import 'dart:ui';

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

enum Handedness { right, left }

enum CameraView { faceOn, downTheLine }

extension CameraViewLabel on CameraView {
  String get label => switch (this) {
        CameraView.faceOn => 'Face-on',
        CameraView.downTheLine => 'Down-the-line',
      };
}

class SwingSettings {
  final Handedness handedness;
  final CameraView view;

  const SwingSettings({
    this.handedness = Handedness.right,
    this.view = CameraView.faceOn,
  });

  /// Lead side = the side closer to the target (left arm for a right-handed golfer).
  bool get leadIsLeft => handedness == Handedness.right;
}

/// One joint position in image pixels.
class Joint {
  final double x;
  final double y;
  final double likelihood;

  const Joint(this.x, this.y, this.likelihood);

  Offset get offset => Offset(x, y);
}

/// One sampled video frame and the pose found in it (if any).
class PoseFrame {
  final int timeMs;
  final String imagePath;
  final int width;
  final int height;
  final Map<PoseLandmarkType, Joint>? joints;

  const PoseFrame({
    required this.timeMs,
    required this.imagePath,
    required this.width,
    required this.height,
    required this.joints,
  });

  bool get hasPose => joints != null && joints!.isNotEmpty;

  Offset at(PoseLandmarkType type) => joints![type]!.offset;

  PoseFrame withJoints(Map<PoseLandmarkType, Joint> newJoints) => PoseFrame(
        timeMs: timeMs,
        imagePath: imagePath,
        width: width,
        height: height,
        joints: newJoints,
      );
}

enum SwingPhase { address, top, impact, finish }

extension SwingPhaseLabel on SwingPhase {
  String get label => switch (this) {
        SwingPhase.address => 'Address',
        SwingPhase.top => 'Top',
        SwingPhase.impact => 'Impact',
        SwingPhase.finish => 'Finish',
      };
}

/// Indices into [SwingAnalysis.frames] for each key moment.
class KeyFrames {
  final int address;
  final int top;
  final int impact;
  final int finish;

  const KeyFrames({
    required this.address,
    required this.top,
    required this.impact,
    required this.finish,
  });

  int operator [](SwingPhase phase) => switch (phase) {
        SwingPhase.address => address,
        SwingPhase.top => top,
        SwingPhase.impact => impact,
        SwingPhase.finish => finish,
      };
}

enum MetricStatus { good, minor, fault }

class Metric {
  final String id;
  final String name;
  final double value;
  final String unit;
  final double idealMin;
  final double idealMax;

  /// How far outside the ideal range counts as a full-severity fault.
  final double tolerance;
  final SwingPhase phase;
  final String description;
  final String tipLow;
  final String tipHigh;

  const Metric({
    required this.id,
    required this.name,
    required this.value,
    required this.unit,
    required this.idealMin,
    required this.idealMax,
    required this.tolerance,
    required this.phase,
    required this.description,
    required this.tipLow,
    required this.tipHigh,
  });

  /// 0 when inside the ideal range, up to 1 at [tolerance] beyond it.
  double get severity {
    final miss = value < idealMin
        ? idealMin - value
        : value > idealMax
            ? value - idealMax
            : 0.0;
    return (miss / tolerance).clamp(0.0, 1.0);
  }

  MetricStatus get status => severity == 0
      ? MetricStatus.good
      : severity < 0.5
          ? MetricStatus.minor
          : MetricStatus.fault;

  bool get isLow => value < idealMin;

  String? get tip => severity == 0 ? null : (isLow ? tipLow : tipHigh);

  String format(double v) {
    final digits = unit == '°' ? 0 : (unit == ':1' ? 1 : 2);
    return '${v.toStringAsFixed(digits)}$unit';
  }

  String get valueText => format(value);
  String get idealText => '${format(idealMin)} – ${format(idealMax)}';
}

class SwingAnalysis {
  final String videoPath;
  final SwingSettings settings;

  /// Smoothed frames that contain a pose, in time order.
  final List<PoseFrame> frames;
  final int totalFramesSampled;
  final KeyFrames? keyFrames;
  final List<Metric> metrics;
  final String? error;

  /// When the club hit the ball, from the sound of the strike. Null when the
  /// video has no clear strike sound and impact was estimated from the hands.
  final int? impactSoundMs;

  const SwingAnalysis({
    required this.videoPath,
    required this.settings,
    required this.frames,
    required this.totalFramesSampled,
    required this.keyFrames,
    required this.metrics,
    this.error,
    this.impactSoundMs,
  });

  /// Metrics outside their ideal range, worst first.
  List<Metric> get issues =>
      metrics.where((m) => m.severity > 0).toList()
        ..sort((a, b) => b.severity.compareTo(a.severity));

  int get score {
    if (metrics.isEmpty) return 0;
    final penalty = metrics.fold<double>(0, (sum, m) => sum + m.severity);
    return (100 - penalty * 100 / metrics.length * 1.5).round().clamp(0, 100);
  }

  /// Frame whose timestamp is closest to [timeMs], or null if none is near.
  PoseFrame? frameNear(int timeMs, {int maxGapMs = 120}) {
    if (frames.isEmpty) return null;
    var lo = 0, hi = frames.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (frames[mid].timeMs < timeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var best = lo;
    if (lo > 0 &&
        (timeMs - frames[lo - 1].timeMs).abs() <
            (frames[lo].timeMs - timeMs).abs()) {
      best = lo - 1;
    }
    return (frames[best].timeMs - timeMs).abs() <= maxGapMs
        ? frames[best]
        : null;
  }
}
