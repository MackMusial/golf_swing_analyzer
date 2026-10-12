import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/swing_models.dart';
import 'analyzing_screen.dart';

/// Records a swing at the highest frame rate the phone allows.
///
/// At 30fps the clubhead moves 1.2-1.5 m between frames, so no frame shows
/// it on the ball. At 240fps it moves about 20 cm. iPhones offer 120/240fps
/// through the camera plugin; most Android phones top out at 60fps there.
class RecordScreen extends StatefulWidget {
  final SwingSettings settings;

  const RecordScreen({super.key, required this.settings});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen>
    with WidgetsBindingObserver {
  /// Fastest first. Only rates the camera reports supporting are tried,
  /// because the plugin accepts any rate silently and then records at its
  /// default. Null = the camera's default (usually 30fps).
  static const _frameRates = <int?>[240, 120, 60, null];
  static const _channel = MethodChannel('golf_swing_analyzer/frames');
  static const _maxLength = Duration(seconds: 15);

  CameraController? _camera;
  int? _fps;
  String? _error;
  bool _recording = false;
  Timer? _autoStop;
  final _elapsed = Stopwatch();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (e) {
      setState(() => _error = 'Couldn\'t open the camera: ${e.description}');
      return;
    }
    if (cameras.isEmpty) {
      setState(() => _error = 'This phone has no camera the app can use.');
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    int? maxFps;
    try {
      maxFps = await _channel.invokeMethod<int>('maxCameraFps');
    } on PlatformException {
      maxFps = null;
    }
    for (final fps in _frameRates) {
      if (fps != null && (maxFps == null || fps > maxFps)) continue;
      final camera = CameraController(
        back,
        ResolutionPreset.high,
        fps: fps,
        // The sound of the strike pins impact to the exact frame.
        enableAudio: true,
      );
      try {
        await camera.initialize();
        await camera.prepareForVideoRecording();
      } on CameraException catch (e) {
        await camera.dispose();
        if (e.code == 'CameraAccessDenied' ||
            e.code == 'CameraAccessDeniedWithoutPrompt' ||
            e.code == 'AudioAccessDenied' ||
            e.code == 'AudioAccessDeniedWithoutPrompt') {
          setState(() => _error =
              'The app needs camera and microphone access to record. Turn it on in Settings.');
          return;
        }
        continue; // This frame rate isn't supported; try the next one.
      }
      if (!mounted) {
        await camera.dispose();
        return;
      }
      setState(() {
        _camera = camera;
        _fps = fps;
      });
      return;
    }
    setState(() => _error = 'Couldn\'t start the camera.');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera when the app goes to the background.
    if (state == AppLifecycleState.inactive && _camera != null) {
      if (_recording) _stop(analyze: false);
      _camera!.dispose();
      setState(() => _camera = null);
    } else if (state == AppLifecycleState.resumed &&
        _camera == null &&
        _error == null) {
      _open();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoStop?.cancel();
    _tick?.cancel();
    _camera?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final camera = _camera;
    if (camera == null || _recording) return;
    await camera.startVideoRecording();
    _elapsed
      ..reset()
      ..start();
    _tick = Timer.periodic(
        const Duration(milliseconds: 200), (_) => setState(() {}));
    _autoStop = Timer(_maxLength, () => _stop());
    setState(() => _recording = true);
  }

  Future<void> _stop({bool analyze = true}) async {
    final camera = _camera;
    if (camera == null || !_recording) return;
    _autoStop?.cancel();
    _tick?.cancel();
    _elapsed.stop();
    setState(() => _recording = false);
    final file = await camera.stopVideoRecording();
    if (!analyze || !mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => AnalyzingScreen(
        videoPath: file.path,
        settings: widget.settings,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Record a swing'),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white)),
              ),
            )
          : camera == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(child: Center(child: CameraPreview(camera))),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        _fps != null && _fps! >= 120
                            ? 'Slow motion: $_fps fps, so you\'ll see the club hit the ball.'
                            : _fps == 60
                                ? '60 fps. This phone can\'t film faster here, so contact may fall between frames.'
                                : 'Standard speed. This phone can\'t film slow motion here, so contact may fall between frames.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white70),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 24, top: 8),
                      child: Column(
                        children: [
                          Text(
                            _recording
                                ? '${(_elapsed.elapsedMilliseconds / 1000).toStringAsFixed(1)}s'
                                : 'Hit a real ball with the sound on for the most exact impact.',
                            style: const TextStyle(color: Colors.white),
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: _recording ? _stop : _start,
                            child: Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 4),
                              ),
                              child: Center(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: _recording ? 30 : 58,
                                  height: _recording ? 30 : 58,
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(
                                        _recording ? 6 : 29),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
