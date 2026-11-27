// 启动服务就绪检测门（T43）验收。
//
// 覆盖：进度与提示展示；全部就绪后放行进入主界面；NOT_STARTED 服务阻塞并
// 显示重试/仍要进入；普通异常不阻塞（宽容策略，避免误伤测试替身/解析抖动）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/app/startup_gate.dart';
import 'package:nexmem_app/transport/transport.dart';

class _IdleTransport implements CoreTransport {
  @override Stream<CoreEvent> get events => const Stream.empty();
  @override int lastSeq = 0;
  @override Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async =>
      <String, dynamic>{};
  @override Future<void> close() async {}
}

List<StartupCheckDef> _checks({
  required List<Future<void> Function()> probes,
  List<String>? labels,
}) {
  final List<String> names = labels ??
      List<String>.generate(probes.length, (int i) => '服务$i');
  return <StartupCheckDef>[
    for (int i = 0; i < probes.length; i++)
      StartupCheckDef(label: names[i], probe: probes[i]),
  ];
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required List<StartupCheckDef> checks,
  void Function(int, int, List<StartupCheckResult>)? onReport,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: NexmemApp(
        session: CoreSession(_IdleTransport()),
        startupChecks: checks,
        onStartupReport: onReport,
      ),
    ),
  );
}

void main() {
  testWidgets('进度提示可见，检测完成后进入主界面', (WidgetTester tester) async {
    final Completer<void> hold = Completer<void>();
    final List<int> reports = <int>[];
    await _pumpApp(
      tester,
      checks: _checks(probes: <Future<void> Function()>[
        () async => hold.future, // 第一项挂起，保持检测门可见
        () async {},
      ]),
      onReport: (int done, int total, List<StartupCheckResult> r) =>
          reports.add(done),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('startup-gate-title')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('startup-gate-progress')),
      findsOneWidget,
    );
    expect(find.text('正在检查服务'), findsOneWidget);
    expect(find.text('已完成 0/2'), findsOneWidget);

    hold.complete();
    await tester.pumpAndSettle();

    expect(reports, <int>[1, 2]);
    // 检测门消失，主界面出现。
    expect(find.byKey(const ValueKey<String>('startup-gate')), findsNothing);
    expect(find.text('消息'), findsWidgets);
  });

  testWidgets('NOT_STARTED 服务阻塞并展示重试与仍要进入', (WidgetTester tester) async {
    await _pumpApp(
      tester,
      checks: _checks(probes: <Future<void> Function()>[
        () async => throw const NexmemException('NOT_STARTED', '通讯录服务尚未接入内核'),
        () async {},
      ]),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('startup-gate-error')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('startup-gate-retry')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('startup-gate-skip')),
      findsOneWidget,
    );

    // 点「仍要进入」放行。
    await tester.tap(find.byKey(const ValueKey<String>('startup-gate-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('startup-gate')), findsNothing);
  });

  testWidgets('普通异常不阻塞，仍进入主界面', (WidgetTester tester) async {
    final List<bool> oks = <bool>[];
    await _pumpApp(
      tester,
      checks: _checks(probes: <Future<void> Function()>[
        () async => throw StateError('解析抖动'),
        () async {},
      ]),
      onReport: (int done, int total, List<StartupCheckResult> r) =>
          oks.add(r.last.ok),
    );
    await tester.pumpAndSettle();

    expect(oks, <bool>[true, true]);
    expect(find.byKey(const ValueKey<String>('startup-gate')), findsNothing);
  });
}
