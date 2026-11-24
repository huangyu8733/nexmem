// QQ 式社交服务：`friend.* / group.join.* / notification.* / moment.* / poll.*` 契约接入。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/social/social_service.dart';
import 'package:nexmem_app/transport/transport.dart';

typedef _Handler = Map<String, dynamic> Function(Map<String, dynamic>? params);

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handlers);
  final Map<String, _Handler> handlers;
  final List<String> methods = <String>[];
  final List<Map<String, dynamic>?> params = <Map<String, dynamic>?>[];

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();
  @override
  int lastSeq = 0;
  @override
  Future<Map<String, dynamic>> call(String method,
      {Map<String, dynamic>? params, Duration? timeout}) async {
    methods.add(method);
    this.params.add(params);
    final handler = handlers[method];
    if (handler == null) throw NexmemException('NOT_STARTED', '$method 未装配');
    return handler(params);
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('好友申请：发送/列表/同意/计数都走正确契约', () async {
    final t = _FakeTransport(<String, _Handler>{
      'friend.request.send': (p) {
        expect(p!['peer'], 'abc');
        expect(p['message'], '你好');
        return <String, dynamic>{'id': 'r1'};
      },
      'friend.request.list': (p) => <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'r1',
            'from': 'a' * 64,
            'to': 'b' * 64,
            'message': '你好',
            'status': 0,
            'direction': 'in',
            'created_at': 123,
          },
        ],
      },
      'friend.request.respond': (p) {
        expect(p!['id'], 'r1');
        expect(p['accept'], true);
        return <String, dynamic>{'id': 'r1'};
      },
      'friend.request.count': (p) => <String, dynamic>{'count': 2},
    });
    final svc = SocialService(t);
    expect(await svc.sendFriendRequest('abc', message: '你好'), 'r1');
    final list = await svc.listFriendRequests();
    expect(list.length, 1);
    expect(list.first.message, '你好');
    expect(list.first.isPending, true);
    expect(list.first.isIncoming, true);
    expect(await svc.pendingFriendRequestCount(), 2);
    await svc.respondFriendRequest('r1', true);
    expect(t.methods, contains('friend.request.respond'));
  });

  test('入群申请与成员管理走正确契约', () async {
    final t = _FakeTransport(<String, _Handler>{
      'group.join.request': (p) => <String, dynamic>{'id': 'j1'},
      'group.join.list': (p) => <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'j1',
            'group_id': 'g1',
            'group_title': '测试群',
            'applicant': 'c' * 64,
            'message': '想入群',
            'status': 0,
            'direction': 'in',
            'created_at': 1,
          },
        ],
      },
      'group.join.respond': (p) => <String, dynamic>{'id': 'j1'},
      'group.member.set': (p) {
        expect(p!['role'], 'admin');
        expect(p['mute_minutes'], 10);
        return <String, dynamic>{};
      },
    });
    final svc = SocialService(t);
    expect(await svc.requestGroupJoin('g1', 'owner1', groupTitle: '测试群', message: '想入群'), 'j1');
    final list = await svc.listGroupJoinRequests();
    expect(list.first.groupTitle, '测试群');
    await svc.respondGroupJoin('j1', true);
    await svc.setMember('g1', 'acct', role: 'admin', muteMinutes: 10);
  });

  test('通知、在线状态解析正确', () async {
    final t = _FakeTransport(<String, _Handler>{
      'notification.list': (p) => <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'n1',
            'kind': 'friend.request',
            'title': '好友申请',
            'body': '你好',
            'payload': '{}',
            'read': false,
            'created_at': 1,
          },
        ],
        'unread': 1,
      },
      'notification.read': (p) => <String, dynamic>{},
      'presence.list': (p) => <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{'account': 'd' * 64, 'online': true, 'known': true},
        ],
      },
    });
    final svc = SocialService(t);
    final notifs = await svc.listNotifications();
    expect(notifs.unread, 1);
    expect(notifs.items.first.read, false);
    await svc.markNotificationRead(id: 'n1');
    expect(t.params.last!['id'], 'n1');
    final presence = await svc.listPresence(['d' * 64]);
    expect(presence.first.online, true);
  });

  test('动态与投票解析正确，含 JSON 选项与票映射', () async {
    final t = _FakeTransport(<String, _Handler>{
      'moment.post': (p) => <String, dynamic>{'id': 'm1'},
      'moment.list': (p) => <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'm1',
            'author': 'e' * 64,
            'text': '今天天气好',
            'attachments': '',
            'likes': 3,
            'created_at': 1,
          },
        ],
      },
      'moment.like': (p) => <String, dynamic>{},
      'moment.comment': (p) => <String, dynamic>{},
      'poll.create': (p) => <String, dynamic>{'id': 'p1'},
      'poll.list': (p) => <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'id': 'p1',
            'group_id': 'g1',
            'creator': 'f' * 64,
            'question': '去哪玩',
            'options': '["A","B"]',
            'votes': '{"acct":1}',
            'created_at': 1,
            'closes_at': 0,
          },
        ],
      },
      'poll.vote': (p) => <String, dynamic>{'votes': '{}'},
    });
    final svc = SocialService(t);
    expect(await svc.postMoment('今天天气好'), 'm1');
    final moments = await svc.listMoments();
    expect(moments.first.likes, 3);
    await svc.likeMoment('m1');
    await svc.commentMoment('m1', '好看');
    expect(await svc.createPoll('g1', '去哪玩', <String>['A', 'B']), 'p1');
    final polls = await svc.listPolls('g1');
    expect(polls.first.optionList, <String>['A', 'B']);
    expect(polls.first.voteMap['acct'], 1);
    await svc.votePoll('p1', 0);
  });

  test('六类社交记录的删除都走正确契约并回传条数', () async {
    final t = _FakeTransport(<String, _Handler>{
      for (final String method in <String>[
        'friend.request.delete',
        'friend.request.clear',
        'group.join.delete',
        'group.join.clear',
        'notification.delete',
        'notification.clear',
      ])
        method: (Map<String, dynamic>? p) => <String, dynamic>{'deleted': 1},
    });
    final svc = SocialService(t);
    expect(await svc.deleteFriendRequest('f1'), 1);
    expect(await svc.clearFriendRequests(), 1);
    expect(await svc.deleteGroupJoinRequest('j1'), 1);
    expect(await svc.clearGroupJoinRequests(), 1);
    expect(await svc.deleteNotification('n1'), 1);
    expect(await svc.clearNotifications(), 1);
    expect(t.methods, <String>[
      'friend.request.delete',
      'friend.request.clear',
      'group.join.delete',
      'group.join.clear',
      'notification.delete',
      'notification.clear',
    ]);
    expect(t.params.first!['id'], 'f1');
  });
}
