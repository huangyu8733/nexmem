// 通话通知条：状态栏下方展示，点击展开通话页，来电可直接拒绝。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/call_notice_bar.dart';
import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/rtc/call_service.dart';
import 'package:nexmem_app/l10n/l10n.dart';

Widget _wrap({
  required CallInfo info,
  required VoidCallback onOpen,
  VoidCallback? onReject,
  bool ringing = false,
}) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: supportedLocales,
    localizationsDelegates: <LocalizationsDelegate<dynamic>>[
      const AppLocalizationsDelegate(),
      ...GlobalMaterialLocalizations.delegates,
    ],
    home: Scaffold(
      body: CallNoticeBar(
        info: info,
        peerName: '张三',
        onOpen: onOpen,
        onReject: onReject,
        ringing: ringing,
      ),
    ),
  );
}

void main() {
  testWidgets('来电通知条显示名称与类型，点击打开通话页', (WidgetTester tester) async {
    int opened = 0;
    int rejected = 0;
    await tester.pumpWidget(_wrap(
      info: CallInfo(
        state: CallState.incoming,
        peer: 'peer-1',
        video: true,
        callId: 'call-1',
      ),
      onOpen: () => opened++,
      onReject: () => rejected++,
    ));

    expect(find.byKey(const ValueKey<String>('call-notice-bar')), findsOneWidget);
    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining('视频通话'), findsOneWidget);
    expect(find.textContaining('来电'), findsOneWidget);
    expect(find.text('点击打开通话界面'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('call-notice-bar')));
    await tester.tap(find.byKey(const ValueKey<String>('call-notice-reject')));
    expect(opened, 1);
    expect(rejected, 1);
  });

  testWidgets('通话中通知条不显示拒绝按钮', (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(_wrap(
      info: CallInfo(
        state: CallState.connected,
        peer: 'peer-2',
        video: false,
        callId: 'call-2',
      ),
      onOpen: () => opened++,
      onReject: () => fail('通话中不应有拒绝按钮'),
    ));

    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining('语音通话'), findsOneWidget);
    expect(find.textContaining('通话中'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('call-notice-reject')), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('call-notice-bar')));
    expect(opened, 1);
  });
}
