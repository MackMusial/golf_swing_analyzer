import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/analysis/swing_analyzer.dart';
import 'package:golf_swing_analyzer/models/swing_models.dart';

/// Real swings recorded from the on-device pipeline (the TRACE lines that
/// integration_test/pipeline_test.dart prints), one frame per line:
/// `timeMs handX handY hipX hipY leftShoulderX leftShoulderY rightShoulderX rightShoulderY`.
/// Values are already smoothed, which is what detectKeyFrames sees.
List<PoseFrame> loadSwing(String name) {
  final lines = File('test/fixtures/swings/$name.txt').readAsLinesSync();
  Joint j(int x, int y) => Joint(x.toDouble(), y.toDouble(), 0.99);
  return [
    for (final line in lines)
      if (line.trim().isNotEmpty)
        if (line.trim().split(' ').map(int.parse).toList() case final v)
          PoseFrame(
            timeMs: v[0],
            imagePath: '',
            width: 720,
            height: 720,
            joints: {
              L.leftWrist: j(v[1], v[2]),
              L.rightWrist: j(v[1], v[2]),
              L.leftHip: j(v[3], v[4]),
              L.rightHip: j(v[3], v[4]),
              L.leftShoulder: j(v[5], v[6]),
              L.rightShoulder: j(v[7], v[8]),
            },
          ),
  ];
}

/// Hand-labelled key moments from watching each clip's hand path: the window
/// (ms) each one must land in. Address is the last still moment before the
/// takeaway (shoulders and hands turning together), not some earlier point
/// while the golfer is still settling in or pressing the hands forward.
/// Finish is when the follow-through stops.
const expected = {
  'pexels_6541855': (
    address: (2200, 2800),
    top: (4250, 4950),
    impact: (5460, 5610),
    finish: (6100, 6450),
  ),
  'pexels_6541964': (
    address: (4700, 5050),
    top: (6290, 6580),
    impact: (7060, 7210),
    finish: (8190, 8610),
  ),
  'pexels_14980434': (
    address: (9800, 10050),
    top: (10930, 11070),
    impact: (11360, 11440),
    finish: (11630, 12010),
  ),
  'pexels_6541665': (
    address: (500, 1000),
    top: (2550, 2950),
    impact: (3860, 3940),
    finish: (5100, 5340),
  ),
  'pexels_6541682': (
    address: (7700, 7900),
    top: (9230, 9420),
    impact: (10100, 10170),
    finish: (11450, 11970),
  ),
  'pexels_6542255': (
    address: (2850, 3050),
    top: (4250, 4750),
    impact: (5290, 5380),
    finish: (6000, 6320),
  ),
  // A full practice swing (0.5-2.9s) comes first. The real one is faster.
  'pexels_6573621': (
    address: (5250, 5420),
    top: (6100, 6520),
    impact: (6760, 6840),
    finish: (7150, 7320),
  ),
  // One-piece takeaway from 8.0s: the shoulders turn with the hands, even
  // though the hands' first move in this view is sideways.
  'pexels_37080178': (
    address: (7900, 8100),
    top: (8830, 9000),
    impact: (9230, 9300),
    finish: (9560, 9720),
  ),
  // Hand-held camera that pans to follow the golfer. Hands hold at the top
  // from 3.10s to 3.43s while the club keeps going.
  'pexels_37030686': (
    address: (2150, 2300),
    top: (3050, 3450),
    impact: (3730, 3840),
    finish: (4100, 4250),
  ),
  // Filmed from behind. The hands creep toward the target from 11.3s with
  // the shoulders still (a forward press); the takeaway starts at 11.75s.
  // The hands keep drifting up through the held finish.
  'pexels_38098104': (
    address: (11600, 11800),
    top: (12650, 12900),
    impact: (13130, 13240),
    finish: (13500, 13700),
  ),
  // Slow motion. Impact is the strike-sound frame (9134ms), which the hands
  // alone get within a couple of frames of.
  'sample_faceon': (
    address: (700, 1250),
    top: (6560, 7100),
    impact: (9000, 9170),
    finish: (11950, 12900),
  ),
  'sample_dtl': (
    address: (2200, 2500),
    top: (6400, 7000),
    impact: (9100, 9300),
    finish: (12000, 12500),
  ),
};

/// The same swing with a couple of pixels of detector jitter, then smoothed
/// the way the app does it. Key moments mustn't hinge on exact pixel values.
List<PoseFrame> jittered(List<PoseFrame> frames, int seed) {
  final rng = math.Random(seed);
  double n() => (rng.nextDouble() * 2 - 1) * 2;
  return smoothFrames([
    for (final f in frames)
      f.withJoints({
        for (final MapEntry(key: t, value: j) in f.joints!.entries)
          t: Joint(j.x + n(), j.y + n(), j.likelihood),
      }),
  ]);
}

void main() {
  for (final (name, seed) in [
    for (final name in expected.keys) ...[(name, null), (name, 1), (name, 2)],
  ]) {
    test('finds the key moments of real swing $name'
        '${seed == null ? '' : ' with jitter $seed'}', () {
      final clean = loadSwing(name);
      final frames = seed == null ? clean : jittered(clean, seed);
      final keys = detectKeyFrames(frames);
      expect(keys, isNotNull);
      final want = expected[name]!;
      final got = {
        'address': (frames[keys!.address].timeMs, want.address),
        'top': (frames[keys.top].timeMs, want.top),
        'impact': (frames[keys.impact].timeMs, want.impact),
        'finish': (frames[keys.finish].timeMs, want.finish),
      };
      for (final MapEntry(key: phase, value: (ms, (lo, hi))) in got.entries) {
        expect(ms, inInclusiveRange(lo, hi), reason: '$phase at ${ms}ms');
      }
    });
  }

  // Checked by eye on each clip. Side views include ones filmed from the
  // target side, which the app treats as down-the-line.
  const views = {
    'pexels_14980434': CameraView.downTheLine,
    'pexels_37080178': CameraView.downTheLine,
    'pexels_6541665': CameraView.downTheLine,
    'pexels_6541855': CameraView.downTheLine,
    'pexels_6541964': CameraView.downTheLine,
    'pexels_6541682': CameraView.downTheLine,
    'pexels_6542255': CameraView.downTheLine,
    'sample_dtl': CameraView.downTheLine,
    'sample_faceon': CameraView.faceOn,
    'pexels_6573621': CameraView.faceOn,
    'pexels_37030686': CameraView.downTheLine,
    'pexels_38098104': CameraView.downTheLine,
  };
  for (final MapEntry(key: name, value: view) in views.entries) {
    test('recognizes $name as ${view.label}', () {
      final frames = loadSwing(name);
      final keys = detectKeyFrames(frames)!;
      final seen = detectCameraView(frames, keys.address);
      expect(seen.view, view);
      expect(seen.clear, isTrue);
    });
  }

  test('rejects a clip of chip shots (no full swing)', () {
    // Hand-held camera following a golfer chipping: the hands never get much
    // above the hips, so there is no full swing to measure.
    expect(detectKeyFrames(loadSwing('pexels_34883764')), isNull);
  });

  test('print key moments of every recorded swing', () {
    for (final f in Directory('test/fixtures/swings').listSync()) {
      final name = f.uri.pathSegments.last.replaceAll('.txt', '');
      final frames = loadSwing(name);
      final k = detectKeyFrames(frames);
      // ignore: avoid_print
      print(k == null
          ? '$name: no swing'
          : '$name: address ${frames[k.address].timeMs} top ${frames[k.top].timeMs} '
              'impact ${frames[k.impact].timeMs} finish ${frames[k.finish].timeMs}');
    }
  });
}
