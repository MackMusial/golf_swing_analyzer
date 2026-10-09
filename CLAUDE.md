# Golf Swing Analyzer

Flutter app (iOS + Android): record or upload a swing video, track the golfer's joints frame by frame, and critique the swing. Everything runs on the phone; nothing is uploaded. Vibe-coded: Claude writes the code, Mack steers.

Original plan doc (Python-based, superseded by this Flutter build): https://claude.ai/artifact/3VfZRMsYMn6XgV438G99C2

## Pipeline
1. **Pick/record**: `image_picker` (`lib/screens/home_screen.dart`). The user picks handedness and camera view (face-on or down-the-line).
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
   - No sound (practice swing, muted, silent track): impact is the middle of the flat bottom of the hand path. The single lowest frame lands early.
   - Measured on the face-on sample: sound gets the exact contact frame. Hands alone are about 2 frames early.
4. **Analysis** (pure Dart, `lib/analysis/swing_analyzer.dart`):
   - Smooth the landmarks, then find address/top/impact/finish from the hand path, searching outward from the fastest hand movement so it stays within one swing.
   - Compute metrics and compare them to ideal ranges (`Metric` in `lib/models/swing_models.dart`).
5. **Results** (`lib/screens/results_screen.dart`): video with skeleton overlay, keyframe jump chips, score, top-3 fixes, key-position thumbnails, all metrics. When paused, it shows the exact analyzed frame so the skeleton lines up.

## Metrics
- **Both views:** tempo (target 3:1), lead arm at top, head sway and head height.
- **Face-on:** hip sway, estimated shoulder/hip turn (from shoulder/hip width shrink), weight shift at finish.
- **Down-the-line:** spine tilt at address, spine angle lost at impact, early extension, knee flex.
- All values are 2D estimates. Lead side = left arm for right-handed golfers. Distances are normalized by torso length.

## Commands
Flutter SDK lives at `C:\Users\mackm\dev\flutter` (on the user PATH).
- `flutter test`: unit tests for the analyzer, using synthetic swings.
- `flutter test integration_test/pipeline_test.dart -d emulator-5554 --dart-define=VIDEO_URL=... --dart-define=VIEW=dtl|faceOn`: real pipeline on device. Prints RESULT/TRACE lines and holds the results screen for screenshots.
- Test clips (cut from a CC-licensed Wikimedia video) are in `C:\Users\mackm\dev\golf_test_videos`. Serve them with `python -m http.server 8765`, run `adb reverse tcp:8765 tcp:8765`, and use `http://localhost:8765/faceon.mp4` or `dtl.mp4`.
- Release builds have R8 minify turned off in `android/app/build.gradle.kts`. With it on, R8 strips ML Kit's WorkManager/Room classes and the app crashes on launch.
- `faceon_click.mp4` in the test clips folder is the face-on sample plus real driving-range audio (from the CC BY-SA "Golf driving range in kanagawa 2023 June 27" on Wikimedia), placed so a strike lands at true contact (9.133s). It tests the strike-sound path. The other samples have no audio.
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
