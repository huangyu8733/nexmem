import 'dart:convert';

import '../../transport/transport.dart';

/// QQ 式社交服务：好友申请、入群审批、通知、在线状态、动态与投票。
///
/// 所有方法走内核 `friend.* / group.join.* / notification.* / presence.* /
/// moment.* / poll.*` 契约。传输层只负责信封搬运，这里做模型解析与容错。
class SocialService {
  const SocialService(this._transport);

  final CoreTransport _transport;

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic> params = const <String, dynamic>{},
    Duration? timeout,
  ]) async {
    return _transport.call(method, params: params, timeout: timeout);
  }

  static int _int(Object? v, [int fallback = 0]) =>
      v is num ? v.toInt() : fallback;

  static String _str(Object? v, [String fallback = '']) =>
      v is String ? v : fallback;

  static bool _bool(Object? v) => v == true;

  static List<Map<String, dynamic>> _items(Object? v) => v is List
      ? v.whereType<Map<String, dynamic>>().toList()
      : <Map<String, dynamic>>[];

  // ---- 好友申请 ----

  Future<String> sendFriendRequest(String peer, {String message = ''}) async {
    final data = await _call('friend.request.send', <String, dynamic>{
      'peer': peer,
      'message': message,
    });
    return _str(data['id']);
  }

  Future<List<FriendRequest>> listFriendRequests({
    int? status,
    int limit = 100,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (status != null) params['status'] = status;
    final data = await _call('friend.request.list', params);
    return _items(data['items']).map(FriendRequest.fromJson).toList();
  }

  Future<void> respondFriendRequest(String id, bool accept) async {
    await _call('friend.request.respond', <String, dynamic>{
      'id': id,
      'accept': accept,
    });
  }

  /// 删除一条好友申请（仅本机记录），返回实际删除条数。
  Future<int> deleteFriendRequest(String id) async {
    final data = await _call('friend.request.delete', <String, dynamic>{
      'id': id,
    });
    return _int(data['deleted']);
  }

  /// 清空本机所有好友申请，返回实际删除条数。
  Future<int> clearFriendRequests() async {
    final data = await _call('friend.request.clear');
    return _int(data['deleted']);
  }

  Future<int> pendingFriendRequestCount() async {
    final data = await _call('friend.request.count');
    return _int(data['count']);
  }

  // ---- 入群审批 ----

  Future<String> requestGroupJoin(
    String groupId,
    String owner, {
    String groupTitle = '',
    String message = '',
  }) async {
    final data = await _call('group.join.request', <String, dynamic>{
      'group_id': groupId,
      'owner': owner,
      'group_title': groupTitle,
      'message': message,
    });
    return _str(data['id']);
  }

  Future<List<GroupJoinRequest>> listGroupJoinRequests({
    String? groupId,
    int? status,
    int limit = 100,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (groupId != null) params['group_id'] = groupId;
    if (status != null) params['status'] = status;
    final data = await _call('group.join.list', params);
    return _items(data['items']).map(GroupJoinRequest.fromJson).toList();
  }

  Future<void> respondGroupJoin(String id, bool accept) async {
    await _call('group.join.respond', <String, dynamic>{
      'id': id,
      'accept': accept,
    });
  }

  /// 删除一条入群申请（仅本机记录），返回实际删除条数。
  Future<int> deleteGroupJoinRequest(String id) async {
    final data = await _call('group.join.delete', <String, dynamic>{'id': id});
    return _int(data['deleted']);
  }

  /// 清空本机所有入群申请，返回实际删除条数。
  Future<int> clearGroupJoinRequests() async {
    final data = await _call('group.join.clear');
    return _int(data['deleted']);
  }

  Future<void> setMember(
    String groupId,
    String account, {
    String? role,
    String? title,
    int? muteMinutes,
  }) async {
    final params = <String, dynamic>{'group_id': groupId, 'account': account};
    if (role != null) params['role'] = role;
    if (title != null) params['title'] = title;
    if (muteMinutes != null) params['mute_minutes'] = muteMinutes;
    await _call('group.member.set', params);
  }

  // ---- 通知与在线状态 ----

  Future<NotificationList> listNotifications({
    int limit = 100,
    bool unreadOnly = false,
  }) async {
    final data = await _call('notification.list', <String, dynamic>{
      'limit': limit,
      'unread_only': unreadOnly,
    });
    return NotificationList(
      items: _items(data['items']).map(AppNotification.fromJson).toList(),
      unread: _int(data['unread']),
    );
  }

  Future<void> markNotificationRead({String? id}) async {
    final params = <String, dynamic>{};
    if (id != null) params['id'] = id;
    await _call('notification.read', params);
  }

  /// 删除一条通知，返回实际删除条数。
  Future<int> deleteNotification(String id) async {
    final data = await _call('notification.delete', <String, dynamic>{
      'id': id,
    });
    return _int(data['deleted']);
  }

  /// 清空全部通知，返回实际删除条数。
  Future<int> clearNotifications() async {
    final data = await _call('notification.clear');
    return _int(data['deleted']);
  }

  /// 查询账号在线状态；[accounts] 为十六进制账号公钥。
  ///
  /// 内核会并发探测每个账号，离线好友较多时也需要数秒，故默认放宽到 30s。
  Future<List<Presence>> listPresence(
    List<String> accounts, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final data = await _call('presence.list', <String, dynamic>{
      'accounts': accounts,
    }, timeout);
    return _items(data['items']).map(Presence.fromJson).toList();
  }

  // ---- 动态 ----

  Future<String> postMoment(
    String text, {
    String attachments = '',
    List<String> peers = const <String>[],
  }) async {
    final data = await _call('moment.post', <String, dynamic>{
      'text': text,
      'attachments': attachments,
      'peers': peers,
    });
    return _str(data['id']);
  }

  Future<List<Moment>> listMoments({int limit = 50}) async {
    final data = await _call('moment.list', <String, dynamic>{'limit': limit});
    return _items(data['items']).map(Moment.fromJson).toList();
  }

  Future<void> likeMoment(
    String id, {
    bool unlike = false,
    String? voter,
  }) async {
    final params = <String, dynamic>{'id': id, 'unlike': unlike};
    if (voter != null) params['voter'] = voter;
    await _call('moment.like', params);
  }

  Future<void> commentMoment(String id, String text) async {
    await _call('moment.comment', <String, dynamic>{'id': id, 'text': text});
  }

  // ---- 投票 ----

  Future<String> createPoll(
    String groupId,
    String question,
    List<String> options, {
    int closesAt = 0,
  }) async {
    final data = await _call('poll.create', <String, dynamic>{
      'group_id': groupId,
      'question': question,
      'options': options,
      'closes_at': closesAt,
    });
    return _str(data['id']);
  }

  Future<List<GroupPoll>> listPolls(String groupId, {int limit = 50}) async {
    final data = await _call('poll.list', <String, dynamic>{
      'group_id': groupId,
      'limit': limit,
    });
    return _items(data['items']).map(GroupPoll.fromJson).toList();
  }

  Future<void> votePoll(String id, int option) async {
    await _call('poll.vote', <String, dynamic>{'id': id, 'option': option});
  }
}

/// 好友申请。
class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.from,
    required this.to,
    required this.message,
    required this.status,
    required this.direction,
    required this.createdAt,
    this.respondedAt = 0,
  });

  final String id;
  final String from;
  final String to;
  final String message;
  final int status; // 0 待处理 1 已同意 2 已拒绝
  final String direction; // in / out
  final int createdAt;
  final int respondedAt;

  bool get isPending => status == 0;
  bool get isIncoming => direction == 'in';

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
    id: SocialService._str(json['id']),
    from: SocialService._str(json['from']),
    to: SocialService._str(json['to']),
    message: SocialService._str(json['message']),
    status: SocialService._int(json['status']),
    direction: SocialService._str(json['direction']),
    createdAt: SocialService._int(json['created_at']),
    respondedAt: SocialService._int(json['responded_at']),
  );
}

