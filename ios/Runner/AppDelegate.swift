import Flutter
import UIKit
import MediaRemux

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaChannel: FlutterMethodChannel?
  private let remuxQueue = DispatchQueue(label: "playback-warehouse.remux", qos: .utility)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MediaRemuxBridge") else { return }
    let channel = FlutterMethodChannel(name: "com.example.video_browser/media_utils",
                                       binaryMessenger: registrar.messenger())
    mediaChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "remuxTsToMp4" else { result(FlutterMethodNotImplemented); return }
      guard let args = call.arguments as? [String: String],
            let input = args["inputPath"], let output = args["outputPath"], let self = self else {
        result(FlutterError(code: "invalid_paths", message: "Missing remux paths", details: nil))
        return
      }
      self.remuxQueue.async {
        let success = input.withCString { src in
          output.withCString { dst in vb_remux_ts_to_mp4(src, dst) == 0 }
        }
        DispatchQueue.main.async { result(success) }
      }
    }
  }
}
