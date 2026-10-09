import 'package:flutter/material.dart';

import '../models/swing_models.dart';
import '../services/swing_processor.dart';
import 'results_screen.dart';

class AnalyzingScreen extends StatefulWidget {
  final String videoPath;
  final SwingSettings settings;

  const AnalyzingScreen({
    super.key,
    required this.videoPath,
    required this.settings,
  });

  @override
  State<AnalyzingScreen> createState() => _AnalyzingScreenState();
}

class _AnalyzingScreenState extends State<AnalyzingScreen> {
  double _progress = 0;
  String _message = 'Starting…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final analysis = await SwingProcessor().process(
        widget.videoPath,
        widget.settings,
        onProgress: (p, msg) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _message = msg;
          });
        },
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ResultsScreen(analysis: analysis),
      ));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Analyzing')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: _error != null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 12),
                  Text('Something went wrong', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back'),
                  ),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.sports_golf, size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 24),
                  LinearProgressIndicator(value: _progress == 0 ? null : _progress),
                  const SizedBox(height: 16),
                  Text(_message, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Everything runs on your phone. Nothing is uploaded.',
                    style: theme.textTheme.bodySmall,
                  ),
                ]),
        ),
      ),
    );
  }
}
