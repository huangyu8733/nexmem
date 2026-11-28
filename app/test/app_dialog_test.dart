// 弹窗主题回归：内嵌面板的透明 DialogTheme 不能污染二级弹窗。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/app/app_dialog.dart';
import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/remote/remote_password_dialog.dart';
import 'package:nexmem_app/features/settings/settings_pane.dart';

Widget _hostWithTransparentDialogTheme({
  required ValueChanged<BuildContext> onOpen,
  required ThemeData rootTheme,
}) {
  return MaterialApp(
    theme: rootTheme,
    home: Scaffold(
      body: Theme(
        // 模拟 EmbeddedSettingsPane 栈顶 dialog 的「去弹窗化」主题。
        data: rootTheme.copyWith(
          dialogTheme: const DialogThemeData(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
          ),
        ),
        child: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () => onOpen(context),
              child: const Text('打开弹窗'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('远控密码弹窗在透明内嵌主题下仍使用不透明背景', (
    WidgetTester tester,
  ) async {
    final ThemeData rootTheme = NexmemTheme.light();
    await tester.pumpWidget(
      _hostWithTransparentDialogTheme(
        rootTheme: rootTheme,
        onOpen: (BuildContext context) {
          // 这里的 context 位于透明 DialogTheme 之下。
          showRemotePasswordDialog(
            context: context,
            title: '设置远程控制密码',
            confirmLabel: '保存',
          );
        },
      ),
    );
    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    final Material surface = tester.widget<Material>(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Material),
      ).first,
    );
    expect(surface.color, isNotNull);
    expect(surface.color, isNot(Colors.transparent));
    expect(find.byKey(const ValueKey<String>('remote-password-input')), findsOneWidget);
  });

  testWidgets('showAppDialog 忽略调用点的透明主题，恢复根主题表面色', (
    WidgetTester tester,
  ) async {
    final ThemeData rootTheme = NexmemTheme.light();
    await tester.pumpWidget(
      _hostWithTransparentDialogTheme(
        rootTheme: rootTheme,
        onOpen: (BuildContext context) {
          showAppDialog<void>(
            context: context,
            builder: (BuildContext context) => const AlertDialog(
              title: Text('标题'),
            ),
          );
        },
      ),
    );
    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    final Material surface = tester.widget<Material>(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Material),
      ).first,
    );
    expect(surface.color, isNotNull);
    expect(surface.color, isNot(Colors.transparent));
    expect(surface.color, rootTheme.dialogTheme.backgroundColor);
  });

  testWidgets('showPaneDialog 桌面分支仍保持不透明弹窗', (
    WidgetTester tester,
  ) async {
    final ThemeData rootTheme = NexmemTheme.light();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _hostWithTransparentDialogTheme(
        rootTheme: rootTheme,
        onOpen: (BuildContext context) {
          showPaneDialog<void>(
            context: context,
            builder: (BuildContext context) => const AlertDialog(
              title: Text('面板'),
            ),
          );
        },
      ),
    );
    await tester.tap(find.text('打开弹窗'));
    await tester.pumpAndSettle();

    final Material surface = tester.widget<Material>(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(Material),
      ).first,
    );
    expect(surface.color, isNotNull);
    expect(surface.color, isNot(Colors.transparent));
  });
}
