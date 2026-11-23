/// 会话列表条目模型（ui-spec.md §2）。
///
/// 字段对齐 Go 内核 `store.Conversation`，另加 UI 展示所需的摘要、置顶、
/// 在线状态等扩展字段；真实数据由内核经传输层推送（P1-16 / core.start）。
library;

/// 对端连通状态，用于头像右下角状态点。
enum PresenceStatus { online, relay, offline }

class ConversationItem {
  const ConversationItem({
    required this.id,
    required this.title,
    this.lastMessage = '',
    this.lastMessageAt,
    this.unread = 0,
    this.pinned = false,
    this.muted = false,
    this.failed = false,
    this.isGroup = false,
    this.presence = PresenceStatus.offline,
    this.peer = '',
  });

  /// 会话 ID（单聊为账号公钥 base64url，群聊为群 ID）。
  final String id;
  final String title;
  final String lastMessage;
  final DateTime? lastMessageAt;
  final int unread;
  final bool pinned;
  final bool muted;
  final bool failed;
  final bool isGroup;
  final PresenceStatus presence;

  /// 单聊对端账号 ID（base64url），由 `conversation.list` 给出，可直接用于
  /// `dm.sendText` 的 `peer`；群聊为空串。
  final String peer;

  ConversationItem copyWith({
    String? title,
    String? lastMessage,
    DateTime? lastMessageAt,
    int? unread,
    bool? pinned,
    bool? muted,
    bool? failed,
    bool? isGroup,
    PresenceStatus? presence,
    String? peer,
  }) {
    return ConversationItem(
      id: id,
      title: title ?? this.title,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unread: unread ?? this.unread,
      pinned: pinned ?? this.pinned,
      muted: muted ?? this.muted,
      failed: failed ?? this.failed,
      isGroup: isGroup ?? this.isGroup,
      presence: presence ?? this.presence,
      peer: peer ?? this.peer,
    );
  }
}

/// 会话时间戳格式化：今天 `HH:mm`、昨天、最近一周 `周X`、更早 `yyyy/MM/dd`。
String formatConversationTime(DateTime time, {DateTime? now}) {
  final DateTime ref = now ?? DateTime.now();
  final DateTime today = DateTime(ref.year, ref.month, ref.day);
  final DateTime thatDay = DateTime(time.year, time.month, time.day);
  final int days = today.difference(thatDay).inDays;
  if (days <= 0) {
    final String hh = time.hour.toString().padLeft(2, '0');
    final String mm = time.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
  if (days == 1) {
    return '昨天';
  }
  if (days < 7) {
    const List<String> weekdays = <String>['一', '二', '三', '四', '五', '六', '日'];
    return '周${weekdays[time.weekday - 1]}';
  }
  final String mm = time.month.toString().padLeft(2, '0');
  final String dd = time.day.toString().padLeft(2, '0');
  return '${time.year}/$mm/$dd';
}
