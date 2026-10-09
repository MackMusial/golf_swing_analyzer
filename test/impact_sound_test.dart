import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/analysis/impact_sound.dart';

/// 4 seconds of background noise at 2 ms per hop, with clicks added at
/// [clicksMs]. Each click has a sharp attack and a ~10 ms ring-down, like a
/// real strike. [gustsMs] adds slower, weaker bumps (wind on the mic).
AudioEnvelope fakeEnvelope({
  List<int> clicksMs = const [],
  List<int> gustsMs = const [],
  double clickSize = 5000,
}) {
  const hop = 2.0;
  final rng = math.Random(7);
  final v = List<double>.generate(2000, (_) => 1 + rng.nextDouble());
  for (final c in clicksMs) {
    final i = (c / hop).round();
    for (var k = 0; k < 6; k++) {
      v[i + k] += clickSize * math.pow(0.5, k);
    }
  }
  for (final g in gustsMs) {
    final i = (g / hop).round();
    for (var k = -40; k <= 40; k++) {
      v[i + k] += 15 * math.exp(-k * k / 400);
    }
  }
  return AudioEnvelope(startMs: 0, hopMs: hop, values: v);
}

void main() {
  test('finds the strike click inside the window', () {
    final env = fakeEnvelope(clicksMs: [1500]);
    final t = findStrikeMs(env, fromMs: 1000, toMs: 2500, expectedMs: 1450);
    expect(t, closeTo(1500, 4));
  });

  test('ignores a louder click outside the window (another golfer)', () {
    final env = fakeEnvelope(clicksMs: [600, 1500]);
    final t = findStrikeMs(env, fromMs: 1000, toMs: 2500, expectedMs: 1450);
    expect(t, closeTo(1500, 4));
  });

  test('picks the click nearest the expected time when two qualify', () {
    final env = fakeEnvelope(clicksMs: [1200, 2200]);
    expect(findStrikeMs(env, fromMs: 1000, toMs: 2500, expectedMs: 2100),
        closeTo(2200, 4));
    expect(findStrikeMs(env, fromMs: 1000, toMs: 2500, expectedMs: 1300),
        closeTo(1200, 4));
  });

  test('no strike in plain noise or wind', () {
    final env = fakeEnvelope(gustsMs: [1400, 2000]);
    expect(findStrikeMs(env, fromMs: 1000, toMs: 2500, expectedMs: 1500), isNull);
  });

  test('no strike in a silent track', () {
    final env = AudioEnvelope(startMs: 0, hopMs: 2, values: List.filled(2000, 0.0));
    expect(findStrikeMs(env, fromMs: 1000, toMs: 2500, expectedMs: 1500), isNull);
  });

  test('a faint tap is not a strike', () {
    final env = fakeEnvelope(clicksMs: [1500], clickSize: 20);
    expect(findStrikeMs(env, fromMs: 1000, toMs: 2500, expectedMs: 1500), isNull);
  });

  test('envelope that starts mid-video reports absolute times', () {
    final base = fakeEnvelope(clicksMs: [1500]);
    final env = AudioEnvelope(startMs: 6000, hopMs: base.hopMs, values: base.values);
    expect(findStrikeMs(env, fromMs: 7000, toMs: 8500, expectedMs: 7400),
        closeTo(7500, 4));
  });
}
