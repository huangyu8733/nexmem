import Flutter
import UIKit
import UniformTypeIdentifiers

/// Flutter 侧内核插件（P1-08）。
///
/// 通道 `io.nexmem/core` 与 Android 完全一致：`call` 传请求信封、回响应信封，
/// 事件通过 `event` 反向调用推给 Dart；所有 `call` 在串行队列上执行，保证
/// 与桌面 FFI / Web 传输一致的“先请求后响应”时序。
///
/// `pickFile` 是平台文件选择器（P2-08）：选中后复制到缓存目录，回传
/// `name/size/mime/path`，内核按绝对路径直接读取。
final class NexmemPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
    private static let channelName = "io.nexmem/core"

    private let channel: FlutterMethodChannel
    private let worker = DispatchQueue(label: "io.nexmem.core.call", qos: .userInitiated)
    private var pendingPick: FlutterResult?

    private init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: NexmemPlugin.channelName, binaryMessenger: messenger)
        super.init()
        NexmemCore.shared.attach { [weak self] payload in
            self?.channel.invokeMethod("event", arguments: payload)
        }
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = NexmemPlugin(messenger: registrar.messenger())
        registrar.addMethodCallDelegate(plugin, channel: plugin.channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "call":
            let request = arguments(call)["request"] as? String ?? ""
            runAsync(result) { try NexmemCore.shared.call(request) }
        case "replaySince":
            let since = (arguments(call)["since"] as? NSNumber)?.int64Value ?? 0
            result(NexmemCore.shared.replaySince(since))
        case "lastSeq":
            result(NexmemCore.shared.lastSeq())
        case "ackedSeq":
            result(NexmemCore.shared.ackedSeq)
        case "ack":
            let seq = (arguments(call)["seq"] as? NSNumber)?.int64Value ?? 0
            NexmemCore.shared.ack(seq)
            result(nil)
        case "dataDir":
            result(NexmemCore.shared.dataDir)
        case "localIp":
            result(Self.en0IPv4())
        case "lanBroadcastAddr":
            // iOS 禁止向 255.255.255.255 受限广播发送（sendto: no route to host），
            // 必须用 en0 的子网定向广播地址（如 192.168.10.255）。
            result(Self.en0BroadcastIPv4())
        case "pickFile":
            pickFile(result)
        case "startService", "stopService":
            // iOS 没有前台服务，常驻依赖静默推送（P6-02），保持空实现。
            result("")
        case "shutdown":
            runAsync(result) {
                NexmemCore.shared.shutdown()
                return ""
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func arguments(_ call: FlutterMethodCall) -> [String: Any] {
        return (call.arguments as? [String: Any]) ?? [:]
    }

    /// 返回当前 Wi-Fi(en0) 的 IPv4 单播地址。用于注入内核补全宣告地址
    /// （本地网络权限由系统弹窗授权）。
    private static func en0IPv4() -> String? {
        return en0IPv4(wantBroadcast: false)
    }

    /// 返回 en0 的子网定向广播地址（如 192.168.10.255）。iOS 不允许向
    /// 255.255.255.255 受限广播发送（sendto: no route to host），必须注入
    /// 定向广播，否则 LAN Beacon 只收不发。
    private static func en0BroadcastIPv4() -> String? {
        return en0IPv4(wantBroadcast: true)
    }

    private static func en0IPv4(wantBroadcast: Bool) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let iface = String(cString: current.pointee.ifa_name)
            // AF_INET 时 ifa_dstaddr 即广播地址（ifa_broadaddr 与其为 union）。
            let addr = wantBroadcast ? current.pointee.ifa_dstaddr : current.pointee.ifa_addr
            if iface == "en0", let addr = addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ok = getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len),
                    &hostname, socklen_t(hostname.count),
                    nil, 0, NI_NUMERICHOST
                )
                if ok == 0 {
                    return String(cString: hostname)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    private func runAsync(_ result: @escaping FlutterResult, _ block: @escaping () throws -> String) {
        worker.async {
            do {
                let value = try block()
                DispatchQueue.main.async { result(value) }
            } catch {
                DispatchQueue.main.async {
                    result(
                        FlutterError(
                            code: "CORE_ERROR",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }
        }
    }

    // MARK: - 文件选择器（P2-08）

    private func pickFile(_ result: @escaping FlutterResult) {
        if pendingPick != nil {
            result(FlutterError(code: "PICK_BUSY", message: "已有一个文件选择正在进行", details: nil))
            return
        }
        guard let presenter = NexmemPlugin.topViewController() else {
            result(FlutterError(code: "NO_ACTIVITY", message: "当前没有可用的界面", details: nil))
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let result = pendingPick else { return }
        pendingPick = nil
        guard let url = urls.first else {
            result(nil)
            return
        }
        worker.async {
            do {
                let picked = try NexmemPlugin.copyPickedFile(url)
                DispatchQueue.main.async { result(picked) }
            } catch {
                DispatchQueue.main.async {
                    result(
                        FlutterError(
                            code: "PICK_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingPick?(nil)
        pendingPick = nil
    }

    /// 把选择结果复制到 `Caches/nexmem-picked` 并返回 Dart 侧字段。
    private static func copyPickedFile(_ url: URL) throws -> [String: Any] {
        let fm = FileManager.default
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let safe = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cache.appendingPathComponent("nexmem-picked", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let target = dir.appendingPathComponent("\(stamp)-\(safe.isEmpty ? "file" : safe)")
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try fm.copyItem(at: url, to: target)
        let attributes = try? fm.attributesOfItem(atPath: target.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let mime = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType ?? ""
        return [
            "name": name,
            "size": size,
            "mime": mime,
            "path": target.path,
        ]
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
