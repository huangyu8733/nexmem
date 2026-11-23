import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/event_sequencer.dart';
import 'package:nexmem_app/transport/transport.dart';

CoreEvent event(int seq, {String type = 'message.new'}) =>
    CoreEvent(seq: seq, type: type, ts: 0);

void main() {
  test('连续序号正常交付并推进水位', () {
    final seq = EventSequencer();
    expect(seq.accept(event(10)), EventOrder.accept); // 首个事件建立基线
    expect(seq.lastSeq, 10);
    expect(seq.accept(event(11)), EventOrder.accept);
    expect(seq.accept(event(12)), EventOrder.accept);
    expect(seq.lastSeq, 12);
  });

  test('重复或过期序号被丢弃', () {
    final seq = EventSequencer();
    expect(seq.accept(event(3)), EventOrder.accept);
    expect(seq.accept(event(3)), EventOrder.duplicate);
    expect(seq.accept(event(2)), EventOrder.duplicate);
    expect(seq.lastSeq, 3);
  });

  test('序号跳跃判定为缺口并推进水位', () {
    final seq = EventSequencer();
    seq.accept(event(1));
    expect(seq.accept(event(4)), EventOrder.gap);
    expect(seq.lastSeq, 4);
    expect(seq.accept(event(5)), EventOrder.accept);
  });

  test('resync_required 不参与去重也不推进水位', () {
    final seq = EventSequencer();
    seq.accept(event(7));
    expect(seq.accept(event(0, type: 'resync_required')), EventOrder.accept);
    expect(seq.lastSeq, 7);
  });

  test('reset 可清空水位用于全量重新同步', () {
    final seq = EventSequencer();
    seq.accept(event(42));
    seq.reset();
    expect(seq.lastSeq, 0);
    expect(seq.accept(event(1)), EventOrder.accept);
  });
}
