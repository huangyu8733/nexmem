// 临时联调辅助脚本：在本机数据目录中创建账号并添加安卓手机为联系人。
// 仅用于本次端到端测试，验证完成后删除。

import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/transport/native_transport.dart';

const String phoneAccount = 'A-KVatZwmnqyZSKKHW0M4mUEfKh0I11rudvqe87tCOY';

void main() {
  test('seed mac identity and contact', () async {
    final NativeTransport transport = NativeTransport(
      libraryPath: '/Users/huangyu/nexmem/bin/libnexmem.dylib',
    );
    await transport.connect();
    final CoreSession session = CoreSession(
      transport,
      startConfig: <String, dynamic>{
        'data_dir': '/tmp/nexmem-e2e/mac-data',
        'display_name': 'Mac 测试机',
        'bootstraps': <String>[
          '/ip4/192.168.0.104/tcp/4001/p2p/12D3KooWCQhnvEZAJS5x6NHAHFuFyWsU5RS7EmUfFib1wKQ283eM',
        ],
        'directory_url': 'http://192.168.0.104:8081',
        'enable_mdns': true,
      },
    );
    final CoreAccount account = await session.bootstrap();
    // ignore: avoid_print
    print('MAC_ACCOUNT=${account.accountId}');
    await session.contacts.add(phoneAccount, alias: '安卓手机');
    final contacts = await session.contacts.list();
    // ignore: avoid_print
    print('CONTACTS=${contacts.map((c) => '${c.id}:${c.name}').join(',')}');
    // 等待目录完成资料发布，便于手机侧解析到本机设备。
    await Future<void>.delayed(const Duration(seconds: 3));
    await transport.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
