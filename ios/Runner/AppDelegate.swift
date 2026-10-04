import Flutter
import UIKit
import MediaRemux
import AVKit

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
      if call.method == "openDownloadedVideo" || call.method == "exportDownloadedVideo" {
        guard let self = self, let args = call.arguments as? [String: String],
              let path = args["path"], FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(code: "file_missing", message: "视频文件不存在", details: nil))
          return
        }
        self.presentDownloadedVideo(path: path, export: call.method == "exportDownloadedVideo", result: result)
        return
      }
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

  private func presentDownloadedVideo(path: String, export: Bool, result: @escaping FlutterResult) {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap { $0.windows }
    guard var presenter = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "no_window", message: "请返回下载页后重试", details: nil))
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let url = URL(fileURLWithPath: path)
    if export {
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      // Export to Files or another app. Photo-library access is not requested.
      sheet.excludedActivityTypes = [.saveToCameraRoll]
      sheet.popoverPresentationController?.sourceView = presenter.view
      sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY, width: 1, height: 1)
      presenter.present(sheet, animated: true) { result(nil) }
    } else {
      let player = AVPlayer(url: url)
      let view = AVPlayerViewController()
      view.player = player
      presenter.present(view, animated: true) {
        player.play()
        result(nil)
      }
    }
  }

}
