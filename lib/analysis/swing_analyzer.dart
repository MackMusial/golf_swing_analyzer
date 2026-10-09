import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../models/swing_models.dart';

typedef L = PoseLandmarkType;

/// Turns raw per-frame poses into key moments, metrics and corrections.
SwingAnalysis analyzeSwing({
  required String videoPath,
  required SwingSettings settings,
  required List<PoseFrame> rawFrames,
}) {
  final posed = rawFrames.where((f) => f.hasPose).toList();
  SwingAnalysis result(List<PoseFrame> frames, KeyFrames? keys,
          List<Metric> metrics, [String? error]) =>
      SwingAnalysis(
        videoPath: videoPath,
        settings: settings,
        frames: frames,
        totalFramesSampled: rawFrames.length,
        keyFrames: keys,
        metrics: metrics,
        error: error,
      );

  if (posed.length < 8) {
    return result(posed, null, const [],
        'Couldn\'t find a golfer in enough frames. Make sure your whole body is in the shot and well lit.');
  }

  final frames = smoothFrames(posed);
  final keys = detectKeyFrames(frames);
  if (keys == null) {
    return result(frames, null, const [],
        'Tracked your body, but couldn\'t find a full swing. Try a clip with one complete swing from address to finish.');
  }
  return result(frames, keys, computeMetrics(frames, keys, settings));
}

/// Light 1-2-1 smoothing over neighbouring frames to cut detector jitter.
List<PoseFrame> smoothFrames(List<PoseFrame> frames) {
  if (frames.length < 3) return frames;
  return [
    for (var i = 0; i < frames.length; i++)
      if (i == 0 || i == frames.length - 1)
        frames[i]
      else
        frames[i].withJoints({
          for (final entry in frames[i].joints!.entries)
            entry.key: _blend(frames[i - 1].joints![entry.key], entry.value,
                frames[i + 1].joints![entry.key]),
        }),
  ];
}

Joint _blend(Joint? prev, Joint cur, Joint? next) {
  if (prev == null || next == null) return cur;
  return Joint(
    (prev.x + 2 * cur.x + next.x) / 4,
    (prev.y + 2 * cur.y + next.y) / 4,
    cur.likelihood,
  );
}

Offset _mid(Offset a, Offset b) => (a + b) / 2;

Offset handPos(PoseFrame f) => _mid(f.at(L.leftWrist), f.at(L.rightWrist));
Offset midHip(PoseFrame f) => _mid(f.at(L.leftHip), f.at(L.rightHip));
Offset midShoulder(PoseFrame f) =>
    _mid(f.at(L.leftShoulder), f.at(L.rightShoulder));
double torsoLength(PoseFrame f) => (midShoulder(f) - midHip(f)).distance;

double _median(List<double> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

/// Finds address, top, impact and finish from the hand path.
///
/// Image y grows downward, so "highest hands" means the smallest y.
KeyFrames? detectKeyFrames(List<PoseFrame> frames) {
  final n = frames.length;
  if (n < 8) return null;

  final hands = frames.map(handPos).toList();
  final scale = _median(frames.map(torsoLength).toList());
  if (scale <= 0) return null;

  // Hand speed in torso-lengths per second.
  final speed = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    final dt = (frames[i].timeMs - frames[i - 1].timeMs) / 1000;
    if (dt > 0) speed[i] = (hands[i] - hands[i - 1]).distance / dt / scale;
  }

  // Walks from [start] in [dir] following the hands while they keep getting
  // higher (or lower), and returns the extreme reached. Small reversals from
  // detector noise are tolerated. Staying local keeps a video with several
  // swings from mixing up one swing's finish with the next one's top.
  int climb(int start, int dir, {required bool higher}) {
    final tol = scale * 0.15;
    var best = start;
    for (var i = start + dir; i >= 0 && i < n; i += dir) {
      final gain = higher
          ? hands[best].dy - hands[i].dy
          : hands[i].dy - hands[best].dy;
      if (gain > 0) {
        best = i;
      } else if (-gain > tol) {
        break;
      }
    }
    return best;
  }

  // The fastest hand movement is in the downswing or just after impact.
  var fastest = 0;
  for (var i = 1; i < n; i++) {
    if (speed[i] > speed[fastest]) fastest = i;
  }
  final movingDown = hands[math.min(fastest + 1, n - 1)].dy >
      hands[math.max(fastest - 1, 0)].dy;
  final impact = climb(fastest, movingDown ? 1 : -1, higher: false);
  final top = climb(impact, -1, higher: true);
  final finish = climb(impact, 1, higher: true);

  // Address: hands lowest before the top, then the last frame before the
  // hands have clearly left that spot (start of takeaway).
  final low = climb(top, -1, higher: false);
  final rise = hands[low].dy - hands[top].dy;
  var address = low;
  while (address + 1 < top &&
      (hands[address + 1] - hands[low]).distance < rise * 0.015) {
    address++;
  }

  if (rise < scale * 0.5 || !(address < top && top < impact && impact <= finish)) {
    return null;
  }
  return KeyFrames(address: address, top: top, impact: impact, finish: finish);
}

