import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../../transport/transport.dart';
import '../group/group_storage.dart';
import 'chat_message.dart';

/// 对端未开启离线存储时内核返回的固定错误码（见 gateway/errors.go）。
const String offlineStorageDisabledCode = 'OFFLINE_STORAGE_DISABLED';

/// 文本发送通道：由 P1-16 传输层在 `core.start` 接通后注入。
///
/// 返回内核分配的 `msg_uuid`；未注入时 [ChatStore] 只做本地置位（乐观显示
/// 单勾），不产生跨端投递。
abstract class ChatSender {
  Future<String> sendText({
    required String conversationId,
    required String msgUuid,
    required String text,
    String? replyTo,
    List<String>? mentions,
    int ttlHours = 0,
  });

  /// 编辑自己发出的消息正文（七-2）。返回内核回显的 msg_uuid。
  Future<String> editMessage({
    required String conversationId,
    required String msgUuid,
    required String text,
  });

  /// 向对端发送单聊输入状态（七-3，瞬时、尽力而为）。
  Future<void> setTyping({
    required String conversationId,
    required bool typing,
  });

  /// 发送文件：`path` 必须是本机绝对路径，内核直接读文件流分片加密
  /// （契约 `dm.sendFile`，仅单聊）。
  Future<String> sendFile({
    required String conversationId,
    required String msgUuid,
    required String path,
    String mime = '',
  });
}

/// 单个会话的消息列表与发送状态机（ui-spec.md §3）。
///
/// 消息按 `sent_at` 升序保存，重复 ID 覆盖（幂等），失败可 [retry] 重发原
/// `msg_uuid`，重发由内核按 `msg_uuid` 去重，不会产生重复消息。
class ChatStore extends ChangeNotifier {
  ChatStore({
    required this.conversationId,
    this.isGroup = false,
    this.sender,
    this.peerOfflineStorageDisabled = false,
    this.groupStorage = GroupStorageStatus.unknown,
    Iterable<ChatMessage> initial = const <ChatMessage>[],
  }) {
    for (final ChatMessage message in initial) {
      _insert(message);
    }
  }

  final String conversationId;
  final bool isGroup;
  final ChatSender? sender;

  /// 对端是否正在输入（七-3 typing），由内核 typing 事件驱动，仅单聊有意义。
  bool _typing = false;
  bool get typing => _typing;

  /// 更新对端输入状态；状态未变化时不触发重绘。
  void setTyping(bool value) {
    if (_typing == value) {
      return;
    }
    _typing = value;
    notifyListeners();
  }

  /// 群盘配置状态：仅群聊有意义，由 `group.members` 返回的 `storage_configured` 驱动。
  ///
  /// 只读语义；外部变更请走 [setGroupStorageStatus] 以触发刷新。
  GroupStorageStatus groupStorage;

  /// 内核回传群资料后更新群盘状态；值变化时通知监听者。
  void setGroupStorageStatus(GroupStorageStatus status) {
    if (groupStorage == status) {
      return;
    }
    groupStorage = status;
    notifyListeners();
  }

  /// 对端未开启离线存储：UI 据此在输入区上方常驻「仅支持在线发送」提示。
  ///
  /// 只读语义；外部变更请走 [setPeerOfflineStorageDisabled] 以触发刷新。
  bool peerOfflineStorageDisabled;

  /// 由对端档案刷新或内核错误码驱动；值变化时通知监听者。
  void setPeerOfflineStorageDisabled(bool value) {
    if (peerOfflineStorageDisabled == value) {
      return;
    }
    peerOfflineStorageDisabled = value;
    notifyListeners();
  }

  /// 引用回复中（P6-32）：用户长按消息选「引用」后暂存的被引用消息。
  ///
  /// UI 状态放在 store 而非页面，使输入区与消息列表通过同一个
  /// ChangeNotifier 同步；发送成功后由调用方 [setQuoting] 传 null 清空。
  ChatMessage? _quoting;

  ChatMessage? get quoting => _quoting;

  void setQuoting(ChatMessage? message) {
    if (message?.id == _quoting?.id &&
        message?.text == _quoting?.text &&
        message?.replyTo == _quoting?.replyTo) {
      return;
    }
    _quoting = message;
    notifyListeners();
  }

