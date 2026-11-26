import 'package:material_ui/material_ui.dart';

import '../contacts/contact_service.dart';
import 'conversation.dart';

/// 会话列表数据源与排序规则（ui-spec.md §2）。
///
/// 当前由 UI 层持有内存状态；P1-16 传输层接通后由内核事件驱动
/// [receive] / [markRead] / [setPinned]，页面无需改动。
class ConversationStore extends ChangeNotifier {
  ConversationStore({
    Iterable<ConversationItem> initial = const <ConversationItem>[],
  }) {
    for (final ConversationItem item in initial) {
      _items[item.id] = item;
    }
  }

  final Map<String, ConversationItem> _items = <String, ConversationItem>{};

  /// 置顶优先，其余按最后消息时间倒序，时间相同按 ID 稳定排序。
  List<ConversationItem> get sorted {
    final List<ConversationItem> list = _items.values.toList();
    list.sort((ConversationItem a, ConversationItem b) {
      if (a.pinned != b.pinned) {
        return a.pinned ? -1 : 1;
      }
      final DateTime? at = a.lastMessageAt;
      final DateTime? bt = b.lastMessageAt;
      if (at == null && bt != null) {
        return 1;
      }
      if (at != null && bt == null) {
        return -1;
      }
      if (at != null && bt != null) {
        final int byTime = bt.compareTo(at);
        if (byTime != 0) {
          return byTime;
        }
      }
      return a.id.compareTo(b.id);
    });
    return list;
  }

  /// 全部会话未读之和，供 Tab 角标使用。
  int get totalUnread => _items.values.fold<int>(
    0,
    (int sum, ConversationItem item) => sum + item.unread,
  );

  ConversationItem? byId(String id) => _items[id];

  /// 按对端账号查找单聊会话（七-3 typing 事件按 peer 定位会话）。
  ConversationItem? byPeer(String peer) {
    for (final ConversationItem item in _items.values) {
      if (!item.isGroup && item.peer == peer) {
        return item;
      }
    }
    return null;
  }

  void upsert(ConversationItem item) {
    _items[item.id] = item;
    notifyListeners();
  }

  /// 收到新消息：刷新摘要与时间、未读 +1，并按排序规则自动上浮。
  ///
  /// 会话不存在时忽略，避免 UI 生成与内核不一致的标题。
  void receive(String id, String text, {DateTime? at}) {
    final ConversationItem? current = _items[id];
    if (current == null) {
      return;
    }
    _items[id] = current.copyWith(
      lastMessage: text,
      lastMessageAt: at ?? DateTime.now(),
      unread: current.unread + 1,
    );
    notifyListeners();
  }

  /// 本地发送成功后刷新摘要与时间，不改变未读（自己发的消息不算未读）。
  void touch(String id, String text, {DateTime? at}) {
    final ConversationItem? current = _items[id];
    if (current == null) {
      return;
    }
    _items[id] = current.copyWith(
      lastMessage: text,
      lastMessageAt: at ?? DateTime.now(),
    );
    notifyListeners();
  }

  void markRead(String id) {
    final ConversationItem? current = _items[id];
    if (current == null || current.unread == 0) {
      return;
    }
    _items[id] = current.copyWith(unread: 0);
    notifyListeners();
  }

  /// 清空本机历史后同步列表：摘要置空、未读归零，会话仍留在列表（P6-13）。
  void clearMessages(String id) {
    final ConversationItem? current = _items[id];
    if (current == null) {
      return;
    }
    if (current.lastMessage.isEmpty && current.unread == 0) {
      return;
    }
    _items[id] = current.copyWith(lastMessage: '', unread: 0);
    notifyListeners();
  }

  void setPinned(String id, bool pinned) {
    final ConversationItem? current = _items[id];
    if (current == null || current.pinned == pinned) {
      return;
    }
    _items[id] = current.copyWith(pinned: pinned);
    notifyListeners();
  }

  /// 免打扰标记（P6-17）：只影响本机未读角标样式，不改变未读数。
  void setMuted(String id, bool muted) {
    final ConversationItem? current = _items[id];
    if (current == null || current.muted == muted) {
      return;
    }
    _items[id] = current.copyWith(muted: muted);
    notifyListeners();
  }

  /// 应用在线状态：key 支持对端 base64url 或十六进制账号，仅变化时通知。
  void applyPresence(Map<String, PresenceStatus> byPeer) {
    bool changed = false;
    for (final ConversationItem item in _items.values.toList()) {
      if (item.isGroup || item.peer.isEmpty) {
        continue;
      }
      final PresenceStatus? status =
          byPeer[item.peer] ?? byPeer[normalizeAccountHex(item.peer)];
      if (status == null || status == item.presence) {
        continue;
      }
      _items[item.id] = item.copyWith(presence: status);
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }

  void remove(String id) {
    if (_items.remove(id) != null) {
      notifyListeners();
    }
  }
}