/// Sub-frame time of the hand-height extreme at frame [i], found by fitting a
/// parabola through its neighbours. Sharpens tempo beyond the sample rate.
double peakTimeMs(List<PoseFrame> frames, int i) {
  if (i <= 0 || i >= frames.length - 1) return frames[i].timeMs.toDouble();
  final y0 = handPos(frames[i - 1]).dy,
      y1 = handPos(frames[i]).dy,
      y2 = handPos(frames[i + 1]).dy;
  final denom = y0 - 2 * y1 + y2;
  if (denom == 0) return frames[i].timeMs.toDouble();
  final shift = (0.5 * (y0 - y2) / denom).clamp(-0.5, 0.5);
  final dt = shift < 0
      ? frames[i].timeMs - frames[i - 1].timeMs
      : frames[i + 1].timeMs - frames[i].timeMs;
  return frames[i].timeMs + shift * dt;
}

/// Angle at [b] formed by a-b-c, in degrees.
double jointAngle(Offset a, Offset b, Offset c) {
  final v1 = a - b, v2 = c - b;
  final cos = (v1.dx * v2.dx + v1.dy * v2.dy) / (v1.distance * v2.distance);
  return math.acos(cos.clamp(-1.0, 1.0)) * 180 / math.pi;
}

/// Spine lean away from vertical, in degrees (0 = standing straight up).
double spineLean(PoseFrame f) {
  final v = midShoulder(f) - midHip(f);
  return math.atan2(v.dx.abs(), -v.dy) * 180 / math.pi;
}

double _rad2deg(double r) => r * 180 / math.pi;