  final List<ChatMessage> _messages = <ChatMessage>[];
  final Random _random = Random.secure();

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);

  int get length => _messages.length;

  bool get isEmpty => _messages.isEmpty;

  ChatMessage? byId(String id) {
    for (final ChatMessage message in _messages) {
      if (message.id == id) {
        return message;
      }
    }
    return null;
  }

  /// 发送文本：先以「发送中」入列，通道成功置「已发送」，异常置「失败」。
  Future<ChatMessage> send(
    String text, {
    String senderId = '',
    String senderName = '',
    DateTime? at,
    String? msgUuid,
    String? replyTo,
    List<String>? mentions,
    int ttlHours = 0,
  }) async {
    final String body = text.trim();
    if (body.isEmpty) {
      throw ArgumentError.value(text, 'text', '消息内容不能为空');
    }
    final DateTime sentAt = at ?? DateTime.now();
    final ChatMessage message = ChatMessage(
      id: msgUuid ?? newMsgUUID(),
      conversationId: conversationId,
      text: body,
      sentAt: sentAt,
      senderId: senderId,
      senderName: senderName,
      isMine: true,
      isGroup: isGroup,
      status: MessageStatus.sending,
      replyTo: replyTo?.trim() ?? '',
      mentions: mentions ?? const <String>[],
      // 乐观倒计时：内核落成后由 msg.list 的 expires_at 覆盖为权威值。
      expiresAt: ttlHours > 0
          ? sentAt.add(Duration(hours: ttlHours)).millisecondsSinceEpoch
          : 0,
    );
    _insert(message);
    notifyListeners();
    return _deliver(message);
  }

  /// 接收到一条消息（入站或本机其他端同步），按时间插入并去重。
  void receive(ChatMessage message) {
    _insert(message);
    notifyListeners();
  }

  /// 发送文件：先以「发送中」入列，通道成功置「已发送」，异常置「失败」。
  ///
  /// 消息正文用文件名占位，使会话摘要与检索同样可读；附件元数据用于气泡展示。
  Future<ChatMessage> sendFile(
    ChatAttachment file, {
    String senderId = '',
    String senderName = '',
    DateTime? at,
    String? msgUuid,
  }) async {
    if (file.path.trim().isEmpty) {
      throw ArgumentError.value(file, 'file', '文件缺少本机绝对路径');
    }
    // 图片按扩展名补齐 MIME，接收端据此内联预览（P6-16）。
    final String inferred = file.mime.isEmpty ? imageMimeFor(file.name) : '';
    final ChatAttachment attachment = inferred.isEmpty
        ? file
        : file.copyWith(mime: inferred);
    final ChatMessage message = ChatMessage(
      id: msgUuid ?? newMsgUUID(),
      conversationId: conversationId,
      text: file.name,
      sentAt: at ?? DateTime.now(),
      senderId: senderId,
      senderName: senderName,
      isMine: true,
      isGroup: isGroup,
      status: MessageStatus.sending,
      attachment: attachment,
    );
    _insert(message);
    notifyListeners();
    return _deliver(message);
  }

  /// 按 `transfer.progress` 事件推进文件传输进度（字节）。
  void setTransferProgress(String id, int done, int total) {
    final int index = _indexOf(id);
    if (index < 0) {
      return;
    }
    final ChatMessage message = _messages[index];
    if (!message.isFile ||
        (message.transferDone == done && message.transferTotal == total)) {
      return;
    }
    _messages[index] = message.copyWith(
      transferDone: done,
      transferTotal: total,
    );
    notifyListeners();
  }

  /// 事件驱动的刷新：已有消息只更新正文与时间，保留本地发送状态。
  ///
  /// 内核 `message.new` 只给指针，随后 `msg.list` 回包的状态可能滞后于
  /// 本地乐观置位，直接覆盖会把「已发送」退回「发送中」。
  void merge(ChatMessage message) {
    final int index = _indexOf(message.id);
    if (index < 0) {
      _insert(message);
    } else {
      final ChatMessage local = _messages[index];
      final bool sending = local.status == MessageStatus.sending;
      _messages[index] = message.copyWith(
        status: local.status,
        // 传输中的文件进度只由 transfer.progress 推进，避免回包把进度清零。
        transferDone: sending ? local.transferDone : message.transferDone,
        transferTotal: sending ? local.transferTotal : message.transferTotal,
      );
    }
    notifyListeners();
  }

  void updateStatus(String id, MessageStatus status) {
    final int index = _indexOf(id);
    if (index < 0 || _messages[index].status == status) {
      return;
    }
    _messages[index] = _messages[index].copyWith(status: status);
    notifyListeners();
  }

  /// 应用消息编辑（七-2）：更新正文并标记「已编辑」。
  void updateEdited(String id, String text, int editedAt) {
    final int index = _indexOf(id);
    if (index < 0) {
      return;
    }
    _messages[index] = _messages[index].copyWith(
      text: text,
      edited: true,
      editedAt: editedAt,
    );
    notifyListeners();
  }

  /// 重发失败消息，沿用原 `msg_uuid` 保证对端幂等。
  Future<void> retry(String id) async {
    final int index = _indexOf(id);
    if (index < 0) {
      return;
    }
    final ChatMessage failed = _messages[index];
    _messages[index] = failed.copyWith(status: MessageStatus.sending);
    notifyListeners();
    await _deliver(failed);
  }

  void remove(String id) {
    final int index = _indexOf(id);
    if (index < 0) {
      return;
    }
    _messages.removeAt(index);
    notifyListeners();
  }

  void clear() {
    if (_messages.isEmpty) {
      return;
    }
    _messages.clear();
    notifyListeners();
  }

  /// 从乐观消息的绝对销毁时间反推 TTL 小时数，供 [retry] 重发时复用。
  /// 发送路径已按整小时计算 expiresAt，这里取整小时；非定时消息返回 0。
  int _ttlHoursOf(ChatMessage message) {
    if (message.expiresAt <= 0) {
      return 0;
    }
    final int hours =
        (message.expiresAt - message.sentAt.millisecondsSinceEpoch) ~/ 3600000;
    return hours > 0 ? hours : 0;
  }

  /// 生成 16 字节随机 `msg_uuid`（hex），与内核 id 不冲突。
  String newMsgUUID() {
    final List<int> bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<ChatMessage> _deliver(ChatMessage message) async {
    final ChatSender? channel = sender;
    if (channel == null) {
      // 内核未接通：本地置位单勾，跨端投递由 P1-19 之后的 core.start 接入。
      _setStatus(message.id, MessageStatus.sent);
      return byId(message.id) ?? message;
    }
    String currentId = message.id;
    try {
      final ChatAttachment? file = message.attachment;
      final String kernelId = file != null
          ? await channel.sendFile(
              conversationId: conversationId,
              msgUuid: message.id,
              path: file.path,
              mime: file.mime,
            )
          : await channel.sendText(
              conversationId: conversationId,
              msgUuid: message.id,
              text: message.text,
              replyTo: message.replyTo.isEmpty ? null : message.replyTo,
              mentions: message.mentions.isEmpty ? null : message.mentions,
              ttlHours: message.expiresAt > 0
                  ? _ttlHoursOf(message)
                  : 0,
            );
      if (kernelId.isEmpty) {
        _setStatus(currentId, MessageStatus.sent);
      } else {
        _rename(currentId, kernelId);
        currentId = kernelId;
        _setStatus(currentId, MessageStatus.sent);
      }
    } on NexmemException catch (error) {
      // 对端未开启离线存储：该错误不可重试，转为常驻降级提示（P3-09）。
      if (error.code == offlineStorageDisabledCode) {
        setPeerOfflineStorageDisabled(true);
      }
      _setStatus(currentId, MessageStatus.failed);
    } catch (_) {
      _setStatus(currentId, MessageStatus.failed);
    }
    return byId(currentId) ?? message;
  }

  /// 用内核 `msg_uuid` 替换乐观入列的本地 ID，避免 `message.new` 事件再插一条。
  void _rename(String from, String to) {
    if (from == to) {
      return;
    }
    final int index = _indexOf(from);
    if (index < 0) {
      return;
    }
    if (_indexOf(to) >= 0) {
      _messages.removeAt(index);
      return;
    }
    _messages[index] = _messages[index].withId(to);
  }

  void _setStatus(String id, MessageStatus status) {
    final int index = _indexOf(id);
    if (index < 0 || _messages[index].status == status) {
      return;
    }
    _messages[index] = _messages[index].copyWith(status: status);
    notifyListeners();
  }

  int _indexOf(String id) {
    for (int i = 0; i < _messages.length; i++) {
      if (_messages[i].id == id) {
        return i;
      }
    }
    return -1;
  }

  /// 按 `sent_at` 升序插入；同 ID 覆盖，保证重复投递只留一条。
  void _insert(ChatMessage message) {
    final int existing = _indexOf(message.id);
    if (existing >= 0) {
      _messages[existing] = message;
      return;
    }
    int low = 0;
    int high = _messages.length;
    while (low < high) {
      final int mid = (low + high) >> 1;
      if (_messages[mid].sentAt.isAfter(message.sentAt)) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    _messages.insert(low, message);
  }
}
