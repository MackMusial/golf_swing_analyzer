import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../models/swing_models.dart';

typedef _L = PoseLandmarkType;

const _bones = <(_L, _L)>[
  (_L.leftShoulder, _L.rightShoulder),
  (_L.leftHip, _L.rightHip),
  (_L.leftShoulder, _L.leftHip),
  (_L.rightShoulder, _L.rightHip),
  (_L.leftShoulder, _L.leftElbow),
  (_L.leftElbow, _L.leftWrist),
  (_L.rightShoulder, _L.rightElbow),
  (_L.rightElbow, _L.rightWrist),
  (_L.leftHip, _L.leftKnee),
  (_L.leftKnee, _L.leftAnkle),
  (_L.rightHip, _L.rightKnee),
  (_L.rightKnee, _L.rightAnkle),
  (_L.leftAnkle, _L.leftHeel),
  (_L.leftHeel, _L.leftFootIndex),
  (_L.rightAnkle, _L.rightHeel),
  (_L.rightHeel, _L.rightFootIndex),
];

const _drawnJoints = {
  _L.nose,
  _L.leftShoulder, _L.rightShoulder, _L.leftElbow, _L.rightElbow,
  _L.leftWrist, _L.rightWrist, _L.leftHip, _L.rightHip,
  _L.leftKnee, _L.rightKnee, _L.leftAnkle, _L.rightAnkle,
};

/// Draws the tracked skeleton for [frame], scaled to fill the paint area.
///
/// Lead side is drawn in orange, trail side in cyan, so you can tell them apart.
class SkeletonPainter extends CustomPainter {
  final PoseFrame? frame;
  final bool leadIsLeft;

  SkeletonPainter(this.frame, {required this.leadIsLeft});

  static const leadColor = Color(0xFFFF9F1C);
  static const trailColor = Color(0xFF2EC4B6);
  static const centerColor = Colors.white;

  Color _colorFor(_L type) {
    final name = type.name;
    if (!name.startsWith('left') && !name.startsWith('right')) {
      return centerColor;
    }
    return name.startsWith('left') == leadIsLeft ? leadColor : trailColor;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null || !f.hasPose) return;
    final sx = size.width / f.width, sy = size.height / f.height;
    Offset? pt(_L t) {
      final j = f.joints![t];
      return j == null ? null : Offset(j.x * sx, j.y * sy);
    }

    final shadow = Paint()
      ..color = Colors.black54
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final bone = Paint()
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    for (final (a, b) in _bones) {
      final pa = pt(a), pb = pt(b);
      if (pa == null || pb == null) continue;
      final ca = _colorFor(a), cb = _colorFor(b);
      bone.color = ca == cb ? ca : centerColor;
      canvas.drawLine(pa, pb, shadow);
      canvas.drawLine(pa, pb, bone);
    }

    // Spine line from hip center to shoulder center.
    final ls = pt(_L.leftShoulder), rs = pt(_L.rightShoulder);
    final lh = pt(_L.leftHip), rh = pt(_L.rightHip);
    if (ls != null && rs != null && lh != null && rh != null) {
      final spine = Paint()
        ..color = Colors.yellowAccent
        ..strokeWidth = 2.5;
      canvas.drawLine((lh + rh) / 2, (ls + rs) / 2, spine);
    }

    final dot = Paint();
    final ring = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final t in _drawnJoints) {
      final p = pt(t);
      if (p == null) continue;
      final likely = (f.joints![t]!.likelihood).clamp(0.3, 1.0);
      dot.color = _colorFor(t).withValues(alpha: likely);
      canvas.drawCircle(p, 5, dot);
      canvas.drawCircle(p, 5, ring);
    }
  }

  @override
  bool shouldRepaint(SkeletonPainter old) =>
      old.frame != frame || old.leadIsLeft != leadIsLeft;
}
