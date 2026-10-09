import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/analysis/swing_analyzer.dart';
import 'package:golf_swing_analyzer/models/swing_models.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Hand height (image y, smaller = higher) over time for a fake swing:
/// still at address until 0.8s, backswing to 1.7s, downswing to 2.0s,
/// follow-through to 2.5s, then hold.
double handY(double t) {
  double ease(double x) => (1 - math.cos(math.pi * x.clamp(0, 1))) / 2;
  if (t < 0.8) return 600;
  if (t < 1.7) return 600 - 350 * ease((t - 0.8) / 0.9);
  if (t < 2.0) return 250 + 350 * ease((t - 1.7) / 0.3);
  if (t < 2.5) return 600 - 400 * ease((t - 2.0) / 0.5);
  return 200;
}

PoseFrame fakeFrame(int ms, {double? handHeight}) {
  final t = ms / 1000;
  final hy = handHeight ?? handY(t);
  final hand = Offset(500, hy);
  Joint j(double x, double y) => Joint(x, y, 0.99);
  const ls = Offset(560, 300), rs = Offset(440, 300);
  return PoseFrame(
    timeMs: ms,
    imagePath: '',
    width: 1000,
    height: 1000,
    joints: {
      PoseLandmarkType.nose: j(500, 230),
      PoseLandmarkType.leftShoulder: j(ls.dx, ls.dy),
      PoseLandmarkType.rightShoulder: j(rs.dx, rs.dy),
      PoseLandmarkType.leftElbow: j((ls.dx + hand.dx) / 2, (ls.dy + hy) / 2),
      PoseLandmarkType.rightElbow: j((rs.dx + hand.dx) / 2, (rs.dy + hy) / 2),
      PoseLandmarkType.leftWrist: j(hand.dx + 5, hy),
      PoseLandmarkType.rightWrist: j(hand.dx - 5, hy),
      PoseLandmarkType.leftHip: j(540, 500),
      PoseLandmarkType.rightHip: j(460, 500),
      PoseLandmarkType.leftKnee: j(550, 650),
      PoseLandmarkType.rightKnee: j(450, 650),
      PoseLandmarkType.leftAnkle: j(570, 800),
      PoseLandmarkType.rightAnkle: j(430, 800),
    },
  );
}

void main() {
  final frames = [for (var ms = 0; ms < 3000; ms += 33) fakeFrame(ms)];

  test('finds address, top, impact and finish in order', () {
    final keys = detectKeyFrames(smoothFrames(frames))!;
    int ms(int i) => frames[i].timeMs;
    expect(ms(keys.address), closeTo(800, 100));
    expect(ms(keys.top), closeTo(1700, 70));
    expect(ms(keys.impact), closeTo(2000, 70));
    expect(ms(keys.finish), greaterThan(2300));
  });

  test('keeps key moments within one swing when the video has two', () {
    // Swing 1 runs 0-3s, hands lower slowly back to address over 3-5s,
    // then the same swing repeats starting at 5s.
    double y(int ms) => ms < 3000
        ? handY(ms / 1000)
        : ms < 5000
            ? 200 + 400 * (ms - 3000) / 2000
            : handY((ms - 5000) / 1000);
    final twoSwings = [
      for (var ms = 0; ms < 8000; ms += 33)
        fakeFrame(ms, handHeight: y(ms)),
    ];
    final keys = detectKeyFrames(smoothFrames(twoSwings))!;
    int ms(int i) => twoSwings[i].timeMs;
    final swingStart = ms(keys.impact) < 3000 ? 0 : 5000;
    expect(ms(keys.top) - swingStart, closeTo(1700, 70));
    expect(ms(keys.address) - swingStart, closeTo(800, 100));
    expect(ms(keys.finish) - swingStart, greaterThan(2300));
  });

  test('computes about a 3:1 tempo and flags nothing for a clean swing', () {
    final analysis = analyzeSwing(
      videoPath: 'x.mp4',
      settings: const SwingSettings(),
      rawFrames: frames,
    );
    expect(analysis.error, isNull);
    final tempo = analysis.metrics.firstWhere((m) => m.id == 'tempo');
    expect(tempo.value, closeTo(3.0, 0.6));
    expect(analysis.metrics.firstWhere((m) => m.id == 'head_sway').severity, 0);
  });

  test('reports an error when no swing happens', () {
    final still = [for (var ms = 0; ms < 2000; ms += 33) fakeFrame(0)]
        .indexed
        .map((e) => PoseFrame(
              timeMs: e.$1 * 33,
              imagePath: '',
              width: 1000,
              height: 1000,
              joints: e.$2.joints,
            ))
        .toList();
    final analysis = analyzeSwing(
      videoPath: 'x.mp4',
      settings: const SwingSettings(),
      rawFrames: still,
    );
    expect(analysis.error, isNotNull);
  });

  test('flags a collapsed lead arm', () {
    final m = Metric(
      id: 'lead_arm', name: '', value: 120, unit: '°',
      idealMin: 155, idealMax: 180, tolerance: 25,
      phase: SwingPhase.top, description: '', tipLow: 'bent', tipHigh: '',
    );
    expect(m.status, MetricStatus.fault);
    expect(m.tip, 'bent');
  });
}
