import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/chat/chat_store.dart';

void main() {
  group('七-1 @成员 / 七-2 编辑 / 七-3 typing 数据层', () {
    test('messagesFromItems 解析 mentions 与 edited 标记', () {
      final List<ChatMessage> messages = messagesFromItems(
        <dynamic>[
          <String, dynamic>{
            'msg_uuid': 'm1',
            'text': '@alice 看这个',
            'sent_at': 1730000000000,
            'direction': 'in',
            'state': 'received',
            'seq': 7,
            'mentions': <String>['alice-pub'],
            'edited': true,
            'edited_at': 1730000001234,
          },
        ],
        conversationId: 'group:abc',
        isGroup: true,
        selfAccount: 'self',
      );
      expect(messages, hasLength(1));
      expect(messages.first.mentions, <String>['alice-pub']);
      expect(messages.first.edited, isTrue);
      expect(messages.first.editedAt, 1730000001234);
      expect(messages.first.seq, 7);
    });

    test('无 mentions / edited 时保持默认值', () {
      final List<ChatMessage> messages = messagesFromItems(
        <dynamic>[
          <String, dynamic>{
            'msg_uuid': 'm2',
            'text': '普通文本',
            'direction': 'out',
            'state': 'sent',
          },
        ],
        conversationId: 'dm:x|y',
        isGroup: false,
        selfAccount: 'self',
      );
      expect(messages.first.mentions, isEmpty);
      expect(messages.first.edited, isFalse);
      expect(messages.first.editedAt, 0);
    });

    test('ChatMessage copyWith / withId 保留 mentions 与编辑字段', () {
      final ChatMessage m = ChatMessage(
        id: 'm',
        conversationId: 'group:g',
        text: 'hi',
        sentAt: DateTime(2026),
        mentions: const <String>['bob'],
        edited: true,
        editedAt: 42,
      );
      expect(m.copyWith(text: 'edited').mentions, <String>['bob']);
      expect(m.copyWith(text: 'edited').edited, isTrue);
      expect(m.withId('m2').editedAt, 42);
      expect(m.withId('m2').mentions, <String>['bob']);
    });

    test('ChatStore.updateEdited 更新正文并标记已编辑', () {
      final ChatStore store = ChatStore(conversationId: 'dm:x|y');
      store.receive(ChatMessage(
        id: 'm',
        conversationId: 'dm:x|y',
        text: '原文',
        sentAt: DateTime(2026),
      ));
      store.updateEdited('m', '新正文', 1234);
      final ChatMessage updated = store.byId('m')!;
      expect(updated.text, '新正文');
      expect(updated.edited, isTrue);
      expect(updated.editedAt, 1234);
    });

    test('ChatStore.setTyping 变更状态且去重', () {
      final ChatStore store = ChatStore(conversationId: 'dm:x|y');
      int notifications = 0;
      store.addListener(() => notifications++);
      expect(store.typing, isFalse);
      store.setTyping(true);
      expect(store.typing, isTrue);
      final int afterFirst = notifications;
      store.setTyping(true);
      expect(notifications, afterFirst, reason: '状态未变不应重复通知');
      store.setTyping(false);
      expect(store.typing, isFalse);
    });

    test('ChatStore.send 透传 mentions 到 sender', () async {
      List<String>? capturedMentions;
      final ChatStore store = ChatStore(
        conversationId: 'group:g',
        isGroup: true,
        sender: _RecordingSender((List<String>? m) => capturedMentions = m),
      );
      await store.send('@bob hi', mentions: const <String>['bob-pub']);
      expect(capturedMentions, <String>['bob-pub']);
      expect(store.byId(store.messages.first.id)!.mentions, <String>['bob-pub']);
    });
  });

  group('七-4 定时消息（阅后即焚）数据层', () {
    test('messagesFromItems 解析 expires_at 并识别定时消息', () {
      final List<ChatMessage> messages = messagesFromItems(
        <dynamic>[
          <String, dynamic>{
            'msg_uuid': 'm1',
            'text': '阅后即焚',
            'sent_at': 1730000000000,
            'direction': 'in',
            'state': 'received',
            'expires_at': 1730000000000 + 3600000,
          },
        ],
        conversationId: 'dm:x|y',
        isGroup: false,
        selfAccount: 'self',
      );
      expect(messages, hasLength(1));
      expect(messages.first.expiresAt, 1730000000000 + 3600000);
      expect(messages.first.isEphemeral, isTrue);
    });

    test('无 expires_at 时按普通消息处理', () {
      final List<ChatMessage> messages = messagesFromItems(
        <dynamic>[
          <String, dynamic>{
            'msg_uuid': 'm2',
            'text': '普通',
            'direction': 'out',
            'state': 'sent',
          },
        ],
        conversationId: 'dm:x|y',
        isGroup: false,
        selfAccount: 'self',
      );
      expect(messages.first.expiresAt, 0);
      expect(messages.first.isEphemeral, isFalse);
    });

    test('ChatMessage copyWith / withId 保留 expiresAt', () {
      final ChatMessage m = ChatMessage(
        id: 'm',
        conversationId: 'dm:x|y',
        text: 'hi',
        sentAt: DateTime(2026),
        expiresAt: 123456,
      );
      expect(m.copyWith(text: 'x').expiresAt, 123456);
      expect(m.withId('m2').expiresAt, 123456);
    });

    test('ChatStore.send 按 ttlHours 计算乐观 expiresAt 并透传', () async {
      int capturedTtl = -1;
      final ChatStore store = ChatStore(
        conversationId: 'dm:x|y',
        sender: _TtlRecordingSender((int t) => capturedTtl = t),
      );
      final DateTime at = DateTime(2026, 1, 1, 12);
      await store.send('定时', at: at, ttlHours: 24);
      expect(capturedTtl, 24);
      final ChatMessage sent = store.messages.first;
      expect(sent.expiresAt, at.add(const Duration(days: 1)).millisecondsSinceEpoch);
      expect(sent.isEphemeral, isTrue);
    });

    test('普通消息 ttlHours=0 不设置 expiresAt', () async {
      int capturedTtl = -1;
      final ChatStore store = ChatStore(
        conversationId: 'dm:x|y',
        sender: _TtlRecordingSender((int t) => capturedTtl = t),
      );
      await store.send('普通');
      expect(capturedTtl, 0);
      expect(store.messages.first.expiresAt, 0);
    });

    test('formatExpiryRemaining 按剩余时间给出正确文案', () {
      final DateTime now = DateTime(2026, 1, 1, 12);
      expect(
        formatExpiryRemaining(0, now: now),
        '',
      );
      expect(
        formatExpiryRemaining(now.add(const Duration(days: 2)).millisecondsSinceEpoch, now: now),
        '2 天后销毁',
      );
      expect(
        formatExpiryRemaining(now.add(const Duration(hours: 3)).millisecondsSinceEpoch, now: now),
        '3 小时后销毁',
      );
      expect(
        formatExpiryRemaining(now.add(const Duration(minutes: 5)).millisecondsSinceEpoch, now: now),
        '5 分钟后销毁',
      );
      expect(
        formatExpiryRemaining(now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch, now: now),
        '已到期',
      );
    });

    test('ephemeralTtlOptions / ephemeralTtlLabel 覆盖契约范围', () {
      expect(ephemeralTtlOptions, <int>[0, 1, 24, 168]);
      expect(ephemeralTtlLabel(0), '关闭');
      expect(ephemeralTtlLabel(1), '1 小时');
      expect(ephemeralTtlLabel(168), '7 天');
    });
  });
}

class _TtlRecordingSender implements ChatSender {
  _TtlRecordingSender(this.onTtl);

  final void Function(int ttl) onTtl;

  @override
  Future<String> sendText({
    required String conversationId,
    required String msgUuid,
    required String text,
    String? replyTo,
    List<String>? mentions,
    int ttlHours = 0,
  }) async {
    onTtl(ttlHours);
    return msgUuid;
  }

  @override
  Future<String> editMessage({
    required String conversationId,
    required String msgUuid,
    required String text,
  }) async =>
      msgUuid;

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
  }) async =>
      msgUuid;
}

class _RecordingSender implements ChatSender {
  _RecordingSender(this.onMentions);

  final void Function(List<String>? mentions) onMentions;

  @override
  Future<String> sendText({
    required String conversationId,
    required String msgUuid,
    required String text,
    String? replyTo,
    List<String>? mentions,
    int ttlHours = 0,
  }) async {
    onMentions(mentions);
    return msgUuid;
  }

  @override
  Future<String> editMessage({
    required String conversationId,
    required String msgUuid,
    required String text,
  }) async =>
      msgUuid;

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
  }) async =>
      msgUuid;
}
