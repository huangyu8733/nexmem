// 根浮层回归：移动端聊天页 push 出新路由后，通知/toast/通话页仍需可见可点。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app_overlay.dart';

void main() {
  testWidgets('根浮层盖在 push 出的路由之上，且不挡住空白处的点击', (WidgetTester tester) async {
    final AppOverlayController controller = AppOverlayController();
    addTearDown(controller.dispose);
    final Object owner = Object();
    bool tapped = false;
    bool routeTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext context) => Scaffold(
                      body: Column(
                        children: <Widget>[
                          const Text('chat-route'),
                          TextButton(
                            onPressed: () => routeTapped = true,
                            child: const Text('route-button'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('open-chat'),
              ),
            ),
          ),
        ),
        builder: (BuildContext context, Widget? child) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (child != null) Positioned.fill(child: child),
              Positioned.fill(child: AppOverlayHost(controller: controller)),
            ],
          );
        },
      ),
    );

    controller.setLayers(owner, <WidgetBuilder>[
      (BuildContext context) => Positioned(
        top: 120,
        left: 24,
        child: SizedBox(
          key: const ValueKey<String>('global-notice'),
          height: 48,
          width: 220,
          child: TextButton(
            onPressed: () => tapped = true,
            child: const Text('notice'),
          ),
        ),
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('open-chat'));
    await tester.pumpAndSettle();
    expect(find.text('chat-route'), findsOneWidget);

    // 聊天页已覆盖壳层，但全局提示仍在其上方。
    expect(find.byKey(const ValueKey<String>('global-notice')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('global-notice')));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);

    // 浮层空白区域不吞掉下面路由的点击。
    await tester.tap(find.text('route-button'));
    await tester.pumpAndSettle();
    expect(routeTapped, isTrue);

    controller.release(owner);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('global-notice')), findsNothing);
  });

  testWidgets('旧壳层释放不会清掉新壳层登记的浮层', (WidgetTester tester) async {
    final AppOverlayController controller = AppOverlayController();
    addTearDown(controller.dispose);
    final Object oldOwner = Object();
    final Object newOwner = Object();

    controller.setLayers(oldOwner, <WidgetBuilder>[
      (BuildContext context) => const Positioned(child: Text('old-layer')),
    ]);
    controller.setLayers(newOwner, <WidgetBuilder>[
      (BuildContext context) => const Positioned(child: Text('new-layer')),
    ]);
    controller.release(oldOwner);
    expect(controller.layers, hasLength(1));
    expect(controller.layers.single, isNotNull);

    controller.release(newOwner);
    expect(controller.layers, isEmpty);
  });
}