List<Metric> computeMetrics(
    List<PoseFrame> frames, KeyFrames keys, SwingSettings settings) {
  final address = frames[keys.address];
  final top = frames[keys.top];
  final impact = frames[keys.impact];
  final finish = frames[keys.finish];
  final scale = torsoLength(address);

  final lead = settings.leadIsLeft;
  final leadShoulder = lead ? L.leftShoulder : L.rightShoulder;
  final leadElbow = lead ? L.leftElbow : L.rightElbow;
  final leadWrist = lead ? L.leftWrist : L.rightWrist;
  final leadAnkle = lead ? L.leftAnkle : L.rightAnkle;
  final trailAnkle = lead ? L.rightAnkle : L.leftAnkle;

  final metrics = <Metric>[];

  // Tempo: backswing time vs downswing time. Tour average is about 3:1.
  final back = peakTimeMs(frames, keys.top) - address.timeMs;
  final down = peakTimeMs(frames, keys.impact) - peakTimeMs(frames, keys.top);
  if (back > 0 && down > 0) {
    metrics.add(Metric(
      id: 'tempo',
      name: 'Tempo (backswing : downswing)',
      value: back / down,
      unit: ':1',
      idealMin: 2.5,
      idealMax: 3.5,
      tolerance: 1.0,
      phase: SwingPhase.top,
      description:
          'How long your backswing takes compared to your downswing. Good players are close to 3:1.',
      tipLow:
          'Your backswing is rushed. Take the club back slower and let it fully load at the top before starting down. Try counting "one-two-three" back and "one" down.',
      tipHigh:
          'Your downswing is slow relative to your backswing. Keep the backswing smooth but commit and accelerate through the ball.',
    ));
  }

  // Lead arm at the top: should be close to straight.
  metrics.add(Metric(
    id: 'lead_arm',
    name: 'Lead arm at the top',
    value: jointAngle(top.at(leadShoulder), top.at(leadElbow), top.at(leadWrist)),
    unit: '°',
    // Face-on, the arm points partly at the camera at the top, so it reads
    // more bent than it is.
    idealMin: settings.view == CameraView.faceOn ? 140 : 155,
    idealMax: 180,
    tolerance: 25,
    phase: SwingPhase.top,
    description:
        'Elbow angle of your lead arm at the top of the backswing. 180° is perfectly straight.',
    tipLow:
        'Your lead arm is collapsing at the top. Keep it extended (not locked) to maintain width. Feel like you push your hands away from your chest on the way back.',
    tipHigh: '',
  ));

  // Head movement from address to impact, in torso lengths.
  final headShift = impact.at(L.nose) - address.at(L.nose);
  metrics.add(Metric(
    id: 'head_sway',
    name: 'Head side-to-side movement',
    value: headShift.dx.abs() / scale,
    unit: '×torso',
    idealMin: 0,
    idealMax: 0.2,
    tolerance: 0.3,
    phase: SwingPhase.impact,
    description:
        'How far your head moved sideways between address and impact.',
    tipLow: '',
    tipHigh:
        'Your head is drifting during the swing. Pick a spot on the back of the ball and keep your head over it until after impact.',
  ));
  metrics.add(Metric(
    id: 'head_height',
    name: 'Head up/down movement',
    value: headShift.dy.abs() / scale,
    unit: '×torso',
    idealMin: 0,
    idealMax: 0.12,
    tolerance: 0.2,
    phase: SwingPhase.impact,
    description: 'How much your head rose or dipped between address and impact.',
    tipLow: '',
    tipHigh: headShift.dy < 0
        ? 'Your head is rising before impact, which usually means you\'re standing up. Keep your chest down and maintain your knee flex through the ball.'
        : 'Your head is dipping toward the ball. Stay tall through the backswing and avoid squatting into the downswing.',
  ));

  if (settings.view == CameraView.faceOn) {
    // Image x-direction that points toward the target (lead side).
    final toTarget = (address.at(leadShoulder).dx - address.at(lead ? L.rightShoulder : L.leftShoulder).dx).sign;
    final toTrail = -toTarget;

    metrics.add(Metric(
      id: 'hip_sway',
      name: 'Hip sway on backswing',
      value: (midHip(top).dx - midHip(address).dx) * toTrail / scale,
      unit: '×torso',
      idealMin: -0.05,
      idealMax: 0.15,
      tolerance: 0.25,
      phase: SwingPhase.top,
      description:
          'How far your hips slid away from the target on the backswing. You want to turn, not slide.',
      tipLow:
          'Your hips are moving toward the target on the backswing (a reverse pivot). Feel your weight load into your trail heel as you turn.',
      tipHigh:
          'Your hips are swaying away from the target instead of rotating. Feel your trail hip turn behind you while keeping pressure on the inside of your trail foot.',
    ));

    double turn(L a, L b, PoseFrame f0, PoseFrame f1) {
      final w0 = (f0.at(a) - f0.at(b)).distance;
      final w1 = (f1.at(a) - f1.at(b)).distance;
      return _rad2deg(math.acos((w1 / w0).clamp(0.0, 1.0)));
    }

    metrics.add(Metric(
      id: 'shoulder_turn',
      name: 'Shoulder turn (estimated)',
      value: turn(L.leftShoulder, L.rightShoulder, address, top),
      unit: '°',
      idealMin: 75,
      idealMax: 110,
      tolerance: 30,
      phase: SwingPhase.top,
      description:
          'Estimated shoulder rotation at the top, based on how much narrower your shoulders look to the camera.',
      tipLow:
          'You\'re not turning your shoulders enough. Try to get your lead shoulder under your chin and your back facing the target at the top.',
      tipHigh: '',
    ));
    metrics.add(Metric(
      id: 'hip_turn',
      name: 'Hip turn (estimated)',
      value: turn(L.leftHip, L.rightHip, address, top),
      unit: '°',
      idealMin: 30,
      idealMax: 55,
      tolerance: 20,
      phase: SwingPhase.top,
      description:
          'Estimated hip rotation at the top. Hips should turn about half as much as the shoulders.',
      tipLow:
          'Your hips are too restricted. Let your trail hip turn back freely; this makes a full shoulder turn much easier.',
      tipHigh:
          'Your hips are over-rotating, which loses the stretch between hips and shoulders. Keep your trail knee flexed to resist a bit.',
    ));

    // Where the hips finish between the feet: 0 = trail ankle, 1 = lead ankle.
    final ta = finish.at(trailAnkle).dx, la = finish.at(leadAnkle).dx;
    if ((la - ta).abs() > scale * 0.1) {
      metrics.add(Metric(
        id: 'weight_shift',
        name: 'Weight shift at finish',
        value: (midHip(finish).dx - ta) / (la - ta),
        unit: '',
        idealMin: 0.7,
        idealMax: 1.25,
        tolerance: 0.4,
        phase: SwingPhase.finish,
        description:
            'Where your hips end up between your feet at the finish (0 = over the trail foot, 1 = over the lead foot).',
        tipLow:
            'You\'re hanging back on your trail side. Finish with your belt buckle facing the target and nearly all your weight on your lead foot, trail toe just touching.',
        tipHigh:
            'Your hips are sliding past your lead foot. Rotate around your lead leg instead of pushing laterally.',
      ));
    }
  } else {
    // Down-the-line: posture and early extension.
    final addressLean = spineLean(address);
    metrics.add(Metric(
      id: 'posture',
      name: 'Spine tilt at address',
      value: addressLean,
      unit: '°',
      idealMin: 30,
      idealMax: 50,
      tolerance: 12,
      phase: SwingPhase.address,
      description: 'How far you bend forward from the hips at setup.',
      tipLow:
          'You\'re standing too upright at address. Hinge more from the hips (push your butt back) and let your arms hang under your shoulders.',
      tipHigh:
          'You\'re bent over too much at address. Stand a bit taller with your chest up, still hinged from the hips.',
    ));
    metrics.add(Metric(
      id: 'posture_loss',
      name: 'Spine angle lost at impact',
      value: addressLean - spineLean(impact),
      unit: '°',
      idealMin: -5,
      idealMax: 8,
      tolerance: 12,
      phase: SwingPhase.impact,
      description:
          'How much your forward bend changed from address to impact. Good players keep it nearly the same.',
      tipLow:
          'You\'re bending further over into impact. Stay in your posture and rotate your chest through rather than diving down.',
      tipHigh:
          'You\'re standing up through impact (losing your spine angle). Keep your chest over the ball and feel your hips turn instead of thrusting up.',
    ));

    // Golfer faces the ball; nose sits ahead of the hips toward it.
    final toBall = (address.at(L.nose).dx - midHip(address).dx).sign;
    metrics.add(Metric(
      id: 'early_extension',
      name: 'Hips toward the ball (early extension)',
      value: (midHip(impact).dx - midHip(address).dx) * toBall / scale,
      unit: '×torso',
      idealMin: -0.15,
      idealMax: 0.1,
      tolerance: 0.2,
      phase: SwingPhase.impact,
      description:
          'How far your hips moved toward the ball between address and impact.',
      tipLow:
          'Your hips are backing away from the ball through impact. Feel your lead hip rotate open while your weight stays centered over your feet.',
      tipHigh:
          'Your hips are thrusting toward the ball (early extension), which crowds your arms. Feel your backside stay on an imaginary wall behind you through impact.',
    ));

    final knee = (jointAngle(address.at(L.leftHip), address.at(L.leftKnee), address.at(L.leftAnkle)) +
            jointAngle(address.at(L.rightHip), address.at(L.rightKnee), address.at(L.rightAnkle))) /
        2;
    metrics.add(Metric(
      id: 'knee_flex',
      name: 'Knee flex at address',
      value: knee,
      unit: '°',
      idealMin: 145,
      idealMax: 170,
      tolerance: 15,
      phase: SwingPhase.address,
      description: 'Angle at your knees during setup. 180° is fully straight.',
      tipLow:
          'You\'re squatting too much at address. Soften your knees just slightly; the bend should come mostly from your hips.',
      tipHigh:
          'Your legs are too straight at address. Add a slight knee flex so you can turn and stay athletic.',
    ));
  }

  return metrics;
}
