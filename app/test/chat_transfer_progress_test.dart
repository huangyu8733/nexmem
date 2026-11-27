// 文件发送 / 接收进度条验收：两端都显示，且进度事件早于消息时也能回填。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/features/chat/chat_store.dart';
import 'package:nexmem_app/features/chats/conversation.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

const ConversationItem _peer = ConversationItem(id: 'alice', title: 'Alice');

ChatMessage _fileMessage({
  String id = 'file-1',
  bool mine = false,
  int done = 0,
  int total = 0,
}) {
  return ChatMessage(
    id: id,
    conversationId: _peer.id,
    text: 'report.zip',
    sentAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    isMine: mine,
    status: mine ? MessageStatus.sending : MessageStatus.sent,
    transferDone: done,
    transferTotal: total,
    attachment: const ChatAttachment(
      name: 'report.zip',
      size: 100,
      mime: 'application/zip',
      path: '/tmp/report.zip',
    ),
  );
}

void main() {
  test('进度事件早于消息到达时暂存并回填', () {
    final ChatStore store = ChatStore(conversationId: _peer.id);
    addTearDown(store.dispose);
    store.setTransferProgress('file-1', 40, 100);
    expect(store.byId('file-1'), isNull);
    store.receive(_fileMessage());
    expect(store.byId('file-1')!.transferDone, 40);
    expect(store.byId('file-1')!.transferTotal, 100);
  });

  test('消息回包不会清掉接收中的进度', () {
    final ChatStore store = ChatStore(conversationId: _peer.id);
    addTearDown(store.dispose);
    store.receive(_fileMessage(done: 40, total: 100));
    store.merge(_fileMessage());
    expect(store.byId('file-1')!.transferDone, 40);
    expect(store.byId('file-1')!.transferTotal, 100);
    // 完成后回包可以正常清零进度标记。
    store.merge(_fileMessage(done: 100, total: 100));
    expect(store.byId('file-1')!.transferDone, 100);
  });

  testWidgets('接收端文件气泡显示百分比进度条', (WidgetTester tester) async {
    final ChatStore store = ChatStore(conversationId: _peer.id);
    addTearDown(store.dispose);
    store.receive(_fileMessage(done: 40, total: 100));
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peer, store: store)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-file-progress-file-1')), findsOneWidget);
    expect(find.textContaining('40%'), findsWidgets);
  });

  testWidgets('发送中但未收到首条进度时显示不确定进度条', (WidgetTester tester) async {
    final ChatStore store = ChatStore(conversationId: _peer.id);
    addTearDown(store.dispose);
    store.receive(_fileMessage(mine: true));
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peer, store: store)),
    );
    // 不确定进度条会持续动画，不能用 pumpAndSettle。
    await tester.pump();
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey<String>('chat-file-progress-file-1')),
    );
    expect(bar.value, isNull);
  });
}
