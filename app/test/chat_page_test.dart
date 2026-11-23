// P1-19 聊天页验收：时间分隔、气泡方向、发送状态、输入工具条、千条滚动。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/features/chat/chat_store.dart';
import 'package:nexmem_app/features/chat/local_image.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/group/group_storage.dart';
import 'package:nexmem_app/transport/transport.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

const ConversationItem _peerConversation = ConversationItem(
  id: 'alice',
  title: 'Alice',
  presence: PresenceStatus.online,
);

const ConversationItem _groupConversation = ConversationItem(
  id: 'group-1',
  title: '项目群',
  isGroup: true,
);

ChatMessage _msg(
  String id,
  String text, {
  required DateTime at,
  bool mine = false,
  String sender = 'Alice',
  String senderId = 'alice',
}) {
  return ChatMessage(
    id: id,
    conversationId: 'alice',
    text: text,
    sentAt: at,
    isMine: mine,
    senderName: mine ? '我' : sender,
    senderId: mine ? 'me' : senderId,
    status: mine ? MessageStatus.sent : MessageStatus.delivered,
  );
}

class _FakeSender implements ChatSender {
  _FakeSender(this.handler);

  final Future<void> Function() handler;

  /// 最近一次 `sendFile` 的入参，便于断言路径与 MIME 透传。
  Map<String, Object?>? lastFile;

  /// 最近一次 `sendText` 的引用 ID（P6-32）。
  String? lastReplyTo;

  /// 最近一次 `sendText` 的 @ 成员列表（七-1）。
  List<String>? lastMentions;

  /// 最近一次 `sendText` 的定时消息小时数（七-4）。
  int? lastTtlHours;

  @override
  Future<String> sendText({
    required String conversationId,
    required String msgUuid,
    required String text,
    String? replyTo,
    List<String>? mentions,
    int ttlHours = 0,
  }) async {
    lastReplyTo = replyTo;
    lastMentions = mentions;
    lastTtlHours = ttlHours;
    await handler();
    return msgUuid;
  }

  @override
  Future<String> editMessage({
    required String conversationId,
    required String msgUuid,
    required String text,
  }) async {
    await handler();
    return msgUuid;
  }

  @override
  Future<void> setTyping({
    required String conversationId,
    required bool typing,
  }) async {}

  @override
  Future<String> sendFile({
    required String conversationId,
    required String msgUuid,
    required String path,
    String mime = '',
  }) async {
    lastFile = <String, Object?>{
      'conversationId': conversationId,
      'msgUuid': msgUuid,
      'path': path,
      'mime': mime,
    };
    await handler();
    return msgUuid;
  }
}

