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

    // Live camera + feature-point overlay, shown as a native view inside Flutter.
    let arViewRegistrar = self.registrar(forPlugin: "ARPreviewViewPlugin")!
    arViewRegistrar.register(ARPreviewFactory(), withId: "ar-preview-view")

    let mapViewRegistrar = self.registrar(forPlugin: "PointCloudViewPlugin")!
    mapViewRegistrar.register(PointCloudViewFactory(), withId: "point-cloud-view")

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
    var meshPoints: [UUID: [SIMD3<Float>]] = [:] // LiDAR mesh vertices
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

        // Enable LiDAR mesh reconstruction if available
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        mapPoints.removeAll()
        meshPoints.removeAll()
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

        // Count total points (sparse + dense mesh vertices if available)
        let totalMeshPoints = meshPoints.values.reduce(0) { $0 + $1.count }

        let payload: [String: Any] = [
            "x": t.x,
            "y": t.y,
            "z": t.z,
            "pointCount": mapPoints.count + totalMeshPoints,
            "trackingState": trackingStateString(frame.camera.trackingState)
        ]
        eventSink?(payload)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateMeshPoints(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateMeshPoints(anchors)
    }

    private func updateMeshPoints(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                let geometry = meshAnchor.geometry
                let vertices = geometry.vertices

                var points: [SIMD3<Float>] = []
                for i in 0..<vertices.count {
                    let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * i))
                    let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee

                    // Transform vertex to world space
                    let vertex4 = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
                    let worldVertex4 = meshAnchor.transform * vertex4
                    points.append(SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z))
                }
                meshPoints[meshAnchor.identifier] = points
            }
        }
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
            case .initializing: return "initializing"
            case .excessiveMotion: return "tooFast"
            case .insufficientFeatures: return "lowFeatures"
            case .relocalizing: return "relocalizing"
            @unknown default: return "limited"
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

        let allSparse = Array(mapPoints.values)
        let allMesh = meshPoints.values.flatMap { $0 }
        let totalCount = allSparse.count + allMesh.count

        var header = "ply\nformat ascii 1.0\n"
        header += "element vertex \(totalCount)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "end_header\n"

        var body = ""
        for p in allSparse {
            body += "\(p.x) \(p.y) \(p.z)\n"
        }
        for p in allMesh {
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

// MARK: - Live AR camera preview (Platform View)

/// Creates the native AR preview view requested from Flutter's UiKitView.
class ARPreviewFactory: NSObject, FlutterPlatformViewFactory {
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return ARPreviewView(frame: frame)
    }
}

/// Wraps an ARSCNView attached to ARSlamManager's already-running session, so
/// it shows the live camera feed plus ARKit's built-in yellow feature-point
/// overlay — purely a visualization layer, it doesn't affect tracking.
class ARPreviewView: NSObject, FlutterPlatformView {
    private let sceneView: ARSCNView

    init(frame: CGRect) {
        sceneView = ARSCNView(frame: frame)
        sceneView.session = ARSlamManager.shared.session
        sceneView.automaticallyUpdatesLighting = true
        sceneView.showsStatistics = false
        sceneView.debugOptions = [.showFeaturePoints]
        super.init()
    }

    func view() -> UIView {
        return sceneView
    }
}

// MARK: - Static point-cloud map viewer (Platform View)

/// Creates a static, orbit-able 3D view of the full accumulated point cloud
/// once scanning has stopped — for actually looking at the map, not just
/// exporting it blind.
class PointCloudViewFactory: NSObject, FlutterPlatformViewFactory {
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return PointCloudView(frame: frame)
    }
}

class PointCloudView: NSObject, FlutterPlatformView {
    private let sceneView: SCNView

    init(frame: CGRect) {
        sceneView = SCNView(frame: frame)
        let scene = SCNScene()
        sceneView.scene = scene
        sceneView.backgroundColor = .black
        sceneView.allowsCameraControl = true   // drag to orbit, pinch to zoom
        sceneView.autoenablesDefaultLighting = true

        let sparsePoints = Array(ARSlamManager.shared.mapPoints.values)
        let meshPoints = ARSlamManager.shared.meshPoints.values.flatMap { $0 }
        let points = sparsePoints + meshPoints

        if !points.isEmpty {
            let pointNode = SCNNode(geometry: PointCloudView.makeGeometry(points: points))
            scene.rootNode.addChildNode(pointNode)

            // Frame the camera around the point cloud's bounding box so the
            // whole scan is visible on first open.
            var minV = points[0]
            var maxV = points[0]
            for p in points {
                minV = SIMD3<Float>(min(minV.x, p.x), min(minV.y, p.y), min(minV.z, p.z))
                maxV = SIMD3<Float>(max(maxV.x, p.x), max(maxV.y, p.y), max(maxV.z, p.z))
            }
            let center = (minV + maxV) / 2
            let extent = maxV - minV
            let radius = max(extent.x, max(extent.y, extent.z))

            let camNode = SCNNode()
            camNode.camera = SCNCamera()
            camNode.position = SCNVector3(center.x, center.y, center.z + radius * 1.5 + 1.0)
            camNode.look(at: SCNVector3(center.x, center.y, center.z))
            scene.rootNode.addChildNode(camNode)
            sceneView.pointOfView = camNode
        }

        super.init()
    }

    /// Builds one SceneKit point-cloud geometry for all points at once,
    /// rather than one node per point (which would be far too slow for
    /// thousands of feature points).
    private static func makeGeometry(points: [SIMD3<Float>]) -> SCNGeometry {
        let vertices: [SCNVector3] = points.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        let indices: [Int32] = Array(0..<Int32(vertices.count))
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: data,
            primitiveType: .point,
            primitiveCount: vertices.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        element.pointSize = 6
        element.minimumPointScreenSpaceRadius = 3
        element.maximumPointScreenSpaceRadius = 6

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemYellow
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }

    func view() -> UIView {
        return sceneView
    }
}