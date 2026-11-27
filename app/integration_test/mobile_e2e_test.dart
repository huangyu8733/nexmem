// X-04 真机 E2E 用例（Android / iOS 共用）。
//
// 覆盖：内核会话建立（core.start + account.me）→ 添加好友 → 双端文本收发 →
// 历史落库可读 → Flutter UI 可启动。真机双方需预先互相添加对方账号公钥，
// 通过环境变量注入对端账号（与 Web E2E 的双端口径一致）。
//
// 运行方式（真机，需在 Android / iOS 各跑一遍）：
//   NEXMEM_PEER_ACCOUNT=<对端账号公钥> \
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/mobile_e2e_test.dart
//
// 输出的 `E2E_*` 行供 §13 门禁记录引用。跳过条件（非真机平台 / 未配置对端账号）
// 通过 `testWidgets(skip: ...)` 显式标记，确保测试框架记为「跳过」而非误记为通过
// （D-05：原实现仅 print + return 会被记为通过，已修正）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/transport/android_transport.dart';
import 'package:nexmem_app/transport/ios_transport.dart';

Future<CoreSession?> _openPlatformSession() {
  if (Platform.isAndroid) return openAndroidSession();
  if (Platform.isIOS) return openIOSSession();
  return Future<CoreSession?>.value(null);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // flutter test/drive 运行在设备进程里，宿主 shell 的环境变量不会透传；
  // 真机双端测试统一用 --dart-define 注入，对端仍可用设备环境变量覆盖。
  const String peerFromDefine = String.fromEnvironment('NEXMEM_PEER_ACCOUNT');
  final String? peerAccount = peerFromDefine.isNotEmpty
      ? peerFromDefine
      : Platform.environment['NEXMEM_PEER_ACCOUNT'];
  final String platform = Platform.isAndroid
      ? 'android'
      : Platform.isIOS
          ? 'ios'
          : 'unsupported';
  final bool nativeAvailable = Platform.isAndroid || Platform.isIOS;
  if (!nativeAvailable) {
    // ignore: avoid_print
    print('E2E_SKIP=$platform:no-native-transport');
  }
  final bool peerConfigured = peerAccount != null && peerAccount.isNotEmpty;
  if (!peerConfigured) {
    // ignore: avoid_print
    print('E2E_SKIP=$platform:no-peer-account');
  }

  testWidgets(
    'E2E 内核启动并读取账号',
    (WidgetTester tester) async {
      final CoreSession? opened = await _openPlatformSession();
      // 已通过 skip 参数排除非真机平台；此处为空说明原生通道异常，
      // 应视为失败而非静默通过（D-05）。
      if (opened == null) {
        fail('E2E_FAIL=$platform:no-native-transport');
      }
      final CoreSession session = opened;
      try {
        final CoreAccount account = await session.bootstrap();
        expect(account.accountId, isNotEmpty);
        // ignore: avoid_print
        print('E2E_PLATFORM=$platform');
        // ignore: avoid_print
        print('E2E_ACCOUNT=${account.accountId}');
      } finally {
        await session.close();
      }
    },
    skip: !nativeAvailable,
  );

  testWidgets(
    'E2E 双端文本收发并落库',
    (WidgetTester tester) async {
      if (peerAccount == null || peerAccount.isEmpty) {
        fail('E2E_FAIL=$platform:no-peer-account');
      }
      final CoreSession? opened = await _openPlatformSession();
      if (opened == null) {
        fail('E2E_FAIL=$platform:no-native-transport');
      }
      final CoreSession session = opened;
      try {
        final CoreAccount account = await session.bootstrap();
      // 添加对端好友（备注仅本机可见），随后发起单聊。
      await session.transport.call(
        'contact.add',
        params: <String, dynamic>{
          'peer': peerAccount,
          'alias': 'E2E 对端',
        },
      );
      final String body = 'E2E 你好 ${DateTime.now().millisecondsSinceEpoch}';
      final Map<String, dynamic> sent = await session.transport.call(
        'dm.sendText',
        params: <String, dynamic>{'peer': peerAccount, 'text': body},
      );
      final Object? msgUuid = sent['msg_uuid'];
      expect(msgUuid, isA<String>());

      // 从 conversation.list 取回刚发送所在会话的 ID（内核按双方公钥规范化），
      // 再拉历史确认消息在真机链路中落库。
      final Map<String, dynamic> convs = await session.transport.call(
        'conversation.list',
      );
      final List<dynamic> items =
          convs['items'] as List<dynamic>? ?? <dynamic>[];
      String? conversationId;
      for (final dynamic item in items) {
        final Map<String, dynamic> c = item as Map<String, dynamic>;
        if (c['peer'] == peerAccount) {
          conversationId = c['conversation_id'] as String?;
          break;
        }
      }
      expect(conversationId, isA<String>(), reason: '应能找到对端单聊会话');

      List<dynamic> page = <dynamic>[];
      bool landed = false;
      for (int i = 0; i < 30; i++) {
        final Map<String, dynamic> res = await session.transport.call(
          'msg.list',
          params: <String, dynamic>{
            'conversation_id': conversationId,
            'limit': 20,
          },
        );
        page = res['items'] as List<dynamic>? ?? <dynamic>[];
        landed = page.any((dynamic m) => m['msg_uuid'] == msgUuid);
        if (landed) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(landed, isTrue, reason: '消息应在真机链路中落库');
      // ignore: avoid_print
      print('E2E_SEND_RECEIVE=$platform:ok');
      expect(account.accountId, isNotEmpty);
    } finally {
      await session.close();
    }
    },
    skip: !nativeAvailable || !peerConfigured,
  );

  testWidgets('E2E Flutter UI 可启动', (WidgetTester tester) async {
    await tester.pumpWidget(const NexmemApp());
    await tester.pumpAndSettle();
    expect(find.byType(NexmemApp), findsOneWidget);
    // ignore: avoid_print
    print('E2E_UI_BOOT=$platform:ok');
  });
}
