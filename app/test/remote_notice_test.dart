// 远控通知条：状态栏下方展示，来电可直接拒绝，点击展开授权框。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/remote_notice_bar.dart';
import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/l10n/l10n.dart';

Widget _wrap({
  required RemoteInfo info,
  required VoidCallback onOpen,
  VoidCallback? onReject,
  VoidCallback? onPause,
  VoidCallback? onResume,
  VoidCallback? onStop,
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
      body: RemoteNoticeBar(
        info: info,
        peerName: '张三',
        onOpen: onOpen,
        onReject: onReject,
        onPause: onPause,
        onResume: onResume,
        onStop: onStop,
        ringing: false,
      ),
    ),
  );
}

RemoteInfo _info(RemoteState state, {RemoteRole role = RemoteRole.host}) =>
    RemoteInfo(
      sid: 'sid-1',
      peer: 'peer-1',
      peerName: '张三',
      role: role,
      state: state,
      requested: RemotePermissions.all,
    );

void main() {
  testWidgets('来电通知条显示名称与来电态，可点击展开并直接拒绝',
      (WidgetTester tester) async {
    int opened = 0;
    int rejected = 0;
    await tester.pumpWidget(_wrap(
      info: _info(RemoteState.incoming),
      onOpen: () => opened++,
      onReject: () => rejected++,
    ));

    expect(find.byKey(const ValueKey<String>('remote-notice-bar')),
        findsOneWidget);
    final Material bar = tester.widget<Material>(
      find.byKey(const ValueKey<String>('remote-notice-bar')),
    );
    expect(bar.color?.a, 1.0, reason: '远控通知条必须是不透明实色');
    expect(find.textContaining('张三'), findsOneWidget);
    expect(find.textContaining('远程控制'), findsWidgets);
    expect(find.text('点击打开远程控制授权界面'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('remote-notice-bar')));
    await tester.tap(find.byKey(const ValueKey<String>('remote-notice-reject')));
    expect(opened, 1);
    expect(rejected, 1);
  });

  testWidgets('被控进行中通知条不显示拒绝，提供暂停与断开',
      (WidgetTester tester) async {
    int opened = 0;
    int paused = 0;
    int stopped = 0;
    await tester.pumpWidget(_wrap(
      info: _info(RemoteState.active),
      onOpen: () => opened++,
      onReject: () => fail('进行中不应有拒绝按钮'),
      onPause: () => paused++,
      onStop: () => stopped++,
    ));

    expect(find.textContaining('远程控制中'), findsOneWidget);
    expect(find.text('点击管理远程控制'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-notice-reject')),
        findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('remote-notice-pause')));
    await tester.tap(find.byKey(const ValueKey<String>('remote-notice-stop')));
    await tester.tap(find.byKey(const ValueKey<String>('remote-notice-bar')));
    expect(paused, 1);
    expect(stopped, 1);
    expect(opened, 1);
  });

  testWidgets('暂停态通知条显示继续而非暂停', (WidgetTester tester) async {
    int resumed = 0;
    await tester.pumpWidget(_wrap(
      info: _info(RemoteState.paused),
      onOpen: () {},
      onPause: () => fail('暂停态不应再触发暂停'),
      onResume: () => resumed++,
    ));

    expect(find.textContaining('已暂停'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-notice-pause')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('remote-notice-pause')));
    expect(resumed, 1);
  });
}
