// 聊天页内通知/来电/通话页回归：push 出聊天页后仍能看到根浮层。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/remote/remote_prefs.dart';
import 'package:nexmem_app/features/remote/remote_incoming_dialog.dart';
import 'package:nexmem_app/features/remote/remote_signal.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/features/rtc/call_page.dart';
import 'package:nexmem_app/features/rtc/rtc_signal.dart';
import 'package:nexmem_app/transport/transport.dart';

class _OverlayTransport implements CoreTransport {
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  int lastSeq = 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    switch (method) {
      case 'account.me':
        return <String, dynamic>{
          'account_id': 'me',
          'device_id': 'device',
          'display_name': '我',
        };
      case 'settings.get':
        return <String, dynamic>{
          'key': params?['key'],
          'value': '',
          'found': false,
        };
      case 'core.info':
        return <String, dynamic>{
          'api_version': '1',
          'core_version': 'test',
          'features': <String>[],
        };
      case 'conversation.list':
        return <String, dynamic>{
          'items': <Object?>[
            _conversation('dm:a', '会话甲'),
            _conversation('dm:b', '会话乙'),
          ],
          'has_more': false,
        };
      case 'msg.list':
        return <String, dynamic>{'items': <dynamic>[], 'has_more': false};
      case 'msg.listSince':
        return <String, dynamic>{'items': <dynamic>[]};
      default:
        return <String, dynamic>{};
    }
  }

  void emit(CoreEvent event) {
    lastSeq = event.seq;
    _events.add(event);
  }

  @override
  Future<void> close() async => _events.close();
}

Map<String, dynamic> _conversation(String id, String title) {
  return <String, dynamic>{
    'conversation_id': id,
    'title': title,
    'kind': 'dm',
    'peer': id.replaceFirst('dm:', ''),
    'last_text': '',
    'last_msg_at': 1700000000000,
    'unread': 0,
  };
}

void main() {
  testWidgets('聊天页中收到其它会话消息时应用内提示仍可见', (WidgetTester tester) async {
    final _OverlayTransport transport = _OverlayTransport();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      NexmemApp(session: CoreSession(transport), enableStartupCheck: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('会话甲'), findsOneWidget);
    await tester.tap(find.text('会话甲'));
    await tester.pumpAndSettle();

    transport.emit(
      CoreEvent(
        seq: 2,
        type: 'message.new',
        ts: 1700000001000,
        data: <String, dynamic>{
          'conversation_id': 'dm:b',
          'msg_uuid': 'm2',
          'direction': 'in',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('app-toast')), findsOneWidget);
    expect(find.textContaining('会话乙'), findsWidgets);
  });

  testWidgets('聊天页中来电通知条与点击后的通话页都盖在聊天页之上', (WidgetTester tester) async {
    final _OverlayTransport transport = _OverlayTransport();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      NexmemApp(session: CoreSession(transport), enableStartupCheck: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('会话甲'));
    await tester.pumpAndSettle();

    final String payload = RtcSignal(
      type: RtcSignalType.offer,
      sdp: 'v=0',
      callId: 'test-call',
      video: true,
    ).toPayloadB64();
    transport.emit(
      CoreEvent(
        seq: 3,
        type: 'rtc.signal',
        ts: 1700000002000,
        data: <String, dynamic>{'peer': 'a', 'payload_b64': payload},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('call-notice-bar')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('call-notice-bar')));
    await tester.pumpAndSettle();
    expect(find.byType(CallPage), findsOneWidget);
  });

  testWidgets('聊天页中远控来电通知条可见，点击先展开授权框，条上可直接拒绝',
      (WidgetTester tester) async {
    final _OverlayTransport transport = _OverlayTransport();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // 被控端需已开启远控，否则请求会被直接拒绝。
    RemotePrefs.instance
      ..enabled = true
      ..loaded = true
      ..passwordCredential = 'hash-only';
    await tester.pumpWidget(
      NexmemApp(session: CoreSession(transport), enableStartupCheck: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('会话甲'));
    await tester.pumpAndSettle();

    final String payload = RemoteSignal(
      type: RemoteSignalType.request,
      sid: 'r-e2e',
      name: '张三',
      permissions: RemotePermissions.all,
    ).toPayloadB64();
    transport.emit(
      CoreEvent(
        seq: 9,
        type: 'rtc.signal',
        ts: 1700000003000,
        data: <String, dynamic>{'peer': 'a', 'payload_b64': payload},
      ),
    );
    await tester.pumpAndSettle();

    // 来电先给通知条，不再直接弹出全屏授权框。
    expect(
      find.byKey(const ValueKey<String>('remote-notice-bar')),
      findsOneWidget,
    );
    expect(find.byType(RemoteIncomingDialog), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('remote-notice-bar')));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteIncomingDialog), findsOneWidget);
  });
}
