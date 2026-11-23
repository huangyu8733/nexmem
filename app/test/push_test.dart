// C-07 验收：设备推送令牌上报的 Dart 服务契约调用。
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/settings/push.dart';
import 'package:nexmem_app/transport/transport.dart';

void main() {
  test('TransportPushService.register 调用 push.register 并解析 tokens', () async {
    final _RecordingTransport transport = _RecordingTransport(
      response: <String, dynamic>{'registered': true, 'tokens': 2},
    );
    final PushService service = TransportPushService(transport);

    final int tokens = await service.register(
      'device-token-abcdefghijklmnop',
      env: PushEnvironment.sandbox,
    );

    expect(tokens, 2);
    expect(transport.lastMethod, 'push.register');
    expect(transport.lastParams!['token'], 'device-token-abcdefghijklmnop');
    expect(transport.lastParams!['env'], 'sandbox');
  });

  test('TransportPushService.register 默认 production 环境', () async {
    final _RecordingTransport transport = _RecordingTransport(
      response: <String, dynamic>{'registered': true, 'tokens': 1},
    );
    await TransportPushService(transport).register('device-token-abcdefghijklmnop');
    expect(transport.lastParams!['env'], 'production');
  });

  test('TransportPushService.unregister 调用 push.unregister 并解析 removed', () async {
    final _RecordingTransport transport = _RecordingTransport(
      response: <String, dynamic>{'removed': true},
    );
    final bool removed = await TransportPushService(transport).unregister(
      'device-token-abcdefghijklmnop',
    );
    expect(removed, isTrue);
    expect(transport.lastMethod, 'push.unregister');
    expect(transport.lastParams!['token'], 'device-token-abcdefghijklmnop');
  });

  test('UnavailablePushService 明确抛 NOT_STARTED', () async {
    final PushService service = const UnavailablePushService();
    expect(
      () => service.register('device-token-abcdefghijklmnop'),
      throwsA(isA<NexmemException>().having(
        (NexmemException e) => e.code,
        'code',
        'NOT_STARTED',
      )),
    );
  });
}

class _RecordingTransport implements CoreTransport {
  _RecordingTransport({required this.response});

  final Map<String, dynamic> response;
  String? lastMethod;
  Map<String, dynamic>? lastParams;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    lastMethod = method;
    lastParams = params;
    return response;
  }

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}
