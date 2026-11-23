import Foundation
import Security

/// gomobile 内核单例（P1-08）。
///
/// 负责三件事：
/// 1. 从 Keychain 取出或生成 32 字节主密钥，并在 `core.start` 前注入 Go 侧；
///    Keychain 条目被删除后主密钥无法恢复，对应“删除条目后无法解密”的验收语义；
/// 2. 持有唯一的 `MobileHandle`，把事件按 seq 写入 [EventBuffer] 供热重启重放；
/// 3. 向 Flutter 插件提供线程安全的 call / replay / ack 入口。
final class NexmemCore: NSObject, MobileEventSink {
    static let shared = NexmemCore()

    private let ring = EventBuffer()
    private let lock = NSLock()
    private var handle: MobileHandle?
    private var listener: ((String) -> Void)?
    private var consumedSeq: Int64 = 0

    private let keychainService = "io.nexmem.core"
    private let keychainAccount = "master.key"
    private let masterKeyBytes = 32

    private override init() {
        super.init()
    }

    /// 应用沙盒数据目录，与 Android `filesDir` / 桌面数据目录等价。
    var dataDir: String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.path
    }

    /// 注册事件监听；回调已切回主线程。
    func attach(_ onEvent: @escaping (String) -> Void) {
        lock.lock()
        listener = onEvent
        lock.unlock()
    }

    func detach() {
        lock.lock()
        listener = nil
        lock.unlock()
    }

    /// Dart 侧已消费的事件水位（P1-10）：热重启只重建 isolate，水位留在进程内。
    var ackedSeq: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return consumedSeq
    }

    /// 记录 Dart 已消费的最大事件序号（只增不减）。
    func ack(_ seq: Int64) {
        lock.lock()
        if seq > consumedSeq {
            consumedSeq = seq
        }
        lock.unlock()
    }

    /// 处理一条请求信封；阻塞调用，必须运行在工作线程。
    func call(_ request: String) throws -> String {
        try ensureHandle().call(request)
    }

    /// 原生侧事件水位，内核尚未启动时退回环形缓冲水位。
    func lastSeq() -> Int64 {
        lock.lock()
        let current = handle
        lock.unlock()
        if let current = current {
            return current.lastSeq()
        }
        return Int64(bitPattern: ring.lastSeq)
    }

    /// 热重启后按 seq 补齐事件；返回契约事件 JSON 数组。
    func replaySince(_ since: Int64) -> String {
        let replay = ring.replaySince(UInt64(max(0, since)))
        if replay.complete {
            return "[" + replay.frames.joined(separator: ",") + "]"
        }
        let resync: [String: Any] = [
            "seq": 0,
            "type": "resync_required",
            "data": [
                "reason": "gap",
                "since": since,
                "oldest_seq": replay.oldestSeq,
                "latest_seq": replay.latestSeq,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: [resync]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// 关闭内核；再次调用 [ensureHandle] 会重新创建。
    func shutdown() {
        lock.lock()
        let current = handle
        handle = nil
        consumedSeq = 0
        lock.unlock()
        current?.close()
        ring.reset()
    }

    // MARK: - MobileEventSink

    func onEvent(_ payload: String) {
        var seq: UInt64 = 0
        if let data = payload.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let number = obj["seq"] as? NSNumber,
           number.int64Value > 0 {
            seq = UInt64(number.int64Value)
        }
        ring.append(seq: seq, payload: payload)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let callback = self.listener
            self.lock.unlock()
            callback?(payload)
        }
    }

    // MARK: - 内核句柄与主密钥

    /// 幂等获取内核句柄；首次调用会注入主密钥。
    private func ensureHandle() throws -> MobileHandle {
        lock.lock()
        defer { lock.unlock() }
        if let current = handle {
            return current
        }
        let key = try loadOrCreateMasterKey()
        _ = try MobileSetMasterKey(key)
        let created = try MobileNew(self)
        handle = created
        return created
    }

    /// 读取或创建主密钥：Keychain 条目缺失时生成并写回；
    /// 条目存在但内容非法时报错，调用方必须失败而不是静默重建。
    private func loadOrCreateMasterKey() throws -> Data {
        if let existing = try readMasterKey() {
            return existing
        }
        var bytes = Data(count: masterKeyBytes)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, masterKeyBytes, base)
        }
        guard status == errSecSuccess else {
            throw NexmemCoreError.keychain(status)
        }
        try storeMasterKey(bytes)
        return bytes
    }

    private func readMasterKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              data.count == masterKeyBytes else {
            throw NexmemCoreError.keychain(status)
        }
        return data
    }

    private func storeMasterKey(_ key: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NexmemCoreError.keychain(status)
        }
    }
}

enum NexmemCoreError: Error, LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "Keychain 主密钥不可用（OSStatus \(status)）"
        }
    }
}
