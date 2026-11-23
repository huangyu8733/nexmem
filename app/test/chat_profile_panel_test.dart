// P6-22 验收：桌面 / Web 右侧可折叠资料面板（ui-spec.md §1 三级导航）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chat/chat_profile_panel.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/group/group_service.dart';
import 'package:nexmem_app/features/group/group_storage.dart';
import 'package:nexmem_app/transport/transport.dart';

String _hex(String ch) => List<String>.filled(64, ch).join();

const ConversationItem _groupConversation = ConversationItem(
  id: 'group:g1',
  title: '项目群',
  isGroup: true,
);

final ConversationItem _directConversation = ConversationItem(
  id: 'dm-x',
  title: 'Alice',
  peer: _hex('c'),
  presence: PresenceStatus.online,
);

class _FakeGroups extends UnavailableGroupService {
  _FakeGroups(this.info);

  final GroupInfo info;
  int calls = 0;

  @override
  Future<GroupInfo> members(String groupId) async {
    calls++;
    return info;
  }
}

class _FailingGroups extends UnavailableGroupService {
  @override
  Future<GroupInfo> members(String groupId) async {
    throw const NexmemException('NOT_STARTED', '群聊服务尚未接入内核');
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(
      body: SizedBox(width: NexmemMetrics.profilePaneWidth, child: child),
    ),
  );
}

void main() {
  testWidgets('群聊面板展示成员、密钥版本与群盘提示，并可打开群设置', (
    WidgetTester tester,
  ) async {
    final GroupInfo info = GroupInfo(
      groupId: 'g1',
      title: '项目群',
      keyVersion: 3,
      storageConfigured: false,
      members: <GroupMember>[
        GroupMember(account: _hex('a'), role: 'admin'),
        GroupMember(account: _hex('b'), role: 'member'),
      ],
    );
    bool opened = false;
    bool closed = false;

    await tester.pumpWidget(
      _wrap(
        ChatProfilePanel(
          conversation: _groupConversation,
          groups: _FakeGroups(info),
          selfAccount: _hex('b'),
          onClose: () => closed = true,
          onOpenGroupInfo: () => opened = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('聊天信息'), findsOneWidget);
    expect(find.text('项目群'), findsOneWidget);
    expect(find.text('群聊 · 2 位成员'), findsOneWidget);
    expect(find.text('群成员（2）'), findsOneWidget);
    expect(find.text('密钥版本 v3'), findsOneWidget);
    expect(find.text(GroupStorageNotice.message), findsOneWidget);
    expect(find.text('aaaaaa…'), findsOneWidget);
    expect(find.text('bbbbbb…（我）'), findsOneWidget);
    expect(find.text('群主'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('chat-profile-open-group')));
    expect(opened, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('chat-profile-close')));
    expect(closed, isTrue);
  });

  testWidgets('群聊面板加载失败时展示错误与重试入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        ChatProfilePanel(
          conversation: _groupConversation,
          groups: _FailingGroups(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('群聊服务尚未接入内核'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('chat-profile-retry')),
      findsOneWidget,
    );
  });

  testWidgets('单聊面板展示账号短串、在线状态与端到端加密说明', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        ChatProfilePanel(
          conversation: _directConversation,
          groups: const UnavailableGroupService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('单聊 · 在线'), findsOneWidget);
    expect(find.text(shortAccountLabel(_hex('c'))), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('消息端到端加密，仅你与对方可读'), findsOneWidget);
  });
}
