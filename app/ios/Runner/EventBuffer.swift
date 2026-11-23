import Foundation

/// 事件环形缓冲（P1-10）。
///
/// Flutter 热重启只重建 Dart isolate，iOS 进程仍在，因此把最近
/// `capacity` 条事件留在原生侧，供新的 isolate 凭 `replaySince` 补齐；
/// 缺口无法补齐时 `complete == false`，由应用重新同步。
/// 语义与 Go `capi.Emitter`、Dart `EventBuffer` 保持一致。
final class EventBuffer {
    struct Replay {
        /// 请求区间是否可完整补齐。
        let complete: Bool
        /// seq 严格大于 since 的事件载荷，按 seq 升序。
        let frames: [String]
        let oldestSeq: UInt64
        let latestSeq: UInt64
    }

    private struct Frame {
        let seq: UInt64
        let payload: String
    }

    private let capacity: Int
    private let lock = NSLock()
    private var items: [Frame] = []

    /// 已记录的最大事件序号。
    private(set) var lastSeq: UInt64 = 0

    init(capacity: Int = 512) {
        self.capacity = capacity
    }

    /// 记录一条事件；seq 为 0 或重复序号直接忽略，超出容量淘汰最旧事件。
    func append(seq: UInt64, payload: String) {
        guard seq > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard seq > lastSeq else { return }
        lastSeq = seq
        guard capacity > 0 else { return }
        if items.count >= capacity {
            items.removeFirst()
        }
        items.append(Frame(seq: seq, payload: payload))
    }

    /// 返回 seq 严格大于 since 的事件；since 为 0 不重放历史，
    /// 已追平或超前返回空列表，区间被淘汰时 `complete == false`。
    func replaySince(_ since: UInt64) -> Replay {
        lock.lock()
        defer { lock.unlock() }
        let oldest = items.first?.seq ?? 0
        let latest = items.last?.seq ?? 0
        if since == 0 {
            return Replay(complete: true, frames: [], oldestSeq: oldest, latestSeq: latest)
        }
        if items.isEmpty {
            return Replay(complete: false, frames: [], oldestSeq: 0, latestSeq: 0)
        }
        if since >= latest {
            return Replay(complete: true, frames: [], oldestSeq: oldest, latestSeq: latest)
        }
        if since &+ 1 < oldest {
            return Replay(complete: false, frames: [], oldestSeq: oldest, latestSeq: latest)
        }
        let frames = items.filter { $0.seq > since }.map { $0.payload }
        return Replay(complete: true, frames: frames, oldestSeq: oldest, latestSeq: latest)
    }

    /// 清空缓冲并重置水位；应用完成全量重新同步后调用。
    func reset(lastSeq: UInt64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
        self.lastSeq = lastSeq
    }
}
