// 「文件与传输」：媒体类型识别与传输列表进度状态。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/files/file_hub_page.dart';
import 'package:nexmem_app/features/files/media_viewer.dart';
import 'package:nexmem_app/features/files/transfer_store.dart';
import 'package:nexmem_app/transport/transport.dart';

class _EventTransport implements CoreTransport {
  final StreamController<CoreEvent> controller = StreamController<CoreEvent>.broadcast();

  @override
  Stream<CoreEvent> get events => controller.stream;

  @override
  int lastSeq = 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async =>
      <String, dynamic>{};

  @override
  Future<void> close() async => controller.close();
}

void main() {
  test('媒体类型按扩展名与 mime 正确识别', () {
    expect(mediaKindOf('/tmp/photo.JPG'), MediaKind.image);
    expect(mediaKindOf('/tmp/movie.mp4'), MediaKind.video);
    expect(mediaKindOf('/tmp/song.flac'), MediaKind.audio);
    expect(mediaKindOf('/tmp/notes.txt'), MediaKind.other);
    expect(mediaKindOf('download', mime: 'video/webm'), MediaKind.video);
    expect(mediaKindOf('stream', mime: 'audio/mpeg'), MediaKind.audio);
  });

  test('传输列表由 fs.progress 事件推进并可标记完成', () async {
    final _EventTransport transport = _EventTransport();
    final TransferStore store = TransferStore.instance;
    store.attach(transport);
    addTearDown(store.detach);

    store.start(
      shareId: 'share-a',
      name: '电影合集',
      dest: '/downloads/movies',
      total: 1000,
    );
    expect(store.tasks.single.status, TransferStatus.running);
    expect(store.tasks.single.progress, 0);

    transport.controller.add(CoreEvent(
      seq: 1,
      type: 'fs.progress',
      ts: 0,
      data: <String, dynamic>{
        'share_id': 'share-a',
        'done': 250,
        'total': 1000,
      },
    ));
    await pumpEventQueue();
    expect(store.tasks.single.done, 250);
    expect(store.tasks.single.progress, 0.25);

    store.finish('share-a');
    expect(store.tasks.single.status, TransferStatus.done);
    expect(store.tasks.single.progress, 1.0);

    store.start(shareId: 'share-b', name: '音乐', dest: '/downloads/music');
    store.fail('share-b', '对端离线');
    expect(store.tasks.first.status, TransferStatus.failed);
    expect(store.tasks.first.error, '对端离线');

    store.clearFinished();
    expect(store.tasks.map((TransferTask t) => t.shareId), <String>['share-b']);
  });

  test('传输记录支持按 share 单条移除与全部清空', () async {
    final TransferStore store = TransferStore.instance;
    store.clearAll();
    store.start(shareId: 'r1', name: '报告', dest: '/downloads');
    store.start(shareId: 'r2', name: '图片', dest: '/downloads');
    expect(store.tasks.length, 2);

    store.remove('r1');
    expect(store.tasks.map((TransferTask t) => t.shareId), <String>['r2']);
    store.clearAll();
    expect(store.tasks, isEmpty);
  });

  testWidgets('传输页每条记录与整页记录都有删除入口', (WidgetTester tester) async {
    final _EventTransport transport = _EventTransport();
    final TransferStore store = TransferStore.instance;
    store.attach(transport);
    addTearDown(store.detach);
    store.clearAll();
    store.start(shareId: 't1', name: '电影', dest: '/downloads');
    store.start(shareId: 't2', name: '音乐', dest: '/downloads');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FileHubPage(session: CoreSession(transport))),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '传输'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('transfer-delete-t1')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('transfer-delete-t1')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey<String>('transfer-delete-confirm')));
    await tester.pumpAndSettle();
    expect(store.tasks.map((TransferTask t) => t.shareId), <String>['t2']);

    await tester.tap(find.byKey(const ValueKey<String>('transfer-clear-all')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey<String>('transfer-clear-confirm')));
    await tester.pumpAndSettle();
    expect(store.tasks, isEmpty);
  });
}
