// 顶部连接状态：内核 degraded（仅中继可达）应继续展示为在线。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/connection_status.dart';

void main() {
  test('内核状态映射：degraded 视为在线', () {
    expect(linkStatusForCoreState('init'), LinkStatus.connecting);
    expect(linkStatusForCoreState('starting'), LinkStatus.connecting);
    expect(linkStatusForCoreState('online'), LinkStatus.online);
    expect(linkStatusForCoreState('degraded'), LinkStatus.online);
    expect(linkStatusForCoreState('offline'), LinkStatus.offline);
    expect(linkStatusForCoreState('stopped'), LinkStatus.offline);
    expect(linkStatusForCoreState('unknown'), isNull);
  });

  testWidgets('状态条展示映射后的在线文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionStatusBar(
            status: linkStatusForCoreState('degraded')!,
          ),
        ),
      ),
    );
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('经中继'), findsNothing);
  });
}