void main() {
  test('时间分隔：间隔满 5 分钟才显示，文案分今天/昨天/更早', () {
    final DateTime base = DateTime(2026, 11, 19, 10, 0);
    expect(shouldShowTimeSeparator(null, base), isTrue);
    expect(shouldShowTimeSeparator(base, base.add(const Duration(minutes: 4))), isFalse);
    expect(shouldShowTimeSeparator(base, base.add(const Duration(minutes: 5))), isTrue);
    // 乱序到达产生负间隔时同样插分隔，避免消息挤在一起。
    expect(shouldShowTimeSeparator(base, base.subtract(const Duration(minutes: 9))), isTrue);

    final DateTime now = DateTime(2026, 11, 19, 15, 0);
    expect(formatMessageTime(DateTime(2026, 11, 19, 8, 5), now: now), '08:05');
    expect(formatMessageTime(DateTime(2026, 11, 18, 23, 59), now: now), '昨天 23:59');
    expect(formatMessageTime(DateTime(2026, 11, 10, 9, 0), now: now), '2026/11/10 09:00');
  });

  test('消息按 sent_at 升序插入，同一 msg_uuid 只保留一条', () {
    final DateTime base = DateTime(2026, 11, 19, 10, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        _msg('m2', '第二条', at: base.add(const Duration(minutes: 2))),
        _msg('m1', '第一条', at: base),
        _msg('m3', '第三条', at: base.add(const Duration(minutes: 5))),
      ],
    );
    addTearDown(store.dispose);

    expect(store.messages.map((ChatMessage m) => m.id), <String>['m1', 'm2', 'm3']);

    store.receive(_msg('m2', '重复投递', at: base.add(const Duration(minutes: 2))));
    expect(store.length, 3);
    expect(store.byId('m2')!.text, '重复投递');
  });

  testWidgets('气泡方向：自己靠右、对方靠左；5 分钟分隔条只出现两次', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 11, 19, 10, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        _msg('a', '早', at: base),
        _msg('b', '三分钟后', at: base.add(const Duration(minutes: 3))),
        _msg('c', '我发的', at: base.add(const Duration(minutes: 20)), mine: true),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessageTimeSeparator), findsNWidgets(2));

    final double width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final double mineX = tester.getCenter(find.text('我发的')).dx;
    final double peerX = tester.getCenter(find.text('早')).dx;
    expect(mineX, greaterThan(width / 2));
    expect(peerX, lessThan(width / 2));
  });

  testWidgets('群聊在对方气泡上方显示发送者昵称', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      initial: <ChatMessage>[
        _msg('g1', '大家好', at: DateTime(2026, 11, 19, 10, 0), sender: '张三'),
        _msg('g2', '收到', at: DateTime(2026, 11, 19, 10, 1), mine: true),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _groupConversation, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('张三'), findsOneWidget);
    // 自己的消息不显示发送者昵称（头像首字仍为「我」）。
    expect(find.text('我'), findsOneWidget);
  });

  testWidgets('发送状态：发送中转圈 → 已发送单勾；失败红叹号点击重发', (WidgetTester tester) async {
    final Completer<void> gate = Completer<void>();
    int attempts = 0;
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      sender: _FakeSender(() async {
        attempts++;
        if (attempts == 1) {
          await gate.future;
        }
      }),
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pump();

    expect(find.text('你好'), findsOneWidget);
    expect(find.byTooltip('发送中'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('已发送'), findsOneWidget);
    expect(attempts, 1);

    final ChatStore failing = ChatStore(
      conversationId: 'alice',
      sender: _FakeSender(() async => throw StateError('offline')),
    );
    addTearDown(failing.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: failing)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '发不出去');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('发送失败，点击重发'), findsOneWidget);
    expect(failing.messages.single.status, MessageStatus.failed);

    await tester.tap(find.byIcon(Icons.error));
    await tester.pumpAndSettle();
    expect(failing.messages.single.status, MessageStatus.failed);
    expect(attempts, 1);
  });

  testWidgets('输入工具条齐全，Enter 发送、Shift+Enter 换行', (WidgetTester tester) async {
    final ChatStore store = ChatStore(conversationId: 'alice');
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    for (final String tool in <String>['语音', '表情', '图片', '文件']) {
      expect(find.byTooltip(tool), findsOneWidget);
    }

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '回车发送');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(store.length, 1);
    expect(store.messages.single.text, '回车发送');
    expect(store.messages.single.status, MessageStatus.sent);
    expect(find.text('回车发送'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '第一行');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(store.length, 1);
    expect(find.byTooltip('发送中'), findsNothing);
  });

  testWidgets('桌面宽屏顶部资料面板入口可切换展开状态', (WidgetTester tester) async {
    final ChatStore store = ChatStore(conversationId: 'alice');
    addTearDown(store.dispose);

    int toggles = 0;
    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onToggleProfile: () => toggles++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('聊天信息'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('chat-profile-toggle')),
    );
    expect(toggles, 1);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onToggleProfile: () => toggles++,
          profileOpen: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起聊天信息'), findsOneWidget);
  });

  testWidgets('表情面板：展开后点选插入光标处，可发送并再次点击收起', (
    WidgetTester tester,
  ) async {
    final ChatStore store = ChatStore(conversationId: 'alice');
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    const ValueKey<String> panelKey = ValueKey<String>('chat-emoji-panel');
    expect(find.byKey(panelKey), findsNothing);

    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle();
    expect(find.byKey(panelKey), findsOneWidget);

    // 光标置于文本中间，表情应插入光标处而不是追加到末尾。
    await tester.enterText(find.byType(TextField), '你好');
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    field.controller!.selection = const TextSelection.collapsed(offset: 1);
    await tester.tap(find.byKey(const ValueKey<String>('chat-emoji-😀')));
    await tester.pumpAndSettle();
    expect(field.controller!.text, '你😀好');

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(store.length, 1);
    expect(store.messages.single.text, '你😀好');
    expect(field.controller!.text, isEmpty);

    await tester.tap(find.byTooltip('表情'));
    await tester.pumpAndSettle();
    expect(find.byKey(panelKey), findsNothing);
  });

  testWidgets('1000 条消息只构建可视范围，滚动到历史消息正常', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 11, 19, 8, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: List<ChatMessage>.generate(
        1000,
        (int i) => _msg(
          'm$i',
          '消息 $i',
          at: base.add(Duration(seconds: i)),
          mine: i.isEven,
        ),
      ),
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('消息 999'), findsOneWidget);
    expect(find.byType(MessageBubble).evaluate().length, lessThan(80));

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('消息 999'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对端未开启离线存储时输入区上方常驻降级提示', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      sender: _FakeSender(
        () async => throw const NexmemException(
          offlineStorageDisabledCode,
          '对方未开启离线存储',
        ),
      ),
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text(OfflineStorageNotice.message), findsNothing);

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(store.peerOfflineStorageDisabled, isTrue);
    expect(store.messages.single.status, MessageStatus.failed);
    expect(find.text('对方未开启离线存储，仅支持在线发送'), findsOneWidget);
  });

  testWidgets('降级提示仅出现在单聊，群聊不显示', (WidgetTester tester) async {
    final ChatStore dm = ChatStore(
      conversationId: 'alice',
      peerOfflineStorageDisabled: true,
    );
    addTearDown(dm.dispose);
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: dm)),
    );
    await tester.pumpAndSettle();
    expect(find.text(OfflineStorageNotice.message), findsOneWidget);

    final ChatStore group = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      peerOfflineStorageDisabled: true,
    );
    addTearDown(group.dispose);
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _groupConversation, store: group)),
    );
    await tester.pumpAndSettle();
    expect(find.text(OfflineStorageNotice.message), findsNothing);
  });

  testWidgets('普通发送失败不产生离线存储降级提示', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      sender: _FakeSender(() async => throw StateError('offline')),
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '发不出去');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(store.peerOfflineStorageDisabled, isFalse);
    expect(find.text(OfflineStorageNotice.message), findsNothing);
  });

  testWidgets('群盘未配置时群聊常驻提示，状态更新实时生效', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      groupStorage: GroupStorageStatus.unconfigured,
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _groupConversation, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text(GroupStorageNotice.message), findsOneWidget);
    expect(find.text('未配置群盘，离线消息不可补'), findsOneWidget);

    // 发送消息后提示仍常驻。
    await tester.enterText(find.byType(TextField), '大家好');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.text(GroupStorageNotice.message), findsOneWidget);

    // 管理员配置群盘后提示消失，再关闭又出现。
    store.setGroupStorageStatus(GroupStorageStatus.configured);
    await tester.pumpAndSettle();
    expect(find.text(GroupStorageNotice.message), findsNothing);

    store.setGroupStorageStatus(GroupStorageStatus.unconfigured);
    await tester.pumpAndSettle();
    expect(find.text(GroupStorageNotice.message), findsOneWidget);
  });

  testWidgets('群盘提示仅在明确未配置的群聊显示，未知/已配置与单聊都不显示', (WidgetTester tester) async {
    final ChatStore unknown = ChatStore(conversationId: 'group-1', isGroup: true);
    addTearDown(unknown.dispose);
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _groupConversation, store: unknown)),
    );
    await tester.pumpAndSettle();
    expect(find.text(GroupStorageNotice.message), findsNothing);

    final ChatStore configured = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      groupStorage: GroupStorageStatus.configured,
    );
    addTearDown(configured.dispose);
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _groupConversation, store: configured)),
    );
    await tester.pumpAndSettle();
    expect(find.text(GroupStorageNotice.message), findsNothing);

    final ChatStore dm = ChatStore(
      conversationId: 'alice',
      groupStorage: GroupStorageStatus.unconfigured,
    );
    addTearDown(dm.dispose);
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: dm)),
    );
    await tester.pumpAndSettle();
    expect(find.text(GroupStorageNotice.message), findsNothing);
  });

  testWidgets('上翻查看历史时新消息显示浮标，点击回到最新', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 11, 19, 8, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: List<ChatMessage>.generate(
        80,
        (int i) => _msg('m$i', '历史 $i', at: base.add(Duration(minutes: i))),
      ),
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();

    store.receive(_msg('new', '新来的', at: base.add(const Duration(hours: 2))));
    await tester.pumpAndSettle();

    expect(find.text('1 条新消息'), findsOneWidget);

    await tester.tap(find.text('1 条新消息'));
    await tester.pumpAndSettle();

    expect(find.text('1 条新消息'), findsNothing);
    expect(find.text('新来的'), findsOneWidget);
  });

  testWidgets('上翻到顶加载更早历史，且不误报新消息浮标', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 11, 19, 8, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: List<ChatMessage>.generate(
        80,
        (int i) => _msg('m$i', '历史 $i', at: base.add(Duration(minutes: i))),
      ),
    );
    addTearDown(store.dispose);

    int calls = 0;
    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onLoadOlder: () async {
            calls++;
            store.receive(
              _msg(
                'older',
                '更早的消息',
                at: base.subtract(const Duration(hours: 1)),
              ),
            );
            return false;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await tester.pumpAndSettle();
    // 更早的消息拼接在列表顶部，继续上翻即可看到，且不产生新消息浮标。
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(store.messages.first.id, 'older');
    expect(find.text('更早的消息'), findsOneWidget);
    expect(find.textContaining('条新消息'), findsNothing);
  });

  testWidgets('搜索命中消息定位到可视区并高亮', (WidgetTester tester) async {
    final DateTime base = DateTime(2026, 11, 19, 8, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: List<ChatMessage>.generate(
        120,
        (int i) => _msg('m$i', '历史 $i', at: base.add(Duration(minutes: i))),
      ),
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          highlightMsgUuid: 'm40',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('历史 40'), findsOneWidget);
    final MessageBubble bubble = tester.widget<MessageBubble>(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is MessageBubble && widget.message.id == 'm40',
      ),
    );
    expect(bubble.highlighted, isTrue);
    expect(find.textContaining('条新消息'), findsNothing);
  });

  test('文件大小格式化按 1024 进制并保留一位小数', () {
    expect(formatFileSize(0), '0 B');
    expect(formatFileSize(1023), '1023 B');
    expect(formatFileSize(1024), '1.0 KB');
    expect(formatFileSize(1536), '1.5 KB');
    expect(formatFileSize(1024 * 1024 * 3), '3.0 MB');
    expect(formatFileSize(1024 * 1024 * 1024 * 2), '2.0 GB');
  });

  testWidgets('文件气泡展示文件名与大小，传输中显示百分比进度', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        ChatMessage(
          id: 'f1',
          conversationId: 'alice',
          text: '报告.pdf',
          sentAt: DateTime(2026, 11, 19, 10, 0),
          isMine: true,
          status: MessageStatus.sending,
          attachment: const ChatAttachment(
            name: '报告.pdf',
            size: 2048,
            mime: 'application/pdf',
            path: r'D:\docs\报告.pdf',
          ),
          transferDone: 512,
          transferTotal: 2048,
        ),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pump();

    expect(find.text('报告.pdf'), findsOneWidget);
    expect(find.text('25% · 2.0 KB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // 进度事件推进到完成，气泡退化为大小文本且进度条消失。
    store.setTransferProgress('f1', 2048, 2048);
    store.updateStatus('f1', MessageStatus.sent);
    await tester.pumpAndSettle();

    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('文件工具经 onPickFile 注入路径后经通道发送，正文为文件名', (WidgetTester tester) async {
    final _FakeSender sender = _FakeSender(() async {});
    final ChatStore store = ChatStore(conversationId: 'alice', sender: sender);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onPickFile: () async => const ChatAttachment(
            name: '报告.pdf',
            size: 128,
            mime: 'application/pdf',
            path: r'D:\docs\报告.pdf',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();

    expect(sender.lastFile?['path'], r'D:\docs\报告.pdf');
    expect(sender.lastFile?['mime'], 'application/pdf');
    expect(store.length, 1);
    expect(store.messages.single.text, '报告.pdf');
    expect(store.messages.single.status, MessageStatus.sent);
    expect(find.text('报告.pdf'), findsOneWidget);
    expect(find.text('128 B'), findsOneWidget);
  });

  testWidgets('文件发送失败置为可重发，重发沿用同一 msg_uuid 与路径', (WidgetTester tester) async {
    int calls = 0;
    final _FakeSender sender = _FakeSender(() async {
      calls++;
      if (calls == 1) {
        throw StateError('peer offline');
      }
    });
    final ChatStore store = ChatStore(conversationId: 'alice', sender: sender);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    await store.sendFile(
      const ChatAttachment(name: 'a.bin', size: 10, path: r'D:\a.bin'),
    );
    await tester.pumpAndSettle();

    final String failedId = store.messages.single.id;
    expect(store.messages.single.status, MessageStatus.failed);

    await expectLater(
      store.sendFile(
        const ChatAttachment(name: 'x', size: 1, path: ''),
      ),
      throwsArgumentError,
    );

    await tester.tap(find.byIcon(Icons.error));
    await tester.pumpAndSettle();

    expect(store.messages.single.id, failedId);
    expect(store.messages.single.status, MessageStatus.sent);
    expect(sender.lastFile?['path'], r'D:\a.bin');
  });

  testWidgets('A-02 群聊文件工具经 sendFile 发送，文件密文与元数据交由内核写入群盘', (
    WidgetTester tester,
  ) async {
    final _FakeSender sender = _FakeSender(() async {});
    final ChatStore store = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      sender: sender,
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _groupConversation,
          store: store,
          onPickFile: () async => const ChatAttachment(
            name: 'a.txt',
            size: 1,
            mime: 'text/plain',
            path: r'D:\a.txt',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();

    expect(find.text('群聊暂不支持发送文件'), findsNothing);
    expect(sender.lastFile?['conversationId'], 'group-1');
    expect(sender.lastFile?['path'], r'D:\a.txt');
    expect(sender.lastFile?['mime'], 'text/plain');
    expect(store.length, 1);
    expect(store.messages.single.text, 'a.txt');
    expect(store.messages.single.status, MessageStatus.sent);
  });

  testWidgets('图片工具只接受图片文件，非图片给出提示且不发送', (WidgetTester tester) async {
    final _FakeSender sender = _FakeSender(() async {});
    final ChatStore store = ChatStore(conversationId: 'alice', sender: sender);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onPickFile: () async => const ChatAttachment(
            name: 'notes.txt',
            size: 10,
            path: r'D:\notes.txt',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('图片'));
    await tester.pumpAndSettle();

    expect(find.text('请选择图片文件（png / jpg / gif / webp）'), findsOneWidget);
    expect(sender.lastFile, isNull);
    expect(store.length, 0);
  });

  testWidgets('图片工具补齐 MIME 并内联缩略图，传输中显示百分比', (WidgetTester tester) async {
    final Completer<void> gate = Completer<void>();
    final _FakeSender sender = _FakeSender(() => gate.future);
    final ChatStore store = ChatStore(conversationId: 'alice', sender: sender);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onPickFile: () async => const ChatAttachment(
            name: 'photo.PNG',
            size: 4096,
            path: r'D:\pics\photo.PNG',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('图片'));
    await tester.pump();
    await tester.pump();

    expect(sender.lastFile?['mime'], 'image/png');
    expect(sender.lastFile?['path'], r'D:\pics\photo.PNG');
    expect(find.byType(LocalImage), findsOneWidget);
    expect(store.messages.single.status, MessageStatus.sending);

    final String id = store.messages.single.id;
    store.setTransferProgress(id, 4096, 8192);
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(store.messages.single.status, MessageStatus.sent);
    expect(find.text('photo.PNG · 4.0 KB'), findsOneWidget);
  });

  testWidgets('A-01 语音工具选音频经文件通道发送并补齐 MIME', (
    WidgetTester tester,
  ) async {
    final _FakeSender sender = _FakeSender(() async {});
    final ChatStore store = ChatStore(conversationId: 'alice', sender: sender);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onPickFile: () async => const ChatAttachment(
            name: 'voice.M4A',
            size: 2048,
            path: r'D:\voice\voice.M4A',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('语音'));
    await tester.pumpAndSettle();

    expect(sender.lastFile?['path'], r'D:\voice\voice.M4A');
    expect(sender.lastFile?['mime'], 'audio/mp4');
    expect(store.length, 1);
  });

  testWidgets('A-01 语音工具拒绝非音频文件且不发送', (WidgetTester tester) async {
    final _FakeSender sender = _FakeSender(() async {});
    final ChatStore store = ChatStore(conversationId: 'alice', sender: sender);
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onPickFile: () async => const ChatAttachment(
            name: 'notes.txt',
            size: 10,
            path: r'D:\notes.txt',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('语音'));
    await tester.pumpAndSettle();

    expect(
      find.text('请选择音频文件（m4a / mp3 / wav / aac 等）'),
      findsOneWidget,
    );
    expect(sender.lastFile, isNull);
    expect(store.length, 0);
  });

  testWidgets('接收端图片消息带落盘路径时显示缩略图，无路径回退文件气泡', (
    WidgetTester tester,
  ) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        ChatMessage(
          id: 'img-1',
          conversationId: 'alice',
          text: '风景.jpg',
          sentAt: DateTime(2026, 11, 19, 10, 0),
          attachment: const ChatAttachment(
            name: '风景.jpg',
            size: 1024,
            mime: 'image/jpeg',
            path: r'D:\inbox\风景.jpg',
          ),
        ),
        ChatMessage(
          id: 'img-2',
          conversationId: 'alice',
          text: '无路径.png',
          sentAt: DateTime(2026, 11, 19, 10, 1),
          attachment: const ChatAttachment(
            name: '无路径.png',
            size: 512,
            mime: 'image/png',
          ),
        ),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LocalImage), findsOneWidget);
    expect(find.text('风景.jpg · 1.0 KB'), findsOneWidget);
    expect(find.text('无路径.png'), findsOneWidget);
    expect(find.text('512 B'), findsOneWidget);
  });

  testWidgets('长按消息弹出复制与删除，删除经 msg.delete 注入后移除消息', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        _msg('m1', '可以复制的文本', at: DateTime(2026, 11, 19, 10, 0)),
      ],
    );
    addTearDown(store.dispose);
    final List<String> deleted = <String>[];
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onDeleteMessage: (String msgUuid) async => deleted.add(msgUuid),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 复制：菜单出现后点「复制」给出提示，消息仍在。
    await tester.longPress(find.text('可以复制的文本'));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, '可以复制的文本');
    expect(find.text('已复制'), findsOneWidget);
    expect(store.length, 1);

    // 删除：确认后经注入的回调落库，再从内存移除。
    await tester.longPress(find.text('可以复制的文本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('仅从本机删除，对方仍可看到这条消息。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(deleted, <String>['m1']);
    expect(store.length, 0);
    expect(find.text('可以复制的文本'), findsNothing);
  });

  testWidgets('转发与 2 分钟撤回：仅己方近期消息可撤回，回调后移除气泡', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        _msg('mine', '刚发的消息', at: now, mine: true),
        _msg('theirs', '对方的消息', at: now.add(const Duration(seconds: 5))),
      ],
    );
    addTearDown(store.dispose);
    final List<String> forwarded = <String>[];
    final List<String> recalled = <String>[];

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onForwardMessage: (ChatMessage message) async {
            forwarded.add(message.id);
            return true;
          },
          onRecallMessage: (ChatMessage message) async {
            recalled.add(message.id);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 己方近期消息：菜单含转发与撤回。
    await tester.longPress(find.text('刚发的消息'));
    await tester.pumpAndSettle();
    expect(find.text('转发'), findsOneWidget);
    expect(find.text('撤回'), findsOneWidget);
    await tester.tap(find.text('转发'));
    await tester.pumpAndSettle();
    expect(forwarded, <String>['mine']);
    expect(find.text('已转发'), findsOneWidget);

    // 撤回：确认后经注入回调处理，再从内存移除。
    await tester.longPress(find.text('刚发的消息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤回'));
    await tester.pumpAndSettle();
    expect(find.text('撤回后对方也将看不到这条消息。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '撤回'));
    await tester.pumpAndSettle();
    expect(recalled, <String>['mine']);
    expect(find.text('刚发的消息'), findsNothing);

    // 对方消息没有撤回入口，但可以转发。
    await tester.longPress(find.text('对方的消息'));
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsNothing);
    expect(find.text('转发'), findsOneWidget);
  });

  testWidgets('群聊撤回：己方近期消息可撤回并提示群内成员不可见', (WidgetTester tester) async {
    final DateTime now = DateTime.now();
    final ChatStore store = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      initial: <ChatMessage>[
        ChatMessage(
          id: 'g-mine',
          conversationId: 'group-1',
          text: '群里刚发的',
          sentAt: now,
          isMine: true,
          senderName: '我',
          senderId: 'me',
          status: MessageStatus.sent,
          isGroup: true,
        ),
      ],
    );
    addTearDown(store.dispose);
    final List<String> recalled = <String>[];

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _groupConversation,
          store: store,
          onRecallMessage: (ChatMessage message) async {
            recalled.add(message.id);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('群里刚发的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤回'));
    await tester.pumpAndSettle();
    expect(find.text('撤回后群内其他成员也将看不到这条消息。'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '撤回'));
    await tester.pumpAndSettle();
    expect(recalled, <String>['g-mine']);
    expect(find.text('群里刚发的'), findsNothing);
  });

  testWidgets('更多 → 清空聊天记录：二次确认后清空本机历史并提示', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        _msg('m1', '要清空的消息', at: DateTime(2026, 11, 19, 10, 0)),
      ],
    );
    addTearDown(store.dispose);
    int clears = 0;

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onClearHistory: () async => clears++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 取消不触发内核清空，消息保留。
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空聊天记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除与「Alice」的本机聊天记录'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(clears, 0);
    expect(store.length, 1);

    // 确认后先调内核，再清空本机列表。
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空聊天记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();

    expect(clears, 1);
    expect(store.length, 0);
    expect(find.text('要清空的消息'), findsNothing);
    expect(find.text('聊天记录已清空'), findsOneWidget);
  });

  testWidgets('内核清空失败时提示错误且保留本机消息', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        _msg('m1', '不能丢的消息', at: DateTime(2026, 11, 19, 10, 0)),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onClearHistory: () async => throw StateError('db locked'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空聊天记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();

    expect(find.textContaining('清空失败'), findsOneWidget);
    expect(store.length, 1);
    expect(find.text('不能丢的消息'), findsOneWidget);
  });

  testWidgets('长按消息菜单包含引用，点选后出现引用预览（P6-32）', (
    WidgetTester tester,
  ) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        _msg('q-origin', '待引用的消息', at: DateTime(2026, 11, 20, 10, 0)),
      ],
    );
    addTearDown(store.dispose);

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('待引用的消息'));
    await tester.pumpAndSettle();
    expect(find.text('引用'), findsOneWidget);

    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-quote-preview')), findsOneWidget);
    expect(store.quoting?.id, 'q-origin');
  });

  testWidgets('引用回复：引用预览显示、replyTo 透传、发送后清空（P6-32）', (
    WidgetTester tester,
  ) async {
    final DateTime base = DateTime(2026, 11, 20, 9, 0);
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      sender: _FakeSender(() async {}),
      initial: <ChatMessage>[
        _msg('origin-1', '这是原文', at: base),
      ],
    );
    addTearDown(store.dispose);

    final _FakeSender sender = store.sender as _FakeSender;
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    // 无引用时不显示预览条。
    expect(find.byKey(const ValueKey<String>('chat-quote-preview')), findsNothing);

    // 通过 store 设定引用（长按菜单 / 右键菜单调用同一入口）。
    store.setQuoting(store.messages.single);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-quote-preview')), findsOneWidget);
    expect(find.text('引用 Alice'), findsOneWidget);

    // 输入并发送：消息带 replyTo，且引用预览清空。
    await tester.enterText(find.byType(TextField), '收到，同意');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(store.length, 2);
    expect(sender.lastReplyTo, 'origin-1');
    expect(store.messages.last.replyTo, 'origin-1');
    expect(find.byKey(const ValueKey<String>('chat-quote-preview')), findsNothing);

    // 气泡内引用条展示被引用消息正文。
    expect(find.byKey(const ValueKey<String>('chat-quoted-strip')), findsOneWidget);
    expect(find.text('这是原文'), findsWidgets);
  });

  testWidgets('引用预览可取消，取消后发送不带 replyTo（P6-32）', (
    WidgetTester tester,
  ) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      sender: _FakeSender(() async {}),
      initial: <ChatMessage>[
        _msg('origin-2', '取消引用测试', at: DateTime(2026, 11, 20, 9, 0)),
      ],
    );
    addTearDown(store.dispose);
    final _FakeSender sender = store.sender as _FakeSender;

    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();

    store.setQuoting(store.messages.single);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-quote-preview')), findsOneWidget);

    // 取消引用。
    await tester.tap(find.byKey(const ValueKey<String>('chat-quote-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-quote-preview')), findsNothing);

    await tester.enterText(find.byType(TextField), '普通回复');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(sender.lastReplyTo, isNull);
  });

  testWidgets('七-2 已编辑消息显示标记，长按仅自己的文本消息有编辑入口', (
    WidgetTester tester,
  ) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      sender: _FakeSender(() async {}),
    );
    store.receive(
      ChatMessage(
        id: 'edited-1',
        conversationId: 'alice',
        text: '被编辑过的文本',
        sentAt: DateTime.now(),
        isMine: true,
        edited: true,
        editedAt: 1234,
        status: MessageStatus.sent,
      ),
    );
    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _peerConversation,
          store: store,
          onEditMessage: (String uuid, String text) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('被编辑过的文本'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('edited-marker')), findsOneWidget);

    await tester.longPress(find.text('被编辑过的文本'));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
  });

  testWidgets('七-1 群聊 @ 候选按钮可见，选中后文本插入 @ 且 mentions 透传', (
    WidgetTester tester,
  ) async {
    final _FakeSender sender = _FakeSender(() async {});
    final ChatStore store = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      sender: sender,
    );
    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: _groupConversation,
          store: store,
          mentionCandidates: const <MentionCandidate>[
            MentionCandidate(account: 'bob-pub', name: 'Bob'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('@ 成员'), findsOneWidget);
    await tester.tap(find.byTooltip('@ 成员'));
    await tester.pumpAndSettle();
    final TextField field = tester.widget<TextField>(
      find.byType(TextField).first,
    );
    expect(field.controller!.text, '@Bob ');

    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(sender.lastMentions, <String>['bob-pub']);
  });

  testWidgets('七-3 typing 事件驱动「对方正在输入」提示', (
    WidgetTester tester,
  ) async {
    final ChatStore store = ChatStore(conversationId: 'alice');
    store.receive(ChatMessage(
      id: 'm',
      conversationId: 'alice',
      text: 'hi',
      sentAt: DateTime(2026),
    ));
    await tester.pumpWidget(
      _wrap(ChatPage(conversation: _peerConversation, store: store)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('typing-indicator')), findsNothing);

    store.setTyping(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('typing-indicator')), findsOneWidget);
    expect(find.text('对方正在输入…'), findsOneWidget);

    store.setTyping(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('typing-indicator')), findsNothing);
  });
}
