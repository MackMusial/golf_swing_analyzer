# Golf Swing Analyzer

Flutter app (iOS + Android): record or upload a swing video, track the golfer's joints frame by frame, and critique the swing. Everything runs on the phone; nothing is uploaded. Vibe-coded: Claude writes the code, Mack steers.

Original plan doc (Python-based, superseded by this Flutter build): https://claude.ai/artifact/3VfZRMsYMn6XgV438G99C2

## Pipeline
1. **Pick/record**: library videos via `image_picker` (`lib/screens/home_screen.dart`). "Record a swing" opens our own camera screen (`lib/screens/record_screen.dart`, `camera` plugin) that films at the highest frame rate the back camera supports (240/120/60, with audio for the strike sound). At 30fps the clubhead moves 1.2-1.5 m between frames, so no frame shows it on the ball; Mack noticed. The plugin silently accepts any fps, so the native `maxCameraFps` channel method reports the real limit first (Android: AE target fps ranges, usually 30-60, since the plugin can't use the high-speed session; iOS: 1280x720 formats, 120/240 on iPhones; untested, needs a Mac). Results show a note on impact for videos under 100fps. The user picks handedness. The camera angle is detected, not asked (people got it wrong, and it decides which metrics apply).
2. **Frame extraction**: our own platform channel `golf_swing_analyzer/frames` with `probe` and `extractFrames`.
   - Android: `android/app/src/main/kotlin/.../MainActivity.kt` (MediaMetadataRetriever, `OPTION_CLOSEST`).
   - iOS: `FrameExtractor` in `ios/Runner/AppDelegate.swift` (AVAssetImageGenerator, zero tolerance).
   - Don't swap in a thumbnail plugin. They grab keyframes only, which is too coarse for a swing.
3. **Pose**: Google ML Kit (`google_mlkit_pose_detection`) on each frame, 33 landmarks in image pixels (`lib/services/swing_processor.dart`).
   - Videos over 5s get a coarse scan first to find the swing, then a ~30fps pass on that window (max 150 frames).
   - All sample times are snapped to real video frames (`probe` returns `fps`).
3b. **Contact** (`_refineImpact` in `swing_processor.dart`):
   - Native `audioEnvelope` returns click energy (mean squared sample-to-sample change) every 2ms over top→finish. `findStrikeMs` (`lib/analysis/impact_sound.dart`) picks the strike click in the late downswing, nearest the hand estimate, so other golfers' shots are ignored.
   - Then every video frame within ~±150ms of contact is added and pose-tracked. The impact keyframe is the last frame at or before the strike sound.
   - No sound (practice swing, muted, silent track): impact is the middle of the flat bottom of the hand path, plus 35ms because the hands lead the club. Checked frame by frame on 7 real swings: 3 exact, 4 one frame off, no bias (before the 35ms it averaged a frame early). Sound gets the exact frame.
4. **Analysis** (pure Dart, `lib/analysis/swing_analyzer.dart`):
   - `smoothFrames` = `despike` (5-frame median; a joint more than 6% of torso length from it is replaced) followed by a 1-2-1 blend. Despike fixes the arm lines thrashing at the top of the backswing, where the elbows are half hidden.
   - Find address/top/impact/finish from the hand path, searching outward from the fastest hand movement (measured across ±2 frames so one glitch can't win) so it stays within one swing.
     - Address = start of the takeaway: walk back from the fastest backswing moment until the hands are nearly still (12% of that speed, so slow-mo works too), then back through any slow creep while the shoulders turn with the hands. Hands moving with the shoulders still is a forward press or fidget and stops the walk. Golfers settle and waggle for seconds, so "lowest hand point" lands far too early.
     - Finish = first nearly-still frame after the fastest follow-through moment. Golfers hold the finish while the hands keep drifting up, so the highest point is late.
   - `detectCameraView` checks the angle at address (face-on: shoulders wide, ≥0.55 of torso, hands in front of the belt; side: shoulders overlap, ≤0.45, hands out in front of the hips). In-between angles use the closer one, and `SwingAnalysis.notice` says the angle was unclear. Side views from the target side or from behind count as down-the-line.
   - Compute metrics and compare them to ideal ranges (`Metric` in `lib/models/swing_models.dart`). A lead arm under 90° at the top means the arm was hidden and the detector guessed, so that metric is skipped.
5. **Results** (`lib/screens/results_screen.dart`): video with skeleton overlay, keyframe jump chips, score, top-3 fixes, key-position thumbnails, all metrics. Speeds 0.25x–3x from a menu.
   - When paused, it shows the exact analyzed frame so the skeleton lines up.
   - Tapping a key-moment chip selects it; ◀ ▶ move it one analyzed frame (`nudgeKeyFrame`: one video frame near impact) and the metrics recompute. A user-placed impact overrides the strike sound. This is the fallback for silent videos where the hands-based impact is a frame off.
   - While playing, `SwingAnalysis.poseAt` blends between analyzed frames. A Ticker extrapolates the position, because video_player only reports it every 100ms.

## Windows scripts (repo root)
- `Setup.bat` installs everything on a bare PC; `Run.bat` boots the emulator (or uses a plugged-in phone), copies `samples/*.mp4` into its library, then `flutter run --release`; `AddVideo.bat` pushes a picked video into the emulator; `Update.bat` pulls the latest from GitHub (git pull, or ZIP download + robocopy for ZIP installs, tracked in `.installed_version`). Logic lives in `tool/windows/*.ps1`.
- These run on Windows PowerShell 5.1: don't use `$ErrorActionPreference='Stop'` around native commands with redirected stderr (it throws on harmless output). `.gitattributes` keeps `.bat`/`.ps1` CRLF, including in GitHub ZIPs.
- On-device integration tests reinstall the app on the emulator. Ask Mack before running them while the emulator is in use.

## Metrics
- **Both views:** tempo (target 3:1), lead arm at top, head sway and head height.
- **Face-on:** hip sway, estimated shoulder/hip turn (from shoulder/hip width shrink), weight shift at finish.
- **Down-the-line:** spine tilt at address, spine angle lost at impact, early extension, knee flex.
- All values are 2D estimates. Lead side = left arm for right-handed golfers. Distances are normalized by torso length.

## Commands
Flutter SDK lives at `C:\Users\mackm\dev\flutter` (on the user PATH).
- `flutter test`: unit tests for the analyzer.
  - `test/swing_analyzer_test.dart` uses synthetic swings.
  - `test/real_swings_test.dart` replays 13 real swings recorded from the device (`test/fixtures/swings/*.txt`), checks hand-labelled windows for each key moment with and without added jitter, checks camera-angle detection, and that a chip-shot clip is rejected. When a real video goes wrong, add it here first: run it on the device, `sh tool/trace_to_fixture.sh run.log [clip#] > test/fixtures/swings/name.txt`, label it by looking at frames (ffmpeg), then fix the code until everything passes. Don't tune thresholds to one clip.
- `flutter test integration_test/pipeline_test.dart -d emulator-5554 --dart-define=VIDEO_URL=...`: real pipeline on device. Prints RESULT/TRACE lines and holds the results screen for screenshots.
  - Batch mode: `--dart-define=VIDEOS=url1,url2,...` runs many clips in one install (about 2 minutes per clip, versus about 10 for one run each). Lines are prefixed `CLIP n`. Keep `|` out of dart-defines, because flutter.bat treats it as a pipe.
- Test clips (cut from a CC-licensed Wikimedia video) are in `C:\Users\mackm\dev\golf_test_videos`. Serve them with `python -m http.server 8765`, run `adb reverse tcp:8765 tcp:8765`, and use `http://localhost:8765/faceon.mp4` or `dtl.mp4`.
- Release builds have R8 minify turned off in `android/app/build.gradle.kts`. With it on, R8 strips ML Kit's WorkManager/Room classes and the app crashes on launch.
- `faceon_click.mp4` in the test clips folder is the face-on sample plus real driving-range audio (from the CC BY-SA "Golf driving range in kanagawa 2023 June 27" on Wikimedia), placed so a strike lands at true contact (9.133s). It tests the strike-sound path. `samples/sample_down_the_line_with_sound.mp4` (Pexels 14980434) has a real recorded strike at 2.662s.
- Pexels test downloads are in `golf_test_videos\pexels` (`p_<id>` originals, `s_<id>` 720p H.264 copies). HDR originals return 0 frames on the emulator; convert them with the zscale/tonemap ffmpeg chain before use.
- Use H.264 MP4 for emulator tests. The emulator's VP9/WebM decoder only returns keyframes.

## iPhone
Mack's phone is an iPhone. iOS builds need a Mac with Xcode (or a cloud Mac CI such as Codemagic). The iOS minimum is 15.5 (ML Kit requires it). The Podfile and camera/photo permission strings are already set. ML Kit doesn't run on the iOS Simulator on Apple Silicon, so test on the real phone.

## Ideas / next steps
- Save swing history and compare swings over time.
- Use ML Kit's z (depth) for real 3D rotation instead of the width-ratio estimate.
- Club tracking (shaft line) for plane analysis, and drawing the club. Researched: the YOLO11 shaft/head/hands model at github.com/nishsm/golf-club-tracking (AGPL, 40MB, laptop-sized; its training data on Roboflow is CC BY 4.0, so a phone-sized model could be trained). CADDIE (CVPR 2026 workshop) is a lighter 5-keypoint club model, but I couldn't confirm a public release.
- Skeleton quality: interpolate the overlay between analyzed frames, Savitzky-Golay smoothing plus outlier removal, fade low-confidence joints, fix left/right swaps, crop to the golfer before running ML Kit.
- Learn ideal ranges from reference pro swings instead of hard-coded ones.
- Optional LLM-written coaching summary from the metrics (on-device or API).
