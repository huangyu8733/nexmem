// 联系人 → 会话 → 群资料联动验收：右栏内联聊天与点成员 @。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/transport/transport.dart';

class _FlowTransport implements CoreTransport {
  final List<(String, Map<String, dynamic>?)> calls =
      <(String, Map<String, dynamic>?)>[];

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int lastSeq = 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    calls.add((method, params));
    switch (method) {
      case 'account.me':
        return <String, dynamic>{
          'account_id': 'a' * 64,
          'device_id': 'b' * 64,
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
        return <String, dynamic>{'items': <dynamic>[]};
      case 'contact.list':
        return <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'account_pub': 'c' * 64,
              'alias': '牛牛',
              'group_name': '朋友',
            },
          ],
        };
      case 'group.list':
        return <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{
              'group_id': 'g1',
              'title': '天天开心',
              'member_count': 2,
              'role': 'admin',
              'key_version': 1,
              'storage_configured': true,
            },
          ],
        };
      case 'group.members':
        return <String, dynamic>{
          'group_id': 'g1',
          'title': '天天开心',
          'key_version': 1,
          'storage_configured': true,
          'allow_friend_add': true,
          'members': <dynamic>[
            <String, dynamic>{'account': 'c' * 64, 'role': 'admin'},
            <String, dynamic>{'account': 'd' * 64, 'role': 'member'},
          ],
        };
      case 'msg.list':
        return <String, dynamic>{
          'items': <dynamic>[],
          'has_more': false,
        };
      default:
        return <String, dynamic>{};
    }
  }

  @override
  Future<void> close() async {}
}

Future<_FlowTransport> _pumpShell(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final _FlowTransport transport = _FlowTransport();
  await tester.pumpWidget(NexmemApp(session: CoreSession(transport)));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('联系人'));
  await tester.pumpAndSettle();
  return transport;
}

void main() {
  testWidgets('群聊列表点击后右栏直接展示会话、群信息和成员', (
    WidgetTester tester,
  ) async {
    await _pumpShell(tester);

    await tester.tap(find.byKey(const ValueKey<String>('contact-groups-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('group-list-g1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('group-list-g1')));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chat-profile-panel')), findsOneWidget);
    expect(find.text('群聊 · 2 位成员'), findsOneWidget);
    expect(find.text('群成员（2）'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('点击群成员把 @ 插入聊天输入框并记录提及账号', (
    WidgetTester tester,
  ) async {
    await _pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey<String>('contact-groups-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('group-list-g1')));
    await tester.pumpAndSettle();

    final Finder member = find.byKey(
      ValueKey<String>('chat-profile-mention-${'d' * 64}'),
    );
    expect(member, findsOneWidget);
    await tester.tap(member);
    await tester.pumpAndSettle();

    final Finder inputFinder = find.byWidgetPredicate(
      (Widget widget) =>
          widget is TextField && widget.decoration?.hintText == '输入消息',
    );
    expect(inputFinder, findsOneWidget);
    final TextField input = tester.widget<TextField>(inputFinder);
    expect(input.controller!.text, startsWith('@'));
  });

  testWidgets('好友列表点击后右栏直接展示单聊会话', (WidgetTester tester) async {
    await _pumpShell(tester);

    final Finder friend = find.byKey(
      ValueKey<String>('pane-friend-${'c' * 64}'),
    );
    expect(friend, findsOneWidget);
    await tester.tap(friend);
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('牛牛'), findsWidgets);
    expect(find.byKey(const ValueKey<String>('chat-profile-panel')), findsNothing);
  });

  testWidgets('群设置开启后可从成员面板直接发送好友申请', (
    WidgetTester tester,
  ) async {
    final _FlowTransport transport = await _pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey<String>('contact-groups-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('group-list-g1')));
    await tester.pumpAndSettle();

    final Finder addFriend = find.byKey(
      ValueKey<String>("chat-profile-add-friend-${'d' * 64}"),
    );
    expect(addFriend, findsOneWidget);
    await tester.tap(addFriend);
    await tester.pumpAndSettle();

    final List<Map<String, dynamic>?> requests = transport.calls
        .where((call) => call.$1 == 'friend.request.send')
        .map((call) => call.$2)
        .toList();
    expect(requests, isNotEmpty);
    expect(requests.first?['peer'], 'd' * 64);
  });
}
