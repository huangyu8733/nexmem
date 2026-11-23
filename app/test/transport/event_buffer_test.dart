import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/event_buffer.dart';
import 'package:nexmem_app/transport/event_sequencer.dart';
import 'package:nexmem_app/transport/transport.dart';

CoreEvent event(int seq, [String type = 'message.new']) => CoreEvent(
  seq: seq,
  type: type,
  ts: seq * 1000,
  data: <String, dynamic>{'i': seq},
);

void main() {
  test('连续事件入缓冲且水位推进', () {
    final buffer = EventBuffer();
    expect(buffer.accept(event(1)), EventOrder.accept);
    expect(buffer.accept(event(2)), EventOrder.accept);
    expect(buffer.lastSeq, 2);
    expect(buffer.oldestSeq, 1);
    expect(buffer.latestSeq, 2);
    expect(buffer.length, 2);
  });

  test('重复事件丢弃且不改变缓冲', () {
    final buffer = EventBuffer(lastSeq: 3);
    expect(buffer.accept(event(2)), EventOrder.duplicate);
    expect(buffer.accept(event(3)), EventOrder.duplicate);
    expect(buffer.length, 0);
    expect(buffer.lastSeq, 3);
  });

  test('缺口推进水位并保留事件，供上层重新同步', () {
    final buffer = EventBuffer();
    buffer.accept(event(1));
    expect(buffer.accept(event(4)), EventOrder.gap);
    expect(buffer.lastSeq, 4);
    expect(buffer.latestSeq, 4);
    expect(buffer.replaySince(1)?.map((e) => e.seq).toList(), <int>[4]);
  });

  test('resync_required 不占序号也不入缓冲', () {
    final buffer = EventBuffer();
    buffer.accept(event(1));
    final resync = CoreEvent(seq: 0, type: 'resync_required', ts: 1);
    expect(buffer.accept(resync), EventOrder.accept);
    expect(buffer.lastSeq, 1);
    expect(buffer.length, 1);
  });

  test('容量淘汰最旧事件，缺口时重放返回 null', () {
    final buffer = EventBuffer(capacity: 3);
    for (var i = 1; i <= 5; i++) {
      buffer.accept(event(i));
    }
    expect(buffer.length, 3);
    expect(buffer.oldestSeq, 3);
    expect(buffer.latestSeq, 5);
    expect(buffer.replaySince(1), isNull, reason: 'seq 2 已被淘汰');
    expect(buffer.replaySince(2)?.map((e) => e.seq).toList(), <int>[
      3,
      4,
      5,
    ], reason: '相邻序号可从最旧事件继续重放');
    expect(buffer.replaySince(3)?.map((e) => e.seq).toList(), <int>[4, 5]);
    expect(buffer.replaySince(5), isEmpty);
    expect(buffer.replaySince(9), isEmpty, reason: '水位超前按追平处理');
  });

  test('since 为 0 时不重放历史', () {
    final buffer = EventBuffer();
    buffer.accept(event(1));
    expect(buffer.replaySince(0), isEmpty);
  });

  test('重置后水位与缓冲同时清空', () {
    final buffer = EventBuffer();
    buffer.accept(event(1));
    buffer.reset(lastSeq: 10);
    expect(buffer.lastSeq, 10);
    expect(buffer.length, 0);
    expect(buffer.replaySince(9), isNull, reason: '空缓冲无法确认是否缺事件');
    expect(buffer.accept(event(11)), EventOrder.accept);
  });

  test('MemoryEventSeqStore 读写与清空', () {
    final store = MemoryEventSeqStore();
    expect(store.load(), isNull);
    store.save(7);
    expect(store.load(), 7);
    store.clear();
    expect(store.load(), isNull);
    expect(MemoryEventSeqStore(3).load(), 3);
  });

  test('非 Web 环境不创建浏览器水位存储', () {
    expect(createBrowserEventSeqStore(), isNull);
  });
}
