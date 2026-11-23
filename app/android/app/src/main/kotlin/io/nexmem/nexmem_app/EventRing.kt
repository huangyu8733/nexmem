package io.nexmem.nexmem_app

/**
 * 事件环形缓冲（P1-10）。
 *
 * Flutter 热重启只重建 Dart isolate，Android Activity 与进程仍在，
 * 因此把最近 [capacity] 条事件留在原生侧，供新的 isolate 凭 [replaySince]
 * 补齐水位缺口；缺口无法补齐时返回 complete=false，由应用重新同步。
 * 语义与 Go `capi.Emitter`、Dart `EventBuffer` 保持一致。
 */
class EventRing(private val capacity: Int = 512) {

    data class Frame(val seq: Long, val payload: String)

    /** 重放结果；[complete] 为 false 表示请求区间已被淘汰。 */
    data class Replay(
        val complete: Boolean,
        val frames: List<String>,
        val oldestSeq: Long,
        val latestSeq: Long,
    )

    private val items = ArrayDeque<Frame>()

    /** 已记录的最大事件序号。 */
    @Volatile
    var lastSeq: Long = 0L
        private set

    /**
     * 记录一条事件。重复或非法序号（seq <= 0）直接忽略；
     * 超出容量时淘汰最旧事件，绝不阻塞调用方。
     */
    @Synchronized
    fun append(seq: Long, payload: String) {
        if (seq <= 0L || seq <= lastSeq) {
            return
        }
        lastSeq = seq
        if (capacity <= 0) {
            return
        }
        if (items.size >= capacity) {
            items.removeFirst()
        }
        items.addLast(Frame(seq, payload))
    }

    /**
     * 返回 seq 严格大于 [since] 的事件；since 为 0 时不重放历史，
     * 已追平或超前时返回空列表，区间被淘汰时返回 complete=false。
     */
    @Synchronized
    fun replaySince(since: Long): Replay {
        if (since <= 0L) {
            return Replay(true, emptyList(), oldestSeq(), latestSeq())
        }
        if (items.isEmpty()) {
            return Replay(false, emptyList(), 0L, 0L)
        }
        val oldest = items.first().seq
        val latest = items.last().seq
        if (since >= latest) {
            return Replay(true, emptyList(), oldest, latest)
        }
        if (since + 1 < oldest) {
            return Replay(false, emptyList(), oldest, latest)
        }
        val frames = ArrayList<String>(items.size)
        for (frame in items) {
            if (frame.seq > since) {
                frames.add(frame.payload)
            }
        }
        return Replay(true, frames, oldest, latest)
    }

    /** 清空缓冲并重置水位；应用完成全量重新同步后调用。 */
    @Synchronized
    fun reset(lastSeq: Long = 0L) {
        items.clear()
        this.lastSeq = lastSeq
    }

    @Synchronized
    fun oldestSeq(): Long = if (items.isEmpty()) 0L else items.first().seq

    @Synchronized
    fun latestSeq(): Long = if (items.isEmpty()) 0L else items.last().seq
}
