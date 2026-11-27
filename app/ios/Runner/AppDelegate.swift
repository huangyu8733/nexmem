import AVFoundation
import CoreLocation
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var permissionsChannel: FlutterMethodChannel?
  private var pushEventsChannel: FlutterEventChannel?
  private var locationChannel: FlutterMethodChannel?
  private let pushEventsHandler = PushEventsHandler()
  private let locationPlugin = LocationPlugin()

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
    // 系统权限中心：摄像头/麦克风/通知的状态、申请与跳转设置。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NexmemPermissions") {
      let channel = FlutterMethodChannel(
        name: "nexmem/permissions",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handlePermission(call: call, result: result)
      }
      permissionsChannel = channel
      // 推送事件宿主实现尚未接入：注册空流避免 Flutter 侧订阅 EventChannel
      // 时触发 MissingPluginException，从而污染真机启动与集成测试。
      let pushEvents = FlutterEventChannel(
        name: "nexmem/push/events",
        binaryMessenger: registrar.messenger()
      )
      pushEvents.setStreamHandler(pushEventsHandler)
      pushEventsChannel = pushEvents
      // 本机位置：仅由用户主动点击「使用系统定位」触发，不引入额外 pod。
      let location = FlutterMethodChannel(
        name: "nexmem/location",
        binaryMessenger: registrar.messenger()
      )
      location.setMethodCallHandler { [weak self] call, result in
        self?.locationPlugin.handle(call, result: result)
      }
      locationChannel = location
    }
  }

  // MARK: - nexmem/permissions

  private func kind(of call: FlutterMethodCall) -> String {
    guard let args = call.arguments as? [String: Any] else { return "" }
    return args["kind"] as? String ?? ""
  }

  private func handlePermission(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let permissionKind = kind(of: call)
    switch call.method {
    case "status":
      permissionStatus(permissionKind, result: result)
    case "request":
      requestPermission(permissionKind, result: result)
    case "openSettings":
      guard let url = URL(string: UIApplication.openSettingsURLString),
            UIApplication.shared.canOpenURL(url) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in result(opened) }
    default:
      result("unsupported")
    }
  }

  private func wire(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .denied, .restricted: return "permanently_denied"
    default: return "prompt"
    }
  }

  private func permissionStatus(_ permissionKind: String, result: @escaping FlutterResult) {
    switch permissionKind {
    case "camera":
      result(wire(AVCaptureDevice.authorizationStatus(for: .video)))
    case "microphone":
      result(wire(AVCaptureDevice.authorizationStatus(for: .audio)))
    case "notifications":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let value: String
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: value = "granted"
        case .denied: value = "denied"
        default: value = "prompt"
        }
        DispatchQueue.main.async { result(value) }
      }
    default:
      result("unsupported")
    }
  }

  private func requestPermission(_ permissionKind: String, result: @escaping FlutterResult) {
    switch permissionKind {
    case "camera":
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { result(granted ? "granted" : "denied") }
      }
    case "microphone":
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { result(granted ? "granted" : "denied") }
      }
    case "notifications":
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      ) { granted, _ in
        DispatchQueue.main.async { result(granted ? "granted" : "denied") }
      }
    default:
      result("unsupported")
    }
  }
}

/// 系统定位：宿主内置 CoreLocation 实现，只有用户确认后才读取一次位置。
final class LocationPlugin: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var pendingPermissionResult: FlutterResult?
  private var pendingLocationResult: FlutterResult?
  private var timeoutWork: DispatchWorkItem?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isServiceEnabled":
      result(CLLocationManager.locationServicesEnabled())
    case "checkPermission":
      result(wire(authorization()))
    case "requestPermission":
      requestPermission(result)
    case "getCurrentPosition":
      getCurrentPosition(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func authorization() -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
      return manager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
  }

  private func wire(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedWhenInUse, .authorizedAlways: return "granted"
    case .denied, .restricted: return "deniedForever"
    case .notDetermined: return "denied"
    @unknown default: return "unableToDetermine"
    }
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    guard CLLocationManager.locationServicesEnabled() else {
      result("denied")
      return
    }
    let status = authorization()
    if status == .notDetermined {
      pendingPermissionResult = result
      manager.requestWhenInUseAuthorization()
      return
    }
    result(wire(status))
  }

  private func getCurrentPosition(_ result: @escaping FlutterResult) {
    guard CLLocationManager.locationServicesEnabled() else {
      result(FlutterError(code: "SERVICE_DISABLED", message: "定位服务未开启", details: nil))
      return
    }
    let status = authorization()
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      result(FlutterError(code: "PERMISSION_DENIED", message: "定位权限尚未授予", details: nil))
      return
    }
    pendingLocationResult = result
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, let callback = self.pendingLocationResult else { return }
      self.pendingLocationResult = nil
      self.manager.stopUpdatingLocation()
      if let location = self.manager.location {
        callback(self.positionMap(location))
      } else {
        callback(FlutterError(code: "TIMEOUT", message: "获取定位超时", details: nil))
      }
    }
    timeoutWork = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    manager.requestLocation()
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard let result = pendingPermissionResult else { return }
    pendingPermissionResult = nil
    result(wire(authorization()))
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last, let result = pendingLocationResult else { return }
    pendingLocationResult = nil
    timeoutWork?.cancel()
    manager.stopUpdatingLocation()
    result(positionMap(location))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let result = pendingLocationResult else { return }
    pendingLocationResult = nil
    timeoutWork?.cancel()
    result(FlutterError(
      code: "LOCATION_FAILED",
      message: error.localizedDescription,
      details: nil
    ))
  }

  private func positionMap(_ location: CLLocation) -> [String: Double] {
    [
      "latitude": location.coordinate.latitude,
      "longitude": location.coordinate.longitude,
      "accuracy": max(location.horizontalAccuracy, 0),
    ]
  }
}

final class PushEventsHandler: NSObject, FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    nil
  }
}
