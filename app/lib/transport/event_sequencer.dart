import 'transport.dart';

/// 单条事件的接收判定结果。
enum EventOrder {
  /// 序号连续，正常交付。
  accept,

  /// 序号不大于水位，属于重复投递，直接丢弃。
  duplicate,

  /// 序号跳跃，说明中间事件丢失，需要应用重新同步。
  gap,
}

/// 事件去重与缺口检测（方案 §6.7）。
///
/// 水位只在交付事件时推进；`resync_required` 不占用序号，由调用方先行处理。
class EventSequencer {
  int _lastSeq = 0;

  /// 已消费到的最大序号。
  int get lastSeq => _lastSeq;

  /// 重置水位；应用完成全量重新同步后调用。
  void reset([int lastSeq = 0]) {
    _lastSeq = lastSeq;
  }

  /// 判断一条事件是否应交付。缺口时水位仍推进到该事件，
  /// 避免后续事件持续判定为缺口（应用已收到 `resync_required`）。
  EventOrder accept(CoreEvent event) {
    if (event.isResync || event.seq <= 0) {
      // 服务端补偿事件不带序号，不能用来推水位。
      return EventOrder.accept;
    }
    if (event.seq <= _lastSeq) {
      return EventOrder.duplicate;
    }
    if (_lastSeq == 0 || event.seq == _lastSeq + 1) {
      _lastSeq = event.seq;
      return EventOrder.accept;
    }
    _lastSeq = event.seq;
    return EventOrder.gap;
  }
}
