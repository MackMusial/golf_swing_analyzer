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

/// Hosts the "golf_swing_analyzer/frames" channel: exact-frame extraction from a
/// video file, plus an audio "click energy" envelope for finding the strike.
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
          case "audioEnvelope":
            value = try audioEnvelope(
              path,
              startMs: args["startMs"] as? Int ?? 0,
              endMs: args["endMs"] as? Int ?? 0,
              hopMs: args["hopMs"] as? Int ?? 2)
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
    let fps = track.nominalFrameRate
    return [
      "durationMs": Int(CMTimeGetSeconds(asset.duration) * 1000),
      "width": Int(abs(size.width)),
      "height": Int(abs(size.height)),
      "fps": fps > 0 ? Double(fps) : 30.0,
    ]
  }

  /// Click energy of the audio between startMs and endMs: for each hopMs slice,
  /// the mean squared change between consecutive (mono) samples. That
  /// high-passes the sound, so a club striking a ball stands far above wind
  /// and voices. Returns NSNull if the video has no audio track.
  private static func audioEnvelope(
    _ path: String, startMs: Int, endMs: Int, hopMs: Int
  ) throws -> Any {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first else { return NSNull() }

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(output)
    reader.timeRange = CMTimeRange(
      start: CMTime(value: CMTimeValue(startMs), timescale: 1000),
      end: CMTime(value: CMTimeValue(endMs + 200), timescale: 1000))
    guard reader.startReading() else {
      throw reader.error
        ?? NSError(
          domain: "FrameExtractor", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Couldn't read the audio"])
    }

    let hops = max(1, (endMs - startMs) / hopMs)
    var sums = [Double](repeating: 0, count: hops)
    var counts = [Int](repeating: 0, count: hops)
    var prev: Double = 0
    var havePrev = false

    while let buffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(buffer),
        let format = CMSampleBufferGetFormatDescription(buffer),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
      else { continue }
      let channels = max(1, Int(asbd.mChannelsPerFrame))
      let rate = asbd.mSampleRate
      let t0 = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)) * 1000

      let length = CMBlockBufferGetDataLength(block)
      var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
      samples.withUnsafeMutableBytes { raw in
        _ = CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
      }

      let frameCount = samples.count / channels
      for k in 0..<frameCount {
        var s: Double = 0
        for c in 0..<channels { s += Double(samples[k * channels + c]) }
        s /= Double(channels)
        if havePrev {
          let idx = Int((t0 + Double(k) * 1000 / rate - Double(startMs)) / Double(hopMs))
          if idx >= 0 && idx < hops {
            let d = s - prev
            sums[idx] += d * d
            counts[idx] += 1
          }
        }
        prev = s
        havePrev = true
      }
    }
    reader.cancelReading()

    let values = (0..<hops).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
    return [
      "startMs": startMs,
      "hopMs": hopMs,
      "values": FlutterStandardTypedData(float64: values.withUnsafeBufferPointer { Data(buffer: $0) }),
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
