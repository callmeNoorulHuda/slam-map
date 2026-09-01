import UIKit
import Flutter

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
