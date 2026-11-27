import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/transport.dart';
import 'package:nexmem_app/transport/ws_transport.dart';

/// 真实网关联调用例：先启动 `nexmem-webd`，再以环境变量指向它。
///
/// ```
/// NEXMEM_WEB_TEST_URL=http://127.0.0.1:8082 \
/// NEXMEM_WEB_TEST_TOKEN=<token> flutter test test/transport/ws_live_test.dart
/// ```
void main() {
  final baseUrl = Platform.environment['NEXMEM_WEB_TEST_URL'];
  final token = Platform.environment['NEXMEM_WEB_TEST_TOKEN'];
  final skipReason = baseUrl == null || baseUrl.isEmpty
      ? '未设置 NEXMEM_WEB_TEST_URL，跳过真实网关联调'
      : false;

  test('真实 webd：令牌握手与 core.ping 往返', () async {
    final transport = WsTransport(
      endpoint: Uri.parse('${baseUrl!}/ws'),
      token: token ?? '',
      autoReconnect: false,
    );
    addTearDown(transport.close);
    await transport.connect();
    final pong = await transport.call('core.ping');
    expect(pong['pong'], isTrue);
    expect(pong['server_ts'], isA<num>());
  }, skip: skipReason);

  test('真实 webd：错误令牌被拒绝', () async {
    final transport = WsTransport(
      endpoint: Uri.parse('${baseUrl!}/ws'),
      token: 'wrong-${token ?? ''}',
      autoReconnect: false,
    );
    addTearDown(transport.close);
    await expectLater(
      transport.connect(),
      throwsA(
        isA<NexmemException>().having((e) => e.code, 'code', 'UNAUTHORIZED'),
      ),
    );
  }, skip: skipReason);
}
