import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/swing_models.dart';
import 'analyzing_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _picker = ImagePicker();
  var _handedness = Handedness.right;
  var _view = CameraView.faceOn;

  Future<void> _getVideo(ImageSource source) async {
    final XFile? video;
    try {
      video = await _picker.pickVideo(
        source: source,
        maxDuration: const Duration(seconds: 15),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Couldn\'t open video: $e')));
      return;
    }
    if (video == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AnalyzingScreen(
        videoPath: video!.path,
        settings: SwingSettings(handedness: _handedness, view: _view),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Row(children: [
              Icon(Icons.sports_golf, size: 36, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Text('Swing Analyzer', style: theme.textTheme.headlineMedium),
            ]),
            const SizedBox(height: 8),
            Text(
              'Film one swing, and get your joints tracked frame by frame plus a critique of what to fix.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 28),
            Text('You swing', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<Handedness>(
              segments: const [
                ButtonSegment(value: Handedness.right, label: Text('Right-handed')),
                ButtonSegment(value: Handedness.left, label: Text('Left-handed')),
              ],
              selected: {_handedness},
              onSelectionChanged: (s) => setState(() => _handedness = s.first),
            ),
            const SizedBox(height: 20),
            Text('Camera angle', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<CameraView>(
              segments: [
                for (final v in CameraView.values)
                  ButtonSegment(value: v, label: Text(v.label)),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _view == CameraView.faceOn
                  ? 'Phone straight in front of you, facing your chest. Best for sway, turn and weight shift.'
                  : 'Phone behind you, looking down your target line. Best for posture and early extension.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: () => _getVideo(ImageSource.camera),
              icon: const Icon(Icons.videocam),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Record a swing'),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _getVideo(ImageSource.gallery),
              icon: const Icon(Icons.video_library),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Upload from library'),
              ),
            ),
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tips for a good read', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    for (final tip in const [
                      'Prop the phone up at about waist height; don\'t hand-hold it.',
                      'Get your whole body in frame, head to feet, with some room above.',
                      'One swing per video, 3–6 seconds long works best.',
                      'Good light and clothes that contrast with the background help tracking.',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('•  $tip'),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
