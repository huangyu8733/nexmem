// P6-08 性能与启动验收（Windows 桌面，profile 模式）。
//
// 运行方式：
//   $env:NEXMEM_LIB="<repo>\\bin\\nexmem.dll"
//   flutter drive --profile -d windows \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/app_performance_test.dart
//
// 指标直接打印 `PERF_*` 行，供 §13 门禁记录引用。
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/features/chat/chat_store.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/transport/native_transport.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final String libraryPath = _resolveLibraryPath();

  testWidgets('冷启动到内核可发消息 < 3s', (WidgetTester tester) async {
    final Directory dataDir = await Directory.systemTemp.createTemp(
      'nexmem-perf-',
    );
    final Stopwatch watch = Stopwatch()..start();
    final NativeTransport transport = NativeTransport(libraryPath: libraryPath);
    try {
      await transport.connect();
      await transport.call(
        'core.start',
        params: <String, dynamic>{
          'config': <String, dynamic>{'data_dir': dataDir.path},
        },
        timeout: const Duration(seconds: 30),
      );
      final int coreReadyMs = watch.elapsedMilliseconds;
      final Map<String, dynamic> account = await transport.call('account.me');
      final int sendableMs = watch.elapsedMilliseconds;
      expect(account['account_id'], isA<String>());
      // ignore: avoid_print
      print('PERF_COLD_START_CORE_MS=$coreReadyMs');
      // ignore: avoid_print
      print('PERF_COLD_START_SENDABLE_MS=$sendableMs');
      expect(
        sendableMs,
        lessThan(3000),
        reason: '冷启动到可发消息应 < 3000ms，实测 $sendableMs ms',
      );
      await transport.call('core.stop');
    } finally {
      await transport.close();
      await dataDir.delete(recursive: true);
    }
  }, skip: libraryPath.isEmpty);

  testWidgets('1000 条消息滚动不掉帧', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 11, 19, 8, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: List<ChatMessage>.generate(
        1000,
        (int i) => ChatMessage(
          id: 'm$i',
          conversationId: 'alice',
          text: '消息 $i',
          sentAt: base.add(Duration(seconds: i)),
          isMine: i.isEven,
          senderName: i.isEven ? '我' : 'Alice',
          status: MessageStatus.sent,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: Scaffold(
          body: ChatPage(
            conversation: const ConversationItem(id: 'alice', title: 'Alice'),
            store: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final List<FrameTiming> frames = <FrameTiming>[];
    void collect(List<FrameTiming> timings) => frames.addAll(timings);
    binding.addTimingsCallback(collect);
    try {
      for (int i = 0; i < 6; i++) {
        await tester.fling(find.byType(ListView), const Offset(0, 600), 2500);
        await tester.pumpAndSettle();
      }
    } finally {
      binding.removeTimingsCallback(collect);
    }

    expect(frames, isNotEmpty, reason: '未采集到帧时间，需以 profile 模式运行');
    final List<double> ui = frames
        .map((FrameTiming t) => t.buildDuration.inMicroseconds / 1000.0)
        .toList();
    final List<double> raster = frames
        .map((FrameTiming t) => t.rasterDuration.inMicroseconds / 1000.0)
        .toList();
    final List<double> total = <double>[
      for (int i = 0; i < frames.length; i++) ui[i] + raster[i],
    ];
    final int jank = total.where((double ms) => ms > 16.67).length;
    // ignore: avoid_print
    print('PERF_SCROLL_FRAMES=${frames.length}');
    // ignore: avoid_print
    print('PERF_SCROLL_P95_UI_MS=${_percentile(ui, 95).toStringAsFixed(2)}');
    // ignore: avoid_print
    print('PERF_SCROLL_P95_RASTER_MS=${_percentile(raster, 95).toStringAsFixed(2)}');
    // ignore: avoid_print
    print('PERF_SCROLL_P95_TOTAL_MS=${_percentile(total, 95).toStringAsFixed(2)}');
    // ignore: avoid_print
    print('PERF_SCROLL_MAX_TOTAL_MS=${total.reduce((double a, double b) => a > b ? a : b).toStringAsFixed(2)}');
    // ignore: avoid_print
    print('PERF_SCROLL_JANK_FRAMES=$jank');
    expect(
      find.byType(MessageBubble).evaluate().length,
      lessThan(80),
      reason: '1000 条消息应只构建可视范围',
    );
    expect(
      _percentile(total, 95),
      lessThan(16.67),
      reason: 'P95 帧耗时应低于 16.67ms（60fps）',
    );
  });
}

String _resolveLibraryPath() {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    return '';
  }
  final String env = Platform.environment['NEXMEM_LIB'] ?? '';
  return env;
}

double _percentile(List<double> values, int percent) {
  if (values.isEmpty) {
    return 0;
  }
  final List<double> sorted = <double>[...values]..sort();
  final int index = ((sorted.length - 1) * percent / 100).round();
  return sorted[index];
}
