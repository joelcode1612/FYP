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
    let screenChannel = FlutterMethodChannel(
      name: "adaptive360/screen",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    screenChannel.setMethodCallHandler { call, result in
      guard call.method == "setKeepScreenOn" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let enabled = call.arguments as? Bool else {
        result(FlutterError(code: "invalid_argument", message: "Expected a boolean", details: nil))
        return
      }
      UIApplication.shared.isIdleTimerDisabled = enabled
      result(nil)
    }
  }
}
