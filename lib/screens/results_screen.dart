import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../models/swing_models.dart';
import '../widgets/skeleton_painter.dart';

class ResultsScreen extends StatefulWidget {
  final SwingAnalysis analysis;

  const ResultsScreen({super.key, required this.analysis});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen>
    with SingleTickerProviderStateMixin {
  late final VideoPlayerController _video;
  late final Ticker _ticker;
  bool _ready = false;
  bool _showSkeleton = true;
  double _speed = 0.5;

  // The player only reports its position every 100ms. To move the skeleton
  // smoothly, remember the last report and run our own clock from there.
  Duration _lastPosition = Duration.zero;
  final _sinceLastPosition = Stopwatch();

  SwingAnalysis get a => widget.analysis;

  @override
  void initState() {
    super.initState();
    _video = VideoPlayerController.file(File(a.videoPath))
      ..setLooping(true)
      ..addListener(_onVideoChanged);
    _video.initialize().then((_) {
      if (!mounted) return;
      _video.setPlaybackSpeed(_speed);
      setState(() => _ready = true);
    });
    _ticker = createTicker((_) => setState(() {}));
  }

  void _onVideoChanged() {
    // Repaint every screen frame only while playing; idle otherwise.
    final playing = _video.value.isPlaying;
    if (playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
    if (_video.value.position != _lastPosition) {
      _lastPosition = _video.value.position;
      _sinceLastPosition
        ..reset()
        ..start();
    }
    setState(() {});
  }

  /// Best estimate of the frame on screen right now.
  int get _livePositionMs {
    final reported = _video.value.position.inMilliseconds;
    if (!_video.value.isPlaying) return reported;
    final ahead = (_sinceLastPosition.elapsedMilliseconds * _speed).round();
    // Don't run more than one report interval ahead if reports stall.
    return (_lastPosition.inMilliseconds + ahead.clamp(0, (150 * _speed).round()))
        .clamp(0, _video.value.duration.inMilliseconds);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _video.dispose();
    super.dispose();
  }

  void _seekToPhase(SwingPhase phase) {
    final keys = a.keyFrames;
    if (keys == null) return;
    _video.pause();
    _video.seekTo(Duration(milliseconds: a.frames[keys[phase]].timeMs));
  }

  static const _speeds = [0.25, 0.5, 1.0, 2.0, 3.0];

  void _setSpeed(double speed) {
    _video.setPlaybackSpeed(speed);
    setState(() => _speed = speed);
  }

  static String _speedLabel(double s) =>
      '${s == s.roundToDouble() ? s.toInt() : s}x';

  double get _aspect {
    if (a.frames.isNotEmpty) return a.frames.first.width / a.frames.first.height;
    return _ready ? _video.value.aspectRatio : 9 / 16;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keys = a.keyFrames;
    final position = _video.value.position.inMilliseconds;

    return Scaffold(
      appBar: AppBar(title: const Text('Your swing')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _player(context, position),
          _controls(theme, position),
          if (keys != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final phase in SwingPhase.values)
                    ActionChip(
                      label: Text(phase.label),
                      onPressed: () => _seekToPhase(phase),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          if (a.error != null) _errorCard(theme) else ...[
            if (a.notice != null) _noticeCard(theme),
            _scoreCard(theme),
            _issues(theme),
            _keyframeGallery(theme),
            _allMetrics(theme),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'Tracked a body in ${a.frames.length} of ${a.totalFramesSampled} frames. '
              '${a.impactSoundMs != null ? 'Impact was found from the sound of the strike. ' : 'No strike sound was heard, so impact is estimated from your hands. '}'
              'Measurements are 2D estimates from one camera angle (${a.settings.view.label}), so treat them as a guide, not gospel.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _player(BuildContext context, int positionMs) {
    final maxHeight = MediaQuery.of(context).size.height * 0.55;
    final playing = _video.value.isPlaying;
    final still = a.frameNear(positionMs);
    // While paused, show the exact analyzed frame so the skeleton lines up
    // perfectly (players don't always repaint after a seek while paused).
    // While playing, blend between analyzed frames so the skeleton glides.
    final showStill = still != null && _ready && !playing;
    final frame = playing ? a.poseAt(_livePositionMs) : still;
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: AspectRatio(
        aspectRatio: _aspect,
        child: GestureDetector(
          onTap: () => _video.value.isPlaying ? _video.pause() : _video.play(),
          child: Stack(fit: StackFit.expand, children: [
            if (_ready) VideoPlayer(_video) else const Center(child: CircularProgressIndicator()),
            if (showStill)
              Image.file(File(still.imagePath), fit: BoxFit.fill, gaplessPlayback: true),
            if (_showSkeleton)
              CustomPaint(
                painter: SkeletonPainter(
                  frame,
                  leadIsLeft: a.settings.leadIsLeft,
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _controls(ThemeData theme, int positionMs) {
    final duration = _video.value.duration.inMilliseconds;
    return Row(children: [
      IconButton(
        icon: Icon(_video.value.isPlaying ? Icons.pause : Icons.play_arrow),
        onPressed: _ready
            ? () => _video.value.isPlaying ? _video.pause() : _video.play()
            : null,
      ),
      Expanded(
        child: Slider(
          value: duration == 0 ? 0 : positionMs.clamp(0, duration).toDouble(),
          max: duration == 0 ? 1 : duration.toDouble(),
          onChanged: _ready
              ? (v) {
                  _video.pause();
                  _video.seekTo(Duration(milliseconds: v.round()));
                }
              : null,
        ),
      ),
      PopupMenuButton<double>(
        tooltip: 'Playback speed',
        initialValue: _speed,
        onSelected: _setSpeed,
        itemBuilder: (_) => [
          for (final s in _speeds)
            PopupMenuItem(value: s, child: Text(_speedLabel(s))),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_speedLabel(_speed),
                style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
            Icon(Icons.arrow_drop_down, color: theme.colorScheme.primary),
          ]),
        ),
      ),
      IconButton(
        tooltip: 'Show joints',
        icon: Icon(_showSkeleton ? Icons.accessibility_new : Icons.accessibility_new_outlined,
            color: _showSkeleton ? theme.colorScheme.primary : null),
        onPressed: () => setState(() => _showSkeleton = !_showSkeleton),
      ),
    ]);
  }

  Widget _errorCard(ThemeData theme) => Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(Icons.info_outline, color: theme.colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(a.error!)),
          ]),
        ),
      );

  Widget _noticeCard(ThemeData theme) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(Icons.videocam_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(a.notice!)),
          ]),
        ),
      );

  Widget _scoreCard(ThemeData theme) {
    final score = a.score;
    final color = score >= 80
        ? Colors.green
        : score >= 55
            ? Colors.orange
            : Colors.red;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: score / 100,
                strokeWidth: 6,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
              Text('$score', style: theme.textTheme.titleLarge),
            ]),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Swing score', style: theme.textTheme.titleMedium),
              Text(
                a.issues.isEmpty
                    ? 'Everything we measured is in a good range. Nice swing!'
                    : '${a.issues.length} of ${a.metrics.length} measurements need work.',
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _issues(ThemeData theme) {
    final issues = a.issues.take(3).toList();
    if (issues.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text('What to work on', style: theme.textTheme.titleLarge),
      ),
      for (final (i, m) in issues.indexed)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: InkWell(
            onTap: () => _seekToPhase(m.phase),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: _statusColor(m.status),
                    child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(m.name, style: theme.textTheme.titleMedium)),
                  Text(m.phase.label, style: theme.textTheme.labelMedium),
                ]),
                const SizedBox(height: 8),
                Text(m.tip ?? ''),
                const SizedBox(height: 6),
                Text('You: ${m.valueText}   ·   Target: ${m.idealText}',
                    style: theme.textTheme.bodySmall),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _keyframeGallery(ThemeData theme) {
    final keys = a.keyFrames;
    if (keys == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text('Key positions', style: theme.textTheme.titleLarge),
      ),
      SizedBox(
        height: 220,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (final phase in SwingPhase.values)
              _keyframeTile(theme, phase, a.frames[keys[phase]]),
          ],
        ),
      ),
    ]);
  }

  Widget _keyframeTile(ThemeData theme, SwingPhase phase, PoseFrame f) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: f.width / f.height,
                child: Stack(fit: StackFit.expand, children: [
                  Image.file(File(f.imagePath), fit: BoxFit.fill),
                  CustomPaint(painter: SkeletonPainter(f, leadIsLeft: a.settings.leadIsLeft)),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('${phase.label} · ${(f.timeMs / 1000).toStringAsFixed(2)}s',
              style: theme.textTheme.labelMedium),
        ]),
      );

  Widget _allMetrics(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text('All measurements', style: theme.textTheme.titleLarge),
          ),
          for (final m in a.metrics)
            ListTile(
              leading: Icon(
                m.status == MetricStatus.good ? Icons.check_circle : Icons.error,
                color: _statusColor(m.status),
              ),
              title: Text(m.name),
              subtitle: Text('${m.description}\nTarget: ${m.idealText}'),
              isThreeLine: true,
              trailing: Text(m.valueText, style: theme.textTheme.titleMedium),
              onTap: () => _seekToPhase(m.phase),
            ),
        ],
      );

  Color _statusColor(MetricStatus s) => switch (s) {
        MetricStatus.good => Colors.green,
        MetricStatus.minor => Colors.orange,
        MetricStatus.fault => Colors.red,
      };
}
