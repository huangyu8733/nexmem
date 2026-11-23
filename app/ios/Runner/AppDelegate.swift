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
    // 应用内插件（P1-08）：不走 pub 依赖，直接注册到同一个引擎。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NexmemPlugin") {
      NexmemPlugin.register(with: registrar)
    }
  }
}
