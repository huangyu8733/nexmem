// 深色外观下 Android 底部系统导航栏跟随主题，消除残留白条。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/system_ui_style.dart';
import 'package:nexmem_app/app/theme.dart';

void main() {
  group('systemUiOverlayStyleFor', () {
    test('深色外观使用深色系统栏与浅色图标', () {
      final SystemUiOverlayStyle style =
          systemUiOverlayStyleFor(Brightness.dark);
      expect(style.systemNavigationBarColor, NexmemColors.darkCard);
      expect(style.systemNavigationBarDividerColor, NexmemColors.darkCard);
      expect(style.statusBarColor, NexmemColors.darkCard);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.systemNavigationBarContrastEnforced, isFalse);
    });

    test('浅色外观使用浅色系统栏与深色图标', () {
      final SystemUiOverlayStyle style =
          systemUiOverlayStyleFor(Brightness.light);
      expect(style.systemNavigationBarColor, NexmemColors.lightCard);
      expect(style.systemNavigationBarDividerColor, NexmemColors.lightCard);
      expect(style.statusBarColor, NexmemColors.lightCard);
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.systemNavigationBarContrastEnforced, isFalse);
    });
  });

  testWidgets('外观切换时同步系统栏，同一亮度不重复设置', (WidgetTester tester) async {
    final List<Brightness> seen = <Brightness>[];

    Widget buildApp(ThemeMode mode) {
      return MaterialApp(
        theme: NexmemTheme.light(),
        darkTheme: NexmemTheme.dark(),
        themeMode: mode,
        home: SystemUiStyleScope(
          onBrightnessChanged: seen.add,
          child: const Scaffold(body: SizedBox.shrink()),
        ),
      );
    }

    await tester.pumpWidget(buildApp(ThemeMode.light));
    await tester.pumpAndSettle();
    expect(seen, <Brightness>[Brightness.light]);

    // 同一亮度的无关重建不应重复写平台通道。
    await tester.pumpWidget(buildApp(ThemeMode.light));
    await tester.pumpAndSettle();
    expect(seen, <Brightness>[Brightness.light]);

    await tester.pumpWidget(buildApp(ThemeMode.dark));
    await tester.pumpAndSettle();
    expect(seen, <Brightness>[Brightness.light, Brightness.dark]);

    await tester.pumpWidget(buildApp(ThemeMode.light));
    await tester.pumpAndSettle();
    expect(seen, <Brightness>[
      Brightness.light,
      Brightness.dark,
      Brightness.light,
    ]);
  });

  testWidgets('跟随系统模式按平台亮度设置系统栏', (WidgetTester tester) async {
    final List<Brightness> seen = <Brightness>[];
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(() {
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });

    await tester.pumpWidget(MaterialApp(
      theme: NexmemTheme.light(),
      darkTheme: NexmemTheme.dark(),
      themeMode: ThemeMode.system,
      home: SystemUiStyleScope(
        onBrightnessChanged: seen.add,
        child: const Scaffold(body: SizedBox.shrink()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(seen, <Brightness>[Brightness.dark]);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(seen, <Brightness>[Brightness.dark, Brightness.light]);
  });

  testWidgets('NexmemApp 挂载系统栏观察器', (WidgetTester tester) async {
    await tester.pumpWidget(const NexmemApp(enableStartupCheck: false));
    await tester.pumpAndSettle();
    expect(find.byType(SystemUiStyleScope), findsOneWidget);
  });
}
