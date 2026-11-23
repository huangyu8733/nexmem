// P1-18 会话列表验收：会话项字段、置顶排序、新消息上浮与未读角标。
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chats/chats_page.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/chats/conversation_store.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  test('会话时间格式：今天 / 昨天 / 周X / 更早', () {
    final DateTime now = DateTime(2026, 11, 19, 15, 0);

    expect(formatConversationTime(DateTime(2026, 11, 19, 8, 5), now: now), '08:05');
    expect(formatConversationTime(DateTime(2026, 11, 18, 23, 59), now: now), '昨天');
    expect(formatConversationTime(DateTime(2026, 11, 16, 9, 0), now: now), '周一');
    expect(formatConversationTime(DateTime(2026, 11, 10, 9, 0), now: now), '2026/11/10');
    // 时钟偏差导致的“未来”时间按当天处理。
    expect(formatConversationTime(DateTime(2026, 11, 19, 15, 30), now: now), '15:30');
  });

  testWidgets('会话项展示头像首字、昵称、摘要、时间与未读角标', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(
          id: 'alice',
          title: 'Alice',
          lastMessage: '晚上见',
          lastMessageAt: now,
          unread: 3,
          presence: PresenceStatus.online,
        ),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(_wrap(ChatsPage(store: store)));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('晚上见'), findsOneWidget);
    expect(find.text(formatConversationTime(now)), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('置顶优先，其余按最后消息时间倒序', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(
          id: 'older',
          title: '较早会话',
          lastMessage: '早',
          lastMessageAt: now.subtract(const Duration(hours: 2)),
        ),
        ConversationItem(
          id: 'pinned',
          title: '置顶会话',
          lastMessage: '置顶',
          lastMessageAt: now.subtract(const Duration(days: 1)),
          pinned: true,
        ),
        ConversationItem(
          id: 'recent',
          title: '最新会话',
          lastMessage: '最新',
          lastMessageAt: now,
        ),
      ],
    );
    addTearDown(store.dispose);

    expect(
      store.sorted.map((ConversationItem e) => e.id).toList(),
      <String>['pinned', 'recent', 'older'],
    );

    await tester.pumpWidget(_wrap(ChatsPage(store: store)));

    final double pinnedY = tester.getTopLeft(find.text('置顶会话')).dy;
    final double recentY = tester.getTopLeft(find.text('最新会话')).dy;
    final double olderY = tester.getTopLeft(find.text('较早会话')).dy;
    expect(pinnedY, lessThan(recentY));
    expect(recentY, lessThan(olderY));
  });

  testWidgets('新消息到达后会话上浮、未读递增，超过 99 显示 99+', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(
          id: 'a',
          title: '会话A',
          lastMessage: '旧消息',
          lastMessageAt: now.subtract(const Duration(minutes: 5)),
        ),
        ConversationItem(
          id: 'b',
          title: '会话B',
          lastMessage: '刚刚',
          lastMessageAt: now,
        ),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(_wrap(ChatsPage(store: store)));

    store.receive('a', '新消息', at: now.add(const Duration(minutes: 1)));
    await tester.pump();

    expect(
      store.sorted.map((ConversationItem e) => e.id).toList(),
      <String>['a', 'b'],
    );
    expect(find.text('新消息'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('会话A')).dy,
      lessThan(tester.getTopLeft(find.text('会话B')).dy),
    );

    store.upsert(store.byId('a')!.copyWith(unread: 120));
    await tester.pump();
    expect(find.text('99+'), findsOneWidget);

    store.markRead('a');
    await tester.pump();
    expect(find.text('99+'), findsNothing);
    expect(store.byId('a')!.unread, 0);
  });

  testWidgets('左滑标记已读：清空未读并回调上层同步内核', (WidgetTester tester) async {
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(
          id: 'alice',
          title: 'Alice',
          lastMessage: '在吗',
          lastMessageAt: DateTime.now(),
          unread: 2,
        ),
      ],
    );
    addTearDown(store.dispose);
    ConversationItem? marked;

    await tester.pumpWidget(
      _wrap(
        ChatsPage(
          store: store,
          onMarkRead: (ConversationItem item) => marked = item,
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);

    await tester.drag(find.text('Alice'), const Offset(400, 0));
    await tester.pumpAndSettle();

    expect(marked?.id, 'alice');
    expect(store.byId('alice')!.unread, 0);
    expect(find.text('2'), findsNothing);
  });

  testWidgets('左滑删除：确认后移除条目并回调上层', (WidgetTester tester) async {
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(
          id: 'alice',
          title: 'Alice',
          lastMessage: '在吗',
          lastMessageAt: DateTime.now(),
        ),
      ],
    );
    addTearDown(store.dispose);
    ConversationItem? deleted;

    await tester.pumpWidget(
      _wrap(
        ChatsPage(
          store: store,
          onDelete: (ConversationItem item) => deleted = item,
        ),
      ),
    );

    await tester.drag(find.text('Alice'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('删除会话'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('删除'),
      ),
    );
    await tester.pumpAndSettle();

    expect(deleted?.id, 'alice');
    expect(store.byId('alice'), isNull);
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('桌面右键菜单：标记已读与删除（ui-spec.md §2）', (WidgetTester tester) async {
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(
          id: 'alice',
          title: 'Alice',
          lastMessage: '在吗',
          lastMessageAt: DateTime.now(),
          unread: 1,
        ),
      ],
    );
    addTearDown(store.dispose);
    ConversationItem? marked;

    await tester.pumpWidget(
      _wrap(
        ChatsPage(
          store: store,
          onMarkRead: (ConversationItem item) => marked = item,
        ),
      ),
    );

    await tester.tap(find.text('Alice'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('标记已读'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('标记已读'));
    await tester.pumpAndSettle();

    expect(marked?.id, 'alice');
    expect(store.byId('alice')!.unread, 0);
  });

  testWidgets('右键菜单：置顶 / 取消置顶与免打扰（P6-17）', (WidgetTester tester) async {
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(
          id: 'alice',
          title: 'Alice',
          lastMessage: '在吗',
          lastMessageAt: DateTime.now(),
        ),
      ],
    );
    addTearDown(store.dispose);
    bool? pinnedArg;
    bool? mutedArg;

    await tester.pumpWidget(
      _wrap(
        ChatsPage(
          store: store,
          onSetPinned: (ConversationItem item, bool pinned) async {
            pinnedArg = pinned;
          },
          onSetMuted: (ConversationItem item, bool muted) async {
            mutedArg = muted;
          },
        ),
      ),
    );

    await tester.tap(find.text('Alice'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('免打扰'), findsOneWidget);

    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(pinnedArg, isTrue);
    expect(store.byId('alice')!.pinned, isTrue);

    await tester.tap(find.text('Alice'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget);

    await tester.tap(find.text('免打扰'));
    await tester.pumpAndSettle();
    expect(mutedArg, isTrue);
    expect(store.byId('alice')!.muted, isTrue);

    await tester.tap(find.text('Alice'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('取消免打扰'), findsOneWidget);

    // 取消置顶 / 取消免打扰也要回调 false。
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    expect(pinnedArg, isFalse);
    expect(store.byId('alice')!.pinned, isFalse);

    await tester.tap(find.text('Alice'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消免打扰'));
    await tester.pumpAndSettle();
    expect(mutedArg, isFalse);
    expect(store.byId('alice')!.muted, isFalse);
  });
}
