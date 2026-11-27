// 摄像头扫码入口验收：扫描结果回填调用方 + 注入模式下不依赖真实摄像头。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/contacts/qr_camera_scanner.dart';

class _OpenScanner extends StatelessWidget {
  const _OpenScanner(this.onResult);

  final void Function(String? value) onResult;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: () async {
        final String? raw = await showQrCameraScannerWithBuilder(
          context,
          scannerBuilder: (BuildContext ctx, void Function(String raw) detected) {
            return TextButton(
              key: const ValueKey<String>('fake-scan'),
              onPressed: () => detected('nexmem://add/abc'),
              child: const Text('模拟扫描'),
            );
          },
        );
        onResult(raw);
      },
      child: const Text('打开'),
    );
  }
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('扫码页把识别到的文本返回给调用方', (WidgetTester tester) async {
    String? result;
    await tester.pumpWidget(
      _wrap(_OpenScanner((String? value) => result = value)),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('fake-scan')), findsOneWidget);
    expect(find.text('摄像头扫码'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('fake-scan')));
    await tester.pumpAndSettle();
    expect(result, 'nexmem://add/abc');
  });

  testWidgets('扫码页注入模式下不出现手电筒/切换摄像头按钮', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        QrCameraScannerPage(
          scannerBuilder: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('qr-scanner-torch')), findsNothing);
    expect(find.byKey(const ValueKey<String>('qr-scanner-switch-camera')), findsNothing);
  });
}
