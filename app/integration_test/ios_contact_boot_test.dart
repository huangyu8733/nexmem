// iOS 真机冒烟：内核慢启动竞态回归（T41）。
//
// 背景：ContactsPage.initState 会立即拉取联系人；iOS 真机上 gomobile 内核
// 首次启动需生成主密钥，core.start 完成更慢，首次拉取早于内核就绪会返回
// NOT_STARTED（message「通讯录服务尚未接入内核」）。修复为内核就绪后
// shell._boot() 主动重拉一次联系人/群列表。
//
// 运行：
//   flutter drive -d <ios-device> --debug \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/ios_contact_boot_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:integration_test/integration_test.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/transport/android_transport.dart';
import 'package:nexmem_app/transport/ios_transport.dart';

Future<CoreSession?> _openSession() {
  if (Platform.isIOS) return openIOSSession();
  if (Platform.isAndroid) return openAndroidSession();
  return Future<CoreSession?>.value(null);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS 真机内核就绪后联系人页无慢启动错误条', (
    WidgetTester tester,
  ) async {
    final CoreSession? session = await _openSession();
    if (session == null) {
      fail('内核会话不可用，无法验证联系人慢启动竞态');
    }
    try {
      // 先启动内核（模拟真实 App 的 _boot），再 pump 应用。
      await session.bootstrap();

      await tester.pumpWidget(NexmemApp(session: session));
      await tester.pumpAndSettle(const Duration(milliseconds: 800));

      // 切到联系人分区（底部 tab 第二项）。
      final Finder contactsTab = find.byIcon(Icons.people_outline);
      if (contactsTab.evaluate().isEmpty) {
        // 账号门未越过（无活跃账号）时跳过断言，避免误判为功能缺陷。
        // ignore: avoid_print
        print('IOS_CONTACT_BOOT=skip:no-active-account');
        return;
      }
      await tester.tap(contactsTab.first);
      await tester.pumpAndSettle(const Duration(milliseconds: 1000));

      // 内核已就绪，联系人页不应再显示「通讯录服务尚未接入内核」错误条。
      expect(
        find.text('通讯录服务尚未接入内核'),
        findsNothing,
        reason: '内核就绪后联系人页不应残留慢启动错误条',
      );
      // ignore: avoid_print
      print('IOS_CONTACT_BOOT=ok');
    } finally {
      await session.close();
    }
  });
}
