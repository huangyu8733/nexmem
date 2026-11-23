// P1-22 验收：conversation.list 数据源映射、peer 反解与错误透传。
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/chats/conversation_service.dart';
import 'package:nexmem_app/transport/transport.dart';

class _RecordingTransport implements CoreTransport {
  final List<String> methods = <String>[];
  Map<String, dynamic>? lastParams;
  Map<String, dynamic> response = <String, dynamic>{};
  NexmemException? error;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    methods.add(method);
    lastParams = params;
    if (error != null) {
      throw error!;
    }
    return response;
  }

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

void main() {
  test('conversationFromJson 映射单聊条目与 peer', () {
    final ConversationItem item = conversationFromJson(<String, dynamic>{
      'conversation_id': 'dm:01|02',
      'kind': 'dm',
      'title': '张三',
      'unread': 3,
      'last_msg_at': 1730000000000,
      'last_text': '在吗',
      'last_direction': 'in',
      'peer': 'AQID',
    });
    expect(item.id, 'dm:01|02');
    expect(item.title, '张三');
    expect(item.unread, 3);
    expect(item.lastMessage, '在吗');
    expect(item.lastMessageAt!.millisecondsSinceEpoch, 1730000000000);
    expect(item.isGroup, isFalse);
    expect(item.peer, 'AQID');
  });

  test('conversationFromJson 映射群聊条目且 peer 为空', () {
    final ConversationItem item = conversationFromJson(<String, dynamic>{
      'conversation_id': 'group:Z3JvdXAx',
      'kind': 'group',
      'title': '研发群',
      'unread': 0,
      'group_id': 'Z3JvdXAx',
    });
    expect(item.isGroup, isTrue);
    expect(item.title, '研发群');
    expect(item.peer, isEmpty);
    expect(item.lastMessageAt, isNull);
    expect(item.lastMessage, isEmpty);
  });

  test('缺少 conversation_id 时抛 FormatException', () {
    expect(
      () => conversationFromJson(<String, dynamic>{'title': 'x'}),
      throwsFormatException,
    );
  });

  test('TransportConversationService 调用 conversation.list 并映射结果', () async {
    final _RecordingTransport transport = _RecordingTransport()
      ..response = <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'conversation_id': 'dm:aa|bb',
            'kind': 'dm',
            'title': '李四',
            'unread': 1,
            'last_msg_at': 1000,
            'last_text': '你好',
            'peer': 'bb',
          },
        ],
        'has_more': false,
      };
    final ConversationService service = TransportConversationService(transport);
    final List<ConversationItem> items = await service.list(limit: 10);
    expect(transport.methods, <String>['conversation.list']);
    expect(transport.lastParams, <String, dynamic>{'limit': 10});
    expect(items, hasLength(1));
    expect(items.single.title, '李四');
    expect(items.single.peer, 'bb');
  });

  test('TransportConversationService 调用 conversation.delete', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final ConversationService service = TransportConversationService(transport);

    await service.delete('dm:aa|bb');

    expect(transport.methods, <String>['conversation.delete']);
    expect(transport.lastParams, <String, dynamic>{
      'conversation_id': 'dm:aa|bb',
    });
  });

  test('TransportConversationService 调用 conversation.clear', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final ConversationService service = TransportConversationService(transport);

    await service.clear('dm:aa|bb');

    expect(transport.methods, <String>['conversation.clear']);
    expect(transport.lastParams, <String, dynamic>{
      'conversation_id': 'dm:aa|bb',
    });
  });

  test('TransportConversationService 调用 conversation.update', () async {
    final _RecordingTransport transport = _RecordingTransport();
    final ConversationService service = TransportConversationService(transport);

    await service.updateFlags('dm:aa|bb', pinned: true);
    expect(transport.methods, <String>['conversation.update']);
    expect(transport.lastParams, <String, dynamic>{
      'conversation_id': 'dm:aa|bb',
      'pinned': true,
    });

    await service.updateFlags('dm:aa|bb', muted: false);
    expect(transport.lastParams, <String, dynamic>{
      'conversation_id': 'dm:aa|bb',
      'muted': false,
    });
  });

  test('conversationFromJson 映射置顶与免打扰标记', () {
    final ConversationItem item = conversationFromJson(<String, dynamic>{
      'conversation_id': 'dm:aa|bb',
      'kind': 'dm',
      'title': '李四',
      'pinned': true,
      'muted': true,
    });
    expect(item.pinned, isTrue);
    expect(item.muted, isTrue);
  });

  test('TransportConversationService 透传内核错误码', () async {
    final _RecordingTransport transport = _RecordingTransport()
      ..error = const NexmemException('NOT_STARTED', '内核尚未启动');
    final ConversationService service = TransportConversationService(transport);
    await expectLater(
      service.list(),
      throwsA(
        isA<NexmemException>().having(
          (NexmemException e) => e.code,
          'code',
          'NOT_STARTED',
        ),
      ),
    );
  });
}
