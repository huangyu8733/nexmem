// P6-23：Web 端「仅在线接收」提示（ui-spec.md §5 / §7）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/app/web_notice.dart';
import 'package:nexmem_app/app/web_notice_store.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('说明条展示文案并在点击「知道了」时回调', (WidgetTester tester) async {
    int dismissed = 0;
    await tester.pumpWidget(
      _wrap(WebOnlineNoticeBanner(onDismiss: () => dismissed++)),
    );

    expect(find.byKey(const ValueKey<String>('web-online-notice')), findsOne);
    final Container banner = tester.widget<Container>(
      find.byKey(const ValueKey<String>('web-online-notice')),
    );
    expect(banner.color?.a, 1.0, reason: 'Web 提示条必须是不透明实色');
    expect(find.text('浏览器关闭后不再实时接收消息，离线消息将在下次打开时补齐。'), findsOne);

    await tester.tap(
      find.byKey(const ValueKey<String>('web-online-notice-dismiss')),
    );
    expect(dismissed, 1);
  });

  testWidgets('设置页在 Web 端展示常驻「仅在线接收」说明', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage(webOnlineOnly: true)));

    expect(
      find.byKey(const ValueKey<String>('settings-web-online-only')),
      findsOne,
    );
    expect(find.textContaining('仅在线接收'), findsOne);
  });

  testWidgets('非 Web 端设置页不显示该说明', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));

    expect(
      find.byKey(const ValueKey<String>('settings-web-online-only')),
      findsNothing,
    );
  });

  test('非 Web 占位存储恒为未读且不落盘', () {
    const WebNoticeStore store = WebNoticeStore();
    expect(store.seen, isFalse);
    store.markSeen();
    expect(store.seen, isFalse);
  });
}
