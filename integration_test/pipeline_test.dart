import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/analysis/swing_analyzer.dart';
import 'package:golf_swing_analyzer/models/swing_models.dart';
import 'package:golf_swing_analyzer/screens/results_screen.dart';
import 'package:golf_swing_analyzer/services/swing_processor.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Runs the real pipeline (native frame extraction + ML Kit + analyzer) on a
/// freely licensed swing video from Wikimedia Commons (phone-style portrait, slow motion).
/// Override with --dart-define=VIDEO_URL=... and VIEW=dtl to test other clips.
const _videoUrl = String.fromEnvironment('VIDEO_URL',
    defaultValue:
        'https://upload.wikimedia.org/wikipedia/commons/9/9e/Suvichaya_Vinijchaitham_Golf_Swing_Slow_Mo_2026.webm');
const _view = String.fromEnvironment('VIEW', defaultValue: 'faceOn');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('analyzes a real swing video', (tester) async {
    final dir = await getApplicationSupportDirectory();
    final video = File('${dir.path}/test_swing.${_videoUrl.split('.').last}');
    await tester.runAsync(() async {
      final req = await HttpClient().getUrl(Uri.parse(_videoUrl));
      req.headers.set('User-Agent', 'golf-swing-analyzer-test/1.0');
      final res = await req.close();
      await res.pipe(video.openWrite());
    });

    late SwingAnalysis analysis;
    await tester.runAsync(() async {
      analysis = await SwingProcessor().process(
        video.path,
        SwingSettings(
          view: _view == 'dtl' ? CameraView.downTheLine : CameraView.faceOn,
        ),
        onProgress: (p, m) => debugPrint('PROGRESS $m'),
      );
    });

    for (final f in analysis.frames) {
      final h = handPos(f), hip = midHip(f);
      debugPrint('TRACE ${f.timeMs} hand=${h.dx.round()},${h.dy.round()} hip=${hip.dx.round()},${hip.dy.round()} torso=${torsoLength(f).round()}');
    }
    debugPrint('RESULT frames=${analysis.frames.length}/${analysis.totalFramesSampled} error=${analysis.error}');
    debugPrint('RESULT impactSoundMs=${analysis.impactSoundMs}');
    final keys = analysis.keyFrames;
    if (keys != null) {
      for (final phase in SwingPhase.values) {
        debugPrint('RESULT ${phase.label}: ${analysis.frames[keys[phase]].timeMs}ms');
      }
    }
    for (final m in analysis.metrics) {
      debugPrint('RESULT ${m.name}: ${m.valueText} (target ${m.idealText}) ${m.status.name}');
    }
    debugPrint('RESULT score=${analysis.score}');

    // Leave each view on screen long enough for `adb exec-out screencap`.
    Future<void> hold(String label) async {
      debugPrint('SCREEN $label');
      await tester.runAsync(() => Future.delayed(const Duration(seconds: 12)));
      await tester.pump();
    }

    await tester.pumpWidget(MaterialApp(home: ResultsScreen(analysis: analysis)));
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pump();
    if (keys != null) {
      await tester.tap(find.text('Impact').first);
      await tester.runAsync(() => Future.delayed(const Duration(seconds: 1)));
      await tester.pump();
      await hold('impact');
      await tester.tap(find.text('Top').first);
      await tester.runAsync(() => Future.delayed(const Duration(seconds: 1)));
      await tester.pump();
    }
    await hold('top');
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await hold('scrolled');
    expect(analysis.frames, isNotEmpty);
  });
}
