import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/analysis/swing_analyzer.dart';
import 'package:golf_swing_analyzer/models/swing_models.dart';
import 'package:golf_swing_analyzer/screens/results_screen.dart';
import 'package:golf_swing_analyzer/services/swing_processor.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Runs the real pipeline (native frame extraction + ML Kit + analyzer) on a
/// freely licensed swing video from Wikimedia Commons (phone-style portrait, slow motion).
/// Override with --dart-define=VIDEO_URL=... and VIEW=dtl to test other clips.
const _videoUrl = String.fromEnvironment('VIDEO_URL',
    defaultValue:
        'https://upload.wikimedia.org/wikipedia/commons/9/9e/Suvichaya_Vinijchaitham_Golf_Swing_Slow_Mo_2026.webm');
const _view = String.fromEnvironment('VIEW', defaultValue: 'faceOn');

/// Batch mode: `--dart-define=VIDEOS=url1~dtl,url2~faceOn,...` analyzes each
/// clip in one app install (much faster than one `flutter test` per clip) and
/// prints `RESULT` lines prefixed with `CLIP n`. No screens are shown.
const _videos = String.fromEnvironment('VIDEOS');

Future<SwingAnalysis> _analyze(WidgetTester tester, String url, String view) async {
  final dir = await getApplicationSupportDirectory();
  final video = File('${dir.path}/test_swing.${url.split('.').last}');
  await tester.runAsync(() async {
    final req = await HttpClient().getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'golf-swing-analyzer-test/1.0');
    final res = await req.close();
    await res.pipe(video.openWrite());
  });
  late SwingAnalysis analysis;
  await tester.runAsync(() async {
    analysis = await SwingProcessor().process(
      video.path,
      SwingSettings(
        view: view == 'dtl' ? CameraView.downTheLine : CameraView.faceOn,
      ),
      onProgress: (p, m) => debugPrint('PROGRESS $m'),
    );
  });
  return analysis;
}

void _printResults(SwingAnalysis analysis, [String prefix = '']) {
  // One line per analyzed frame; tool/trace_to_fixture.sh turns these into
  // test/fixtures/swings files for test/real_swings_test.dart.
  for (final f in analysis.frames) {
    final h = handPos(f), hip = midHip(f);
    String p(PoseLandmarkType t) {
      final o = f.at(t);
      return '${o.dx.round()},${o.dy.round()}';
    }
    debugPrint('${prefix}TRACE ${f.timeMs} hand=${h.dx.round()},${h.dy.round()} hip=${hip.dx.round()},${hip.dy.round()} torso=${torsoLength(f).round()}'
        ' ls=${p(PoseLandmarkType.leftShoulder)} rs=${p(PoseLandmarkType.rightShoulder)}'
        ' le=${p(PoseLandmarkType.leftElbow)} re=${p(PoseLandmarkType.rightElbow)}');
  }
  debugPrint('${prefix}RESULT frames=${analysis.frames.length}/${analysis.totalFramesSampled} error=${analysis.error}');
  debugPrint('${prefix}RESULT view=${analysis.settings.view.label} notice=${analysis.notice}');
  debugPrint('${prefix}RESULT impactSoundMs=${analysis.impactSoundMs}');
  final keys = analysis.keyFrames;
  if (keys != null) {
    for (final phase in SwingPhase.values) {
      debugPrint('${prefix}RESULT ${phase.label}: ${analysis.frames[keys[phase]].timeMs}ms');
    }
  }
  for (final m in analysis.metrics) {
    debugPrint('${prefix}RESULT ${m.name}: ${m.valueText} (target ${m.idealText}) ${m.status.name}');
  }
  debugPrint('${prefix}RESULT score=${analysis.score}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // debugPrint is throttled; with thousands of TRACE lines, whatever is still
  // queued when the test ends is silently lost (the last clip's results).
  debugPrint = debugPrintSynchronously;

  if (_videos.isNotEmpty) {
    testWidgets('analyzes a batch of real swing videos', (tester) async {
      final clips = _videos.split(',');
      for (var i = 0; i < clips.length; i++) {
        final [url, view] = clips[i].split('~');
        debugPrint('CLIP $i $url');
        _printResults(await _analyze(tester, url, view), 'CLIP $i ');
      }
      debugPrint('BATCH DONE ${clips.length} clips');
    }, timeout: const Timeout(Duration(hours: 3)));
    return;
  }

  testWidgets('analyzes a real swing video', (tester) async {
    final analysis = await _analyze(tester, _videoUrl, _view);

    _printResults(analysis);
    final keys = analysis.keyFrames;

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
