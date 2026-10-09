import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FrameExtractor") {
      FrameExtractor.register(messenger: registrar.messenger())
    }
  }
}

/// Hosts the "golf_swing_analyzer/frames" channel: exact-frame extraction from a video file.
enum FrameExtractor {
  private static var channel: FlutterMethodChannel?
  private static let queue = DispatchQueue(label: "frame-extractor", qos: .userInitiated)

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "golf_swing_analyzer/frames", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "path is required", details: nil))
        return
      }
      queue.async {
        do {
          let value: Any
          switch call.method {
          case "probe":
            value = try probe(path)
          case "extractFrames":
            value = try extractFrames(
              path,
              timesMs: args["timesMs"] as? [Int] ?? [],
              outDir: args["outDir"] as? String ?? NSTemporaryDirectory(),
              maxDimension: args["maxDimension"] as? Int ?? 720)
          default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
            return
          }
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "FRAME_ERROR", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
    channel = ch
  }

  private static func videoTrack(_ asset: AVAsset) throws -> AVAssetTrack {
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw NSError(
        domain: "FrameExtractor", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No video track found"])
    }
    return track
  }

  private static func probe(_ path: String) throws -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let track = try videoTrack(asset)
    let size = track.naturalSize.applying(track.preferredTransform)
    return [
      "durationMs": Int(CMTimeGetSeconds(asset.duration) * 1000),
      "width": Int(abs(size.width)),
      "height": Int(abs(size.height)),
    ]
  }

  private static func extractFrames(
    _ path: String, timesMs: [Int], outDir: String, maxDimension: Int
  ) throws -> [[String: Any]] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    _ = try videoTrack(asset)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true  // portrait phone video comes out upright
    generator.requestedTimeToleranceBefore = .zero  // exact frames, not nearest keyframe
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)

    var frames: [[String: Any]] = []
    for t in timesMs {
      let time = CMTime(value: CMTimeValue(t), timescale: 1000)
      guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil),
        let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
      else { continue }
      let url = URL(fileURLWithPath: outDir).appendingPathComponent("frame_\(t).jpg")
      try data.write(to: url)
      frames.append([
        "path": url.path, "timeMs": t, "width": cgImage.width, "height": cgImage.height,
      ])
    }
    return frames
  }
}
