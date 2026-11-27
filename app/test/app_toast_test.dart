// 右上角小提示：显示、定位、关闭与自动收起。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app_toast.dart';
import 'package:nexmem_app/app/theme.dart';

Widget _wrap(AppToastController controller) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(
      body: Stack(
        children: <Widget>[
          AppToastOverlay(controller: controller),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('提示浮层出现在右上角，可手动关闭', (WidgetTester tester) async {
    final AppToastController controller = AppToastController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_wrap(controller));

    controller.show('测试提示');
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('app-toast')), findsOneWidget);
    expect(find.text('测试提示'), findsOneWidget);
    final Positioned positioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('app-toast')),
        matching: find.byType(Positioned),
      ),
    );
    expect(positioned.right, 12);
    expect(positioned.top, 34);

    await tester.tap(find.byKey(const ValueKey<String>('app-toast-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('app-toast')), findsNothing);
  });

  testWidgets('提示超时自动收起', (WidgetTester tester) async {
    final AppToastController controller = AppToastController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_wrap(controller));

    controller.show('稍后消失');
    await tester.pump();
    expect(find.text('稍后消失'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('稍后消失'), findsNothing);
  });
}
