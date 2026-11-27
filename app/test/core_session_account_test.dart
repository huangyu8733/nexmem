import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/transport/transport.dart';

class _AccountSwitchTransport implements CoreTransport {
  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int lastSeq = 0;

  String dataDir = 'data-a';
  bool started = true;
  bool supportsDataDir = true;
  final List<String> calls = <String>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    calls.add(method);
    switch (method) {
      case 'core.dataDir':
        if (!supportsDataDir) {
          throw const NexmemException('INVALID_ARG', '未知方法');
        }
        if (!started) {
          throw const NexmemException('NOT_STARTED', '内核尚未启动');
        }
        return <String, dynamic>{'data_dir': dataDir};
      case 'core.stop':
        started = false;
        return <String, dynamic>{};
      case 'core.start':
        final Object? dir = params?['config']?['data_dir'];
        dataDir = dir is String && dir.isNotEmpty ? dir : dataDir;
        started = true;
        return <String, dynamic>{'state': 'online'};
      case 'account.me':
        if (!started) {
          throw const NexmemException('NOT_STARTED', '内核尚未启动');
        }
        return <String, dynamic>{
          'account_id': 'account-$dataDir',
          'device_id': 'device-1',
        };
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('currentDataDir 读取内核数据目录，旧内核返回 null', () async {
    final _AccountSwitchTransport transport = _AccountSwitchTransport();
    final CoreSession session = CoreSession(transport);
    expect(await session.currentDataDir(), 'data-a');

    transport.supportsDataDir = false;
    expect(await session.currentDataDir(), isNull);
  });

  test('restartWithConfig 停内核后切换账号并记住新配置', () async {
    final _AccountSwitchTransport transport = _AccountSwitchTransport();
    final CoreSession session = CoreSession(
      transport,
      startConfig: <String, dynamic>{'data_dir': 'data-a'},
    );
    expect((await session.bootstrap()).accountId, 'account-data-a');

    final CoreAccount account = await session.restartWithConfig(
      <String, dynamic>{'data_dir': 'data-b'},
    );
    expect(account.accountId, 'account-data-b');
    expect(session.accountId, 'account-data-b');
    expect(session.activeStartConfig?['data_dir'], 'data-b');
    expect(transport.calls.sublist(1), <String>['core.stop', 'core.start', 'account.me']);

    await session.stop();
    expect(session.account, isNull);
    // bootstrap 使用切换后的配置重连，不会回到旧账号。
    expect((await session.bootstrap()).accountId, 'account-data-b');
  });
}
