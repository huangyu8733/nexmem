import Flutter
import MediaPlayer
import PhotosUI
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
final class NexmemPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate,
    PHPickerViewControllerDelegate, MPMediaPickerControllerDelegate {
    private static let channelName = "io.nexmem/core"

    private let channel: FlutterMethodChannel
    private let worker = DispatchQueue(label: "io.nexmem.core.call", qos: .userInitiated)
    private var pendingPick: FlutterResult?
    private var pendingPHIsVideo = false
    private var pendingPickIsDirectory = false

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
        case "pickImage":
            pickImage(result)
        case "pickMedia":
            pickMedia(result)
        case "pickVideo":
            pickVideo(result)
        case "pickAudio":
            pickAudio(result)
        case "pickDirectory":
            pickDirectory(result)
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
        pendingPickIsDirectory = false
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    /// 选择本地文件夹（聊天发送文件夹 / P2P 发布共用）。
    /// UIDocumentPicker 的 asCopy 会把目录树复制到应用沙盒，仍需再复制到
    /// Caches 固定路径，因为系统临时副本在回调结束后可能失效。
    private func pickDirectory(_ result: @escaping FlutterResult) {
        if pendingPick != nil {
            result(FlutterError(code: "PICK_BUSY", message: "已有一个文件选择正在进行", details: nil))
            return
        }
        guard let presenter = NexmemPlugin.topViewController() else {
            result(FlutterError(code: "NO_ACTIVITY", message: "当前没有可用的界面", details: nil))
            return
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        pendingPickIsDirectory = true
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    /// 打开系统相册（PHPicker，iOS 14+ 无需照片库权限）。
    private func pickImage(_ result: @escaping FlutterResult) {
        if pendingPick != nil {
            result(FlutterError(code: "PICK_BUSY", message: "已有一个文件选择正在进行", details: nil))
            return
        }
        guard let presenter = NexmemPlugin.topViewController() else {
            result(FlutterError(code: "NO_ACTIVITY", message: "当前没有可用的界面", details: nil))
            return
        }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        pendingPHIsVideo = false
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    /// 打开系统视频库（PHPicker 视频），直接进入相册的视频列表。
    private func pickVideo(_ result: @escaping FlutterResult) {
        if pendingPick != nil {
            result(FlutterError(code: "PICK_BUSY", message: "已有一个文件选择正在进行", details: nil))
            return
        }
        guard let presenter = NexmemPlugin.topViewController() else {
            result(FlutterError(code: "NO_ACTIVITY", message: "当前没有可用的界面", details: nil))
            return
        }
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        pendingPHIsVideo = true
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    /// 打开系统音频库（音乐库）；受保护项目无法导出时退回文件选择器。
    private func pickAudio(_ result: @escaping FlutterResult) {
        if pendingPick != nil {
            result(FlutterError(code: "PICK_BUSY", message: "已有一个文件选择正在进行", details: nil))
            return
        }
        guard let presenter = NexmemPlugin.topViewController() else {
            result(FlutterError(code: "NO_ACTIVITY", message: "当前没有可用的界面", details: nil))
            return
        }
        // 音乐库权限被拒绝/受限时直接走文件选择器，避免 present 音乐库时被系统终止。
        let status = MPMediaLibrary.authorizationStatus()
        if status == .denied || status == .restricted {
            pickMedia(result)
            return
        }
        let picker = MPMediaPickerController(mediaTypes: .anyAudio)
        picker.delegate = self
        picker.allowsPickingMultipleItems = false
        picker.prompt = "选择音频"
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    /// 打开系统文件选择器，只列视频与音频。
    /// Photos 框架没有音频资产类型，PHPicker 无法选音频，因此统一用
    /// UIDocumentPicker + UTType.movie/.audio 过滤，视频音频一次可选。
    private func pickMedia(_ result: @escaping FlutterResult) {
        if pendingPick != nil {
            result(FlutterError(code: "PICK_BUSY", message: "已有一个文件选择正在进行", details: nil))
            return
        }
        guard let presenter = NexmemPlugin.topViewController() else {
            result(FlutterError(code: "NO_ACTIVITY", message: "当前没有可用的界面", details: nil))
            return
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.movie, .audio],
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        pendingPickIsDirectory = false
        pendingPick = result
        presenter.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = pendingPick else { return }
        pendingPick = nil
        guard let provider = results.first?.itemProvider else {
            result(nil)
            return
        }
        // 临时文件在 completion 返回后即失效，必须先复制到 Caches 再回调。
        let isVideo = pendingPHIsVideo
        let typeIdentifier = isVideo ? UTType.movie.identifier : UTType.image.identifier
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) {
            [weak self] url, error in
            guard self != nil else { return }
            if let error = error {
                DispatchQueue.main.async {
                    result(
                        FlutterError(
                            code: "PICK_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
                return
            }
            guard let url = url else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            do {
                let picked = try NexmemPlugin.copyPickedImage(
                    url,
                    suggestedName: provider.suggestedName,
                    defaultName: isVideo ? "video.mov" : "image.jpg"
                )
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

    private static func copyPickedImage(
        _ url: URL,
        suggestedName: String?,
        defaultName: String = "image.jpg"
    ) throws -> [String: Any] {
        let fm = FileManager.default
        let rawName = suggestedName ?? url.lastPathComponent
        let name = rawName.isEmpty ? defaultName : rawName
        let safe = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cache.appendingPathComponent("nexmem-picked", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(safe)")
        try fm.copyItem(at: url, to: target)
        let size = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        let ext = (name as NSString).pathExtension
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return [
            "name": name,
            "size": size,
            "mime": mime,
            "path": target.path,
        ]
    }

    func mediaPicker(
        _ mediaPicker: MPMediaPickerController,
        didPickMediaItems mediaItemCollection: MPMediaItemCollection
    ) {
        mediaPicker.dismiss(animated: true)
        guard let result = pendingPick else { return }
        guard let item = mediaItemCollection.items.first else {
            pendingPick = nil
            result(nil)
            return
        }
        guard let assetURL = item.assetURL else {
            // DRM / 云同步项目没有可导出的本地 URL，退回音频文件选择器。
            guard let presenter = NexmemPlugin.topViewController() else {
                pendingPick = nil
                result(FlutterError(
                    code: "PICK_FAILED",
                    message: "该音频无法导出，请从文件中选择",
                    details: nil
                ))
                return
            }
            let fallback = UIDocumentPickerViewController(
                forOpeningContentTypes: [.audio],
                asCopy: true
            )
            fallback.delegate = self
            fallback.allowsMultipleSelection = false
            presenter.present(fallback, animated: true)
            return
        }
        pendingPick = nil
        worker.async {
            do {
                var picked = try NexmemPlugin.copyPickedFile(assetURL)
                if let title = item.title, !title.isEmpty {
                    picked["name"] = title
                }
                DispatchQueue.main.async { result(picked) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "PICK_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
        mediaPicker.dismiss(animated: true)
        pendingPick?(nil)
        pendingPick = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let result = pendingPick else { return }
        pendingPick = nil
        let wantsDirectory = pendingPickIsDirectory
        pendingPickIsDirectory = false
        guard let url = urls.first else {
            result(nil)
            return
        }
        worker.async {
            do {
                if wantsDirectory {
                    let path = try NexmemPlugin.copyPickedDirectory(url)
                    DispatchQueue.main.async { result(path) }
                } else {
                    let picked = try NexmemPlugin.copyPickedFile(url)
                    DispatchQueue.main.async { result(picked) }
                }
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

    /// 把选中的目录树复制到 `Caches/nexmem-picked`，返回内核可读的绝对路径。
    private static func copyPickedDirectory(_ url: URL) throws -> String {
        let fm = FileManager.default
        let name = url.lastPathComponent.isEmpty ? "folder" : url.lastPathComponent
        let safe = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let root = cache.appendingPathComponent("nexmem-picked", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let target = root.appendingPathComponent("\(stamp)-\(safe.isEmpty ? "folder" : safe)", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let sourcePath = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(domain: "NexmemPick", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法读取所选文件夹"
            ])
        }
        for case let child as URL in enumerator {
            let relative = child.path.hasPrefix(sourcePath + "/")
                ? String(child.path.dropFirst(sourcePath.count + 1))
                : child.lastPathComponent
            let destination = target.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: child, to: destination)
            }
        }
        return target.path
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
