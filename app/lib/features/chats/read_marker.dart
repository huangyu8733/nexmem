import '../../transport/transport.dart';

/// 已读推进通道：打开会话时把内核 `unread` 清零（P6-07）。
///
/// 由 `core.start` 接通后注入 [TransportReadMarker]；未接通时用无操作实现，
/// 本地未读仍由 `ConversationStore.markRead` 负责，不阻塞 UI。
abstract class ReadMarker {
  Future<void> markRead({
    required String conversationId,
    String upToId = '',
  });
}

/// 经统一的 [CoreTransport] 调用内核 `msg.markRead`。
class TransportReadMarker implements ReadMarker {
  const TransportReadMarker(this.transport);

  final CoreTransport transport;

  @override
  Future<void> markRead({
    required String conversationId,
    String upToId = '',
  }) async {
    await transport.call(
      'msg.markRead',
      params: <String, dynamic>{
        'conversation_id': conversationId,
        'up_to_id': upToId,
      },
    );
  }
}

/// 内核未接入时的无操作实现。
class UnavailableReadMarker implements ReadMarker {
  const UnavailableReadMarker();

  @override
  Future<void> markRead({
    required String conversationId,
    String upToId = '',
  }) async {}
}
