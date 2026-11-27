// 窄屏下载对话框：确认弹出全屏页并确认后不会破坏 inherited element 生命周期。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/files/file_hub_page.dart';
import 'package:nexmem_app/transport/transport.dart';

class _DownloadTransport implements CoreTransport {
  final StreamController<CoreEvent> eventsController =
      StreamController<CoreEvent>.broadcast();

  @override
  Stream<CoreEvent> get events => eventsController.stream;

  @override
  int lastSeq = 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    switch (method) {
      case 'fs.list':
        return <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'share_id': 's1',
              'name': '远端资料',
              'kind': 'imported',
              'code': 'nexmem://fs/placeholder',
              'file_count': 2,
              'total_size': 36,
              'local': false,
            },
          ],
        };
      case 'fs.download':
        return <String, dynamic>{
          'share_id': params?['share_id'],
          'dest': params?['dest'],
          'kind': 'downloaded',
        };
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<void> close() async => eventsController.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/nexmem-test',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider_android'),
    (MethodCall call) async => '/tmp/nexmem-test',
  );

  testWidgets('窄屏下载对话框确认后页面仍可正常渲染', (WidgetTester tester) async {
    final Size original = tester.view.physicalSize;
    final double originalDpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.physicalSize = original;
      tester.view.devicePixelRatio = originalDpr;
    });

    final _DownloadTransport transport = _DownloadTransport();
    addTearDown(transport.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FileHubPage(session: CoreSession(transport))),
      ),
    );
    await tester.pumpAndSettle();

    final Finder download = find.byKey(const ValueKey<String>('share-download-s1'));
    expect(download, findsOneWidget);
    await tester.tap(download);
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.text('开始下载'), findsOneWidget);

    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('下载完成，本机已自动做种，可继续分享给他人'), findsOneWidget);
  });
}
