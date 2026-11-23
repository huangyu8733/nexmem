/// 聊天消息模型与时间分隔规则（ui-spec.md §3）。
///
/// 字段对齐 Go 内核 `store.Message`：`msg_uuid` 作为 [id]，`sent_at` 为毫秒
/// 时间戳换算的本地时间；`state` 映射为 [MessageStatus]。
library;

enum MessageStatus {
  /// 发送中（气泡旁转圈）。
  sending,

  /// 已发送（单勾，内核已受理入队）。
  sent,

  /// 已送达（双勾灰）。
  delivered,

  /// 已读（双勾主色）。
  read,

  /// 发送失败（红色感叹号，可点击重发）。
  failed,
}

/// 文件附件元数据，对应内核消息里的 `attachments[0]`。
///
/// [path] 是本机绝对路径：发送端为待发送文件，接收端为内核落盘位置；
/// 平台不支持或元数据缺失时为空串。
class ChatAttachment {
  const ChatAttachment({
    required this.name,
    required this.size,
    this.mime = '',
    this.path = '',
  });

  /// 展示用文件名。
  final String name;

  /// 文件字节数。
  final int size;

  /// MIME 类型，未知时为空串。
  final String mime;

  /// 本机绝对路径。
  final String path;

  /// 是否为可直接预览的图片附件（按 MIME 或扩展名判定）。
  bool get isImage => isImageAttachment(name: name, mime: mime);

  /// 是否为语音/音频附件（A-01，按 MIME 或扩展名判定）。
  bool get isAudio => isAudioAttachment(name: name, mime: mime);

  ChatAttachment copyWith({String? name, int? size, String? mime, String? path}) {
    return ChatAttachment(
      name: name ?? this.name,
      size: size ?? this.size,
      mime: mime ?? this.mime,
      path: path ?? this.path,
    );
  }
}

/// 可内联预览的图片扩展名。
const List<String> imageFileExtensions = <String>[
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'heic',
];

/// 图片扩展名到 MIME 的映射，用于发送前补齐附件 MIME。
const Map<String, String> _imageMimeByExtension = <String, String>{
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
};

/// 音频扩展名到 MIME 的映射（A-01 语音消息发送，复用文件通道）。
const Map<String, String> _audioMimeByExtension = <String, String>{
  'm4a': 'audio/mp4',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'opus': 'audio/opus',
  'flac': 'audio/flac',
  'amr': 'audio/amr',
  '3gp': 'audio/3gpp',
};

String _extensionOf(String name) {
  final String lower = name.toLowerCase();
  final int dot = lower.lastIndexOf('.');
  return dot < 0 ? '' : lower.substring(dot + 1);
}

/// 按 MIME 或扩展名判定图片附件（P6-16）。
bool isImageAttachment({required String name, String mime = ''}) {
  if (mime.toLowerCase().startsWith('image/')) {
    return true;
  }
  return imageFileExtensions.contains(_extensionOf(name));
}

/// 按扩展名推断图片 MIME；非图片返回空串。
String imageMimeFor(String name) {
  return _imageMimeByExtension[_extensionOf(name)] ?? '';
}

/// 按 MIME 或扩展名判定语音/音频附件（A-01）。
bool isAudioAttachment({required String name, String mime = ''}) {
  if (mime.toLowerCase().startsWith('audio/')) {
    return true;
  }
  return _audioMimeByExtension.containsKey(_extensionOf(name));
}

/// 按扩展名推断音频 MIME；非音频返回空串。
String audioMimeFor(String name) {
  return _audioMimeByExtension[_extensionOf(name)] ?? '';
}

