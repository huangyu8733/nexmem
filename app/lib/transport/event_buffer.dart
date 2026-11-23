import 'dart:collection';

import 'event_sequencer.dart';
import 'transport.dart';

import 'event_seq_store_stub.dart'
    if (dart.library.js_interop) 'event_seq_store_web.dart'
    as browser;

/// 事件水位持久化接口（P1-10）。
///
/// Web 端页面刷新会销毁整个 Dart 运行时，内存缓冲无法保留，
/// 因此只持久化 `lastSeq`，重连时作为 `since` 交给网关从事件缓冲重放；
/// 移动端/桌面端由原生环形缓冲承担事件本体留存。
abstract class EventSeqStore {
  /// 读取上次消费的水位；没有记录时返回 null。
  int? load();

  /// 保存已消费水位。
  void save(int seq);

  /// 清空水位（例如切换账号或全量重新同步）。
  void clear();
}

/// 进程内水位存储，主要用于测试与无持久化环境的降级。
class MemoryEventSeqStore implements EventSeqStore {
  MemoryEventSeqStore([this._seq]);

  int? _seq;

  @override
  int? load() => _seq;

  @override
  void save(int seq) {
    _seq = seq;
  }

  @override
  void clear() {
    _seq = null;
  }
}

/// 按平台创建浏览器 `localStorage` 水位存储；非 Web 环境返回 null。
EventSeqStore? createBrowserEventSeqStore() =>
    browser.createBrowserEventSeqStore();

/// 事件环形缓冲 + 序号水位判定（P1-10）。
///
/// 与 [EventSequencer] 的分工：Sequencer 只负责去重与缺口判定，本类额外保存
/// 最近 [capacity] 条事件本体，供进程内热重启（Dart isolate 重建）后重放；
/// 缺口或缓冲淘汰时 `replaySince` 返回 null，调用方应触发全量重新同步。
class EventBuffer {
  EventBuffer({this.capacity = 512, int lastSeq = 0})
    : _sequencer = EventSequencer() {
    _sequencer.reset(lastSeq);
  }

  /// 缓冲容量，与网关 `DefaultEventBufferSize` 保持一致。
  final int capacity;

  final EventSequencer _sequencer;
  final ListQueue<CoreEvent> _items = ListQueue<CoreEvent>();

  /// 已消费到的最大序号。
  int get lastSeq => _sequencer.lastSeq;

  /// 缓冲内最旧序号；空缓冲返回 0。
  int get oldestSeq => _items.isEmpty ? 0 : _items.first.seq;

  /// 缓冲内最新序号；空缓冲返回 0。
  int get latestSeq => _items.isEmpty ? 0 : _items.last.seq;

  /// 缓冲内事件条数。
  int get length => _items.length;

  /// 判定一条事件是否交付，并把事件本体写入缓冲。
  ///
  /// `resync_required` 不带序号，仅返回判定结果、不占用缓冲与水位；
  /// 缺口时会推进水位（与 [EventSequencer] 一致），避免后续事件持续判缺口。
  EventOrder accept(CoreEvent event) {
    final order = _sequencer.accept(event);
    if (event.isResync || order == EventOrder.duplicate) {
      return order;
    }
    _append(event);
    return order;
  }

  /// 返回 seq 严格大于 [since] 的事件（升序）；返回 null 表示缺口无法补齐。
  ///
  /// - `since == 0`：全新客户端，不重放历史；
  /// - `since` 已追平或超前：返回空列表；
  /// - 请求区间已被容量淘汰：返回 null，调用方应重新同步。
  List<CoreEvent>? replaySince(int since) {
    if (since == 0) {
      return const <CoreEvent>[];
    }
    if (_items.isEmpty) {
      return null;
    }
    if (since >= latestSeq) {
      return const <CoreEvent>[];
    }
    if (since + 1 < oldestSeq) {
      return null;
    }
    return _items.where((CoreEvent e) => e.seq > since).toList(growable: false);
  }

  /// 重置水位并清空缓冲；应用完成全量重新同步后调用。
  void reset({int lastSeq = 0}) {
    _sequencer.reset(lastSeq);
    _items.clear();
  }

  void _append(CoreEvent event) {
    if (capacity <= 0) {
      return;
    }
    if (_items.length >= capacity) {
      _items.removeFirst();
    }
    _items.addLast(event);
  }
}
