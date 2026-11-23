// ui-spec.md §8/§9 验收：骨架屏、断网提示与桌面/Web 快捷键。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chats/chats_page.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/chats/conversation_store.dart';
import 'package:nexmem_app/features/search/search_page.dart';

Widget _wrap(Widget child) {
  return MaterialApp(theme: NexmemTheme.light(), home: Scaffold(body: child));
}

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const NexmemApp());
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key,
    {LogicalKeyboardKey? modifier}) async {
  if (modifier != null) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  if (modifier != null) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首屏加载展示 6 行骨架屏，加载完成后回到空态', (WidgetTester tester) async {
    final ConversationStore store = ConversationStore();
    addTearDown(store.dispose);

    await tester.pumpWidget(_wrap(ChatsPage(store: store, loading: true)));
    expect(find.byType(ConversationSkeleton), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('conversation-skeleton')),
        findsOneWidget);
    expect(find.text('暂无会话，点击 + 发起聊天'), findsNothing);

    await tester.pumpWidget(
      _wrap(ChatsPage(store: store, loading: false)),
    );
    expect(find.byType(ConversationSkeleton), findsNothing);
    expect(find.text('暂无会话，点击 + 发起聊天'), findsOneWidget);
  });

  testWidgets('骨架屏不覆盖已有会话', (WidgetTester tester) async {
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

    await tester.pumpWidget(_wrap(ChatsPage(store: store, loading: true)));
    expect(find.byType(ConversationSkeleton), findsNothing);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('断网时会话列表顶部提示正在重连', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const ChatsPage(offline: true)));
    expect(find.text('网络已断开，正在重连'), findsOneWidget);

    await tester.pumpWidget(_wrap(const ChatsPage()));
    expect(find.text('网络已断开，正在重连'), findsNothing);
  });

  testWidgets('桌面 Ctrl+F 打开搜索页，Esc 返回', (WidgetTester tester) async {
    await _pumpShell(tester, const Size(1280, 800));
    expect(find.byType(SearchPage), findsNothing);

    await _press(
      tester,
      LogicalKeyboardKey.keyF,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    expect(find.byType(SearchPage), findsOneWidget);
    expect(find.byKey(const Key('search-field')), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(SearchPage), findsNothing);
  });

  testWidgets('桌面 Ctrl+N 打开发起聊天面板', (WidgetTester tester) async {
    await _pumpShell(tester, const Size(1280, 800));

    await _press(
      tester,
      LogicalKeyboardKey.keyN,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    expect(find.text('发起单聊'), findsOneWidget);
    expect(find.text('创建群聊'), findsOneWidget);
  });

  testWidgets('移动端 Esc 回到消息 Tab', (WidgetTester tester) async {
    await _pumpShell(tester, const Size(390, 844));

    await tester.tap(find.text('联系人'));
    await tester.pumpAndSettle();
    expect(find.text('好友'), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(find.text('暂无会话，点击 + 发起聊天'), findsOneWidget);
  });
}