/// 人类可读的文件大小：`B` / `KB` / `MB` / `GB`（保留一位小数）。
String formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.text,
    required this.sentAt,
    this.senderId = '',
    this.senderName = '',
    this.isMine = false,
    this.isGroup = false,
    this.status = MessageStatus.sent,
    this.attachment,
    this.transferDone = 0,
    this.transferTotal = 0,
    this.seq = 0,
    this.replyTo = '',
    this.mentions = const <String>[],
    this.edited = false,
    this.editedAt = 0,
    this.expiresAt = 0,
  });

  /// 消息唯一 ID，对应内核 `msg_uuid`。
  final String id;
  final String conversationId;
  final String text;

  /// 发送时间（本地时区）。
  final DateTime sentAt;
  final String senderId;
  final String senderName;

  /// 自己发送的消息靠右显示。
  final bool isMine;
  final bool isGroup;
  final MessageStatus status;

  /// 文件消息的附件元数据；文本消息为 null。
  final ChatAttachment? attachment;

  /// 文件传输进度（字节）：由 `transfer.progress` 事件推进。
  final int transferDone;
  final int transferTotal;

  /// 内核本机事件序号，来自 `msg.list` / `msg.listSince` 的 `seq`。
  ///
  /// 0 表示来源未提供（如乐观插入的消息），不可作为 `after_seq` 游标。
  final int seq;

  /// 被引用消息的 `msg_uuid`；空串表示不是引用消息（P6-32）。
  final String replyTo;

  /// 被 @ 的成员账号 ID 列表（七-1 @成员），用于气泡内高亮渲染。
  final List<String> mentions;

  /// 消息是否被编辑过（七-2）；[editedAt] 为编辑时间（毫秒）。
  final bool edited;
  final int editedAt;

  /// 定时消息的本机销毁时间（Unix 毫秒）；0 表示永不过期。
  /// 由内核按正文 ttl_hours 计算并随 msg.list 返回，客户端仅展示倒计时。
  final int expiresAt;

  /// 是否为定时消息。
  bool get isEphemeral => expiresAt > 0;

  bool get isFile => attachment != null;

  /// 传输进度比例；未知总量时返回 null。
  double? get transferRatio {
    if (transferTotal <= 0) {
      return null;
    }
    return (transferDone / transferTotal).clamp(0.0, 1.0);
  }

  /// 换成内核返回的 `msg_uuid`：乐观入列的本地 ID 与内核 ID 不一致时用。
  ChatMessage withId(String newId) {
    return ChatMessage(
      id: newId,
      conversationId: conversationId,
      text: text,
      sentAt: sentAt,
      senderId: senderId,
      senderName: senderName,
      isMine: isMine,
      isGroup: isGroup,
      status: status,
      attachment: attachment,
      transferDone: transferDone,
      transferTotal: transferTotal,
      seq: seq,
      replyTo: replyTo,
      mentions: mentions,
      edited: edited,
      editedAt: editedAt,
      expiresAt: expiresAt,
    );
  }

  ChatMessage copyWith({
    String? text,
    DateTime? sentAt,
    String? senderId,
    String? senderName,
    bool? isMine,
    bool? isGroup,
    MessageStatus? status,
    ChatAttachment? attachment,
    int? transferDone,
    int? transferTotal,
    int? seq,
    String? replyTo,
    List<String>? mentions,
    bool? edited,
    int? editedAt,
    int? expiresAt,
  }) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      text: text ?? this.text,
      sentAt: sentAt ?? this.sentAt,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      isMine: isMine ?? this.isMine,
      isGroup: isGroup ?? this.isGroup,
      status: status ?? this.status,
      attachment: attachment ?? this.attachment,
      transferDone: transferDone ?? this.transferDone,
      transferTotal: transferTotal ?? this.transferTotal,
      seq: seq ?? this.seq,
      replyTo: replyTo ?? this.replyTo,
      mentions: mentions ?? this.mentions,
      edited: edited ?? this.edited,
      editedAt: editedAt ?? this.editedAt,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }
}

/// 相邻消息间隔超过 5 分钟时插入时间分隔条（ui-spec.md §3）。
const Duration messageTimeGap = Duration(minutes: 5);

bool shouldShowTimeSeparator(DateTime? previous, DateTime current) {
  if (previous == null) {
    return true;
  }
  return current.difference(previous).abs() >= messageTimeGap;
}

/// 消息区分隔条文案：今天 `HH:mm`、昨天 `昨天 HH:mm`、更早 `yyyy/MM/dd HH:mm`。
String formatMessageTime(DateTime time, {DateTime? now}) {
  final DateTime ref = now ?? DateTime.now();
  final DateTime today = DateTime(ref.year, ref.month, ref.day);
  final DateTime thatDay = DateTime(time.year, time.month, time.day);
  final int days = today.difference(thatDay).inDays;
  final String hhmm =
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  if (days <= 0) {
    return hhmm;
  }
  if (days == 1) {
    return '昨天 $hhmm';
  }
  final String mm = time.month.toString().padLeft(2, '0');
  final String dd = time.day.toString().padLeft(2, '0');
  return '${time.year}/$mm/$dd $hhmm';
}

/// 气泡右下角的短时间，仅显示 `HH:mm`。
String formatBubbleTime(DateTime time) {
  return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

/// 定时消息可选的存活时长（小时）：0 表示关闭；其余为 1 小时～7 天。
/// 与内核 `expiry.MinHours/MaxHours` 与契约 `ttl_hours` 范围一致。
const List<int> ephemeralTtlOptions = <int>[0, 1, 24, 168];

/// TTL 选项的人类可读标签，索引与 [ephemeralTtlOptions] 一一对应。
String ephemeralTtlLabel(int hours) {
  return switch (hours) {
    0 => '关闭',
    1 => '1 小时',
    24 => '1 天',
    168 => '7 天',
    _ => '$hours 小时',
  };
}

/// 定时消息气泡上的剩余时间文案：`expiresAt` 为 Unix 毫秒，0 表示永不过期。
/// 剩余不足 1 分钟显示「即将销毁」，超过 1 天显示「X 天后销毁」。
String formatExpiryRemaining(int expiresAt, {DateTime? now}) {
  if (expiresAt <= 0) {
    return '';
  }
  final int nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final int remainingMs = expiresAt - nowMs;
  if (remainingMs <= 0) {
    return '已到期';
  }
  final Duration remaining = Duration(milliseconds: remainingMs);
  if (remaining.inDays >= 1) {
    return '${remaining.inDays} 天后销毁';
  }
  if (remaining.inHours >= 1) {
    return '${remaining.inHours} 小时后销毁';
  }
  if (remaining.inMinutes >= 1) {
    return '${remaining.inMinutes} 分钟后销毁';
  }
  return '即将销毁';
}
