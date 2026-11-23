import '../../transport/transport.dart';
import 'conversation.dart';

/// 会话列表数据源（P1-22）：由 `conversation.list` 提供首屏数据，
/// 后续增量由 `message.new` / `conversation.changed` 事件驱动。
abstract class ConversationService {
  /// 拉取会话首页；失败抛 [NexmemException]。
  Future<List<ConversationItem>> list({int limit = 50});

  /// 删除本地会话条目（历史消息保留）；失败抛 [NexmemException]。
  Future<void> delete(String conversationId);

  /// 清空会话本机历史与检索索引（会话保留）；失败抛 [NexmemException]。
  Future<void> clear(String conversationId);

  /// 设置本机会话标记（P6-17）：置顶影响列表排序，免打扰只改本机展示。
  Future<void> updateFlags(
    String conversationId, {
    bool? pinned,
    bool? muted,
  });
}

/// 把 `conversation.list` 的单个条目映射为 [ConversationItem]。
///
/// 单聊条目的 [ConversationItem.peer] 直接来自内核反解结果，客户端无需
/// 解析 `dm:<hex>|<hex>` 形式的会话 ID；群聊以 `group_id` 为准。
ConversationItem conversationFromJson(Map<String, dynamic> json) {
  final Object? id = json['conversation_id'];
  if (id is! String || id.isEmpty) {
    throw const FormatException('会话条目缺少 conversation_id');
  }
  final Object? title = json['title'];
  final Object? unread = json['unread'];
  final Object? lastAt = json['last_msg_at'];
  final Object? lastText = json['last_text'];
  final Object? peer = json['peer'];
  final Object? kind = json['kind'];
  return ConversationItem(
    id: id,
    title: title is String ? title : '',
    lastMessage: lastText is String ? lastText : '',
    lastMessageAt:
        lastAt is num ? DateTime.fromMillisecondsSinceEpoch(lastAt.toInt()) : null,
    unread: unread is num ? unread.toInt() : 0,
    isGroup: kind == 'group',
    peer: peer is String ? peer : '',
    pinned: json['pinned'] == true,
    muted: json['muted'] == true,
  );
}

/// 经统一的 [CoreTransport] 调用内核 `conversation.list`。
class TransportConversationService implements ConversationService {
  const TransportConversationService(this.transport);

  final CoreTransport transport;

  @override
  Future<List<ConversationItem>> list({int limit = 50}) async {
    final Map<String, dynamic> data = await transport.call(
      'conversation.list',
      params: <String, dynamic>{'limit': limit},
    );
    final Object? items = data['items'];
    if (items is! List) {
      return const <ConversationItem>[];
    }
    final List<ConversationItem> out = <ConversationItem>[];
    for (final Object? item in items) {
      if (item is Map<String, dynamic>) {
        out.add(conversationFromJson(item));
      }
    }
    return out;
  }

  @override
  Future<void> delete(String conversationId) async {
    await transport.call(
      'conversation.delete',
      params: <String, dynamic>{'conversation_id': conversationId},
    );
  }

  @override
  Future<void> clear(String conversationId) async {
    await transport.call(
      'conversation.clear',
      params: <String, dynamic>{'conversation_id': conversationId},
    );
  }

  @override
  Future<void> updateFlags(
    String conversationId, {
    bool? pinned,
    bool? muted,
  }) async {
    final Map<String, dynamic> params = <String, dynamic>{
      'conversation_id': conversationId,
    };
    if (pinned != null) {
      params['pinned'] = pinned;
    }
    if (muted != null) {
      params['muted'] = muted;
    }
    await transport.call('conversation.update', params: params);
  }
}

/// 内核未接通时的占位实现：明确抛 `NOT_STARTED`，便于 UI 展示空态而非假数据。
class UnavailableConversationService implements ConversationService {
  const UnavailableConversationService();

  @override
  Future<List<ConversationItem>> list({int limit = 50}) {
    throw const NexmemException('NOT_STARTED', '会话列表服务尚未接入内核');
  }

  @override
  Future<void> delete(String conversationId) {
    throw const NexmemException('NOT_STARTED', '会话列表服务尚未接入内核');
  }

  @override
  Future<void> clear(String conversationId) {
    throw const NexmemException('NOT_STARTED', '会话列表服务尚未接入内核');
  }

  @override
  Future<void> updateFlags(
    String conversationId, {
    bool? pinned,
    bool? muted,
  }) {
    throw const NexmemException('NOT_STARTED', '会话列表服务尚未接入内核');
  }
}