/// 入群申请。
class GroupJoinRequest {
  const GroupJoinRequest({
    required this.id,
    required this.groupId,
    required this.groupTitle,
    required this.applicant,
    required this.message,
    required this.status,
    required this.direction,
    required this.createdAt,
    this.respondedAt = 0,
  });

  final String id;
  final String groupId;
  final String groupTitle;
  final String applicant;
  final String message;
  final int status;
  final String direction;
  final int createdAt;
  final int respondedAt;

  bool get isPending => status == 0;
  bool get isIncoming => direction == 'in';

  factory GroupJoinRequest.fromJson(Map<String, dynamic> json) =>
      GroupJoinRequest(
        id: SocialService._str(json['id']),
        groupId: SocialService._str(json['group_id']),
        groupTitle: SocialService._str(json['group_title']),
        applicant: SocialService._str(json['applicant']),
        message: SocialService._str(json['message']),
        status: SocialService._int(json['status']),
        direction: SocialService._str(json['direction']),
        createdAt: SocialService._int(json['created_at']),
        respondedAt: SocialService._int(json['responded_at']),
      );
}

/// 系统通知。
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.payload,
    required this.read,
    required this.createdAt,
  });

  final String id;
  final String kind;
  final String title;
  final String body;
  final String payload;
  final bool read;
  final int createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: SocialService._str(json['id']),
        kind: SocialService._str(json['kind']),
        title: SocialService._str(json['title']),
        body: SocialService._str(json['body']),
        payload: SocialService._str(json['payload']),
        read: SocialService._bool(json['read']),
        createdAt: SocialService._int(json['created_at']),
      );
}

