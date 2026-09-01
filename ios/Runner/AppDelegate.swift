import UIKit
import Flutter
import ARKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as! FlutterViewController

    let methodChannel = FlutterMethodChannel(
      name: "com.noor.slam/control",
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "start":
        ARSlamManager.shared.start()
        result(nil)
      case "stop":
        ARSlamManager.shared.stop()
        result(nil)
      case "export":
        if let path = ARSlamManager.shared.exportPLY() {
          result(path)
        } else {
          result(FlutterError(code: "EXPORT_FAILED", message: "Could not write PLY file", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: "com.noor.slam/frames",
      binaryMessenger: controller.binaryMessenger
    )
    eventChannel.setStreamHandler(ARSlamManager.shared)

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Wraps an ARSession running plain world tracking (visual-inertial SLAM).
/// Streams live pose + point-count to Flutter over an EventChannel, and can
/// export the accumulated sparse point cloud as a .ply file on demand.
///
/// Kept in this same file (rather than its own ARSlamManager.swift) because
/// this project has no Mac/Xcode available to register a new file with the
/// build target — everything compiles through AppDelegate.swift instead.
class ARSlamManager: NSObject, ARSessionDelegate, FlutterStreamHandler {
    static let shared = ARSlamManager()

    let session = ARSession()
    var eventSink: FlutterEventSink?
    var isRunning = false

    // Keyed by ARKit's per-point identifier so repeated observations of the
    // same physical feature overwrite rather than duplicate.
    var mapPoints: [UInt64: SIMD3<Float>] = [:]
    var trajectory: [simd_float4x4] = []

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            eventSink?(FlutterError(code: "UNSUPPORTED",
                                     message: "ARWorldTracking not supported on this device",
                                     details: nil))
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        mapPoints.removeAll()
        trajectory.removeAll()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        session.pause()
        isRunning = false
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }

        trajectory.append(frame.camera.transform)

        if let cloud = frame.rawFeaturePoints {
            for i in 0..<cloud.points.count {
                let id = cloud.identifiers[i]
                mapPoints[id] = cloud.points[i]
            }
        }

        let t = frame.camera.transform.columns.3
        let payload: [String: Any] = [
            "x": t.x,
            "y": t.y,
            "z": t.z,
            "pointCount": mapPoints.count,
            "trackingState": trackingStateString(frame.camera.trackingState)
        ]
        eventSink?(payload)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        eventSink?(FlutterError(code: "SESSION_FAILED", message: error.localizedDescription, details: nil))
    }

    private func trackingStateString(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited-initializing"
            case .excessiveMotion: return "limited-excessiveMotion"
            case .insufficientFeatures: return "limited-insufficientFeatures"
            case .relocalizing: return "limited-relocalizing"
            @unknown default: return "limited-unknown"
            }
        }
    }

    // MARK: - Export

    /// Writes the accumulated point cloud to a PLY file in the app's
    /// Documents directory and returns its path.
    func exportPLY() -> String? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "slam_map_\(Int(Date().timeIntervalSince1970)).ply"
        let fileURL = docs.appendingPathComponent(filename)

        var header = "ply\nformat ascii 1.0\n"
        header += "element vertex \(mapPoints.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "end_header\n"

        var body = ""
        for (_, p) in mapPoints {
            body += "\(p.x) \(p.y) \(p.z)\n"
        }

        do {
            try (header + body).write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL.path
        } catch {
            return nil
        }
    }

    // MARK: - FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}