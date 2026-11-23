import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/native_transport.dart';
import 'package:nexmem_app/transport/transport.dart';

/// 桌面端真实 FFI 联调（P1-09 / P1-10 / P1-20）。
///
/// 需先构建内核动态库并指定路径，例如：
/// `NEXMEM_LIB=D:\wwwroot\nexmem\bin\nexmem.dll flutter test test/native_transport_test.dart`
void main() {
  final String? library = Platform.environment['NEXMEM_LIB'];
  final String? skipReason = library == null
      ? '未设置 NEXMEM_LIB（指向已构建的 c-shared 产物），跳过真实 FFI 联调'
      : null;

  test('FFI 传输：请求往返、事件回传、水位持久化与停止后 NOT_STARTED', () async {
    final Directory dir = Directory.systemTemp.createTempSync('nexmem-ffi-');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on Object {
        // 临时目录清理失败不影响结论。
      }
    });
    final String seqPath = '${dir.path}${Platform.pathSeparator}event_seq';

    final NativeTransport transport = NativeTransport(
      libraryPath: library,
      seqStore: FileEventSeqStore(seqPath),
    );
    addTearDown(transport.close);
    final List<CoreEvent> events = <CoreEvent>[];
    final StreamSubscription<CoreEvent> sub = transport.events.listen(events.add);
    addTearDown(sub.cancel);

    await transport.connect();

    final Map<String, dynamic> info = await transport.call('core.info');
    expect(info['api_version'], isA<String>());

    await expectLater(
      transport.call('no.such.method'),
      throwsA(
        isA<NexmemException>().having((NexmemException e) => e.code, 'code', 'INVALID_ARG'),
      ),
    );

    final Map<String, dynamic> started = await transport.call(
      'core.start',
      params: <String, dynamic>{
        'config': <String, dynamic>{
          'data_dir': dir.path,
          'listen': <String>['/ip4/127.0.0.1/tcp/0'],
        },
      },
      timeout: const Duration(seconds: 60),
    );
    expect(started['state'], isA<String>());
    final Map<String, dynamic> me = await transport.call('account.me');
    final String accountId = me['account_id'] as String;
    expect(accountId, isNotEmpty);
    expect(
      File('${dir.path}${Platform.pathSeparator}nexmem.db').existsSync(),
      isTrue,
    );

    // 内核事件经 NativeCallable.listener 回到 Dart isolate。
    await _until(() => events.any((CoreEvent e) => e.type == 'state.changed'));
    expect(events.first.seq, greaterThan(0));
    expect(transport.lastSeq, greaterThanOrEqualTo(events.first.seq));
    expect(File(seqPath).existsSync(), isTrue, reason: '事件水位应写入文件');

    // 全新客户端不重放历史；已追平后返回空；since=1 时从内核环形缓冲补齐。
    expect(transport.replaySince(0), isEmpty);
    expect(transport.replaySince(transport.lastSeq), isEmpty);
    final List<CoreEvent>? replayed = transport.replaySince(1);
    expect(replayed, isNotNull);
    if (transport.lastSeq > 1) {
      expect(replayed, isNotEmpty);
      expect(replayed!.first.seq, greaterThan(1));
    }

    final Map<String, dynamic> again = await transport.call('account.me');
    expect(again['account_id'], accountId);

    await transport.call('core.stop', timeout: const Duration(seconds: 30));
    await expectLater(
      transport.call('account.me'),
      throwsA(
        isA<NexmemException>().having(
          (NexmemException e) => e.code,
          'code',
          'NOT_STARTED',
        ),
      ),
    );
    final int kernelLast = transport.lastSeq;
    await transport.close();

    // 进程重启：旧水位已失去意义（内核 seq 从 1 重来），不得凭空下发 resync。
    File(seqPath).writeAsStringSync('999');
    final NativeTransport restarted = NativeTransport(
      libraryPath: library,
      seqStore: FileEventSeqStore(seqPath),
    );
    final List<CoreEvent> restartedEvents = <CoreEvent>[];
    final StreamSubscription<CoreEvent> restartedSub = restarted.events.listen(
      restartedEvents.add,
    );
    await restarted.connect();
    expect(restarted.lastSeq, 0);
    expect(
      restartedEvents.where((CoreEvent e) => e.type == 'resync_required'),
      isEmpty,
    );
    await restartedSub.cancel();
    await restarted.close();

    // 同进程热重启：内核仍持有该 seq 空间，按水位重放缺失事件且不重复。
    File(seqPath).writeAsStringSync('1');
    final NativeTransport resumed = NativeTransport(
      libraryPath: library,
      seqStore: FileEventSeqStore(seqPath),
    );
    final List<CoreEvent> resumedEvents = <CoreEvent>[];
    final StreamSubscription<CoreEvent> resumedSub = resumed.events.listen(
      resumedEvents.add,
    );
    await resumed.connect();
    expect(resumed.lastSeq, kernelLast);
    if (kernelLast > 1 && resumedEvents.isNotEmpty) {
      expect(resumedEvents.first.seq, greaterThan(1));
    }
    await resumedSub.cancel();
    await resumed.close();
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _until(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待内核事件超时（${timeout.inSeconds}s）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
