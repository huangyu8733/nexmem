// 「关于 → 开源许可」导航层级回归。
//
// 窄屏下「关于」是 SettingsPanePage（外层一个 AppBar），内部用
// EmbeddedSettingsPane 的独立 Navigator 渲染 _AboutDialog。点「开源许可」
// 若 showLicensePage 用默认 useRootNavigator=false，LicensePage 会被 push
// 进内层导航栈，与外层 AppBar 叠加成两个标题栏。修复为 useRootNavigator=true。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/settings/backup.dart';
import 'package:nexmem_app/features/settings/diagnostics.dart';
import 'package:nexmem_app/features/settings/report.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/settings_pane.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';
import 'package:nexmem_app/features/settings/storage_config.dart';

void main() {
  testWidgets('开源许可 push 到根导航器，不与外层关于标题栏叠加', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final WidgetBuilder aboutBuilder = settingsPaneBuilder(
      label: '关于',
      backup: const UnavailableBackupService(),
      settings: const UnavailableSettingsService(),
      diagnostics: const UnavailableDiagnosticsService(),
      ping: const UnavailablePingService(),
      storage: const UnavailableStorageTestService(),
      themeMode: ThemeMode.system,
      reportSink: const UnavailableReportSink(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: Scaffold(
          body: SettingsPanePage(title: '关于', builder: aboutBuilder),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder license = find.byKey(const ValueKey<String>('about-license'));
    expect(license, findsOneWidget);
    await tester.tap(license);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    // LicensePage 由根导航器全屏呈现：只剩一层标题栏，外层「关于」不可见。
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('关于'), findsNothing);
  });
}