class NotificationList {
  const NotificationList({required this.items, required this.unread});
  final List<AppNotification> items;
  final int unread;
}

/// 在线状态。
class Presence {
  const Presence({
    required this.account,
    required this.online,
    required this.known,
  });

  final String account;
  final bool online;
  final bool known;

  factory Presence.fromJson(Map<String, dynamic> json) => Presence(
    account: SocialService._str(json['account']),
    online: SocialService._bool(json['online']),
    known: SocialService._bool(json['known']),
  );
}

/// 好友动态。
class Moment {
  const Moment({
    required this.id,
    required this.author,
    required this.text,
    required this.attachments,
    required this.likes,
    required this.createdAt,
  });

  final String id;
  final String author;
  final String text;
  final String attachments;
  final int likes;
  final int createdAt;

  factory Moment.fromJson(Map<String, dynamic> json) => Moment(
    id: SocialService._str(json['id']),
    author: SocialService._str(json['author']),
    text: SocialService._str(json['text']),
    attachments: SocialService._str(json['attachments']),
    likes: SocialService._int(json['likes']),
    createdAt: SocialService._int(json['created_at']),
  );
}

/// 群投票。
class GroupPoll {
  const GroupPoll({
    required this.id,
    required this.groupId,
    required this.creator,
    required this.question,
    required this.options,
    required this.votes,
    required this.createdAt,
    this.closesAt = 0,
  });

  final String id;
  final String groupId;
  final String creator;
  final String question;
  final String options;
  final String votes;
  final int createdAt;
  final int closesAt;

  List<String> get optionList {
    try {
      final decoded = jsonDecode(options);
      return decoded is List
          ? decoded.map((e) => e.toString()).toList()
          : const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  Map<String, dynamic> get voteMap {
    try {
      final decoded = jsonDecode(votes);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  factory GroupPoll.fromJson(Map<String, dynamic> json) => GroupPoll(
    id: SocialService._str(json['id']),
    groupId: SocialService._str(json['group_id']),
    creator: SocialService._str(json['creator']),
    question: SocialService._str(json['question']),
    options: SocialService._str(json['options']),
    votes: SocialService._str(json['votes']),
    createdAt: SocialService._int(json['created_at']),
    closesAt: SocialService._int(json['closes_at']),
  );
}
