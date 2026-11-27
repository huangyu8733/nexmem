// P1-20 Flutter 侧 core.start 注入：会话首页、历史消息、发送通道与事件驱动。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/contacts/contacts_page.dart';
import 'package:nexmem_app/features/group/group_storage.dart';
import 'package:nexmem_app/features/settings/backup.dart';
import 'package:nexmem_app/features/settings/diagnostics.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/storage_config.dart';
import 'package:nexmem_app/transport/transport.dart';

typedef _Handler = Object? Function(Map<String, dynamic>? params);

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handlers);

  final Map<String, _Handler> handlers;
  final List<String> methods = <String>[];
  final List<Map<String, dynamic>?> params = <Map<String, dynamic>?>[];
  final List<Duration?> timeouts = <Duration?>[];
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  int lastSeq = 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    methods.add(method);
    this.params.add(params);
    timeouts.add(timeout);
    final _Handler? handler = handlers[method];
    if (handler == null) {
      throw NexmemException('NOT_STARTED', '$method 未装配');
    }
    final Object? result = handler(params);
    return result is Map<String, dynamic> ? result : <String, dynamic>{};
  }

  void emit(CoreEvent event) {
    lastSeq = event.seq;
    _events.add(event);
  }

  @override
  Future<void> close() async {
    await _events.close();
  }
}

Map<String, dynamic> _conversationJson({
  required String id,
  String title = '张三',
  String kind = 'dm',
  String lastText = '',
  int unread = 0,
}) {
  return <String, dynamic>{
    'conversation_id': id,
    'title': title,
    'kind': kind,
    'last_text': lastText,
    'last_msg_at': 1700000000000,
    'unread': unread,
    if (kind == 'dm') 'peer': 'peer-account',
  };
}

Map<String, dynamic> _messageJson({
  required String id,
  required String conversationId,
  required String text,
  String direction = 'in',
  String sender = 'peer-account',
  String state = 'received',
  int at = 1700000000000,
  int seq = 0,
  String replyTo = '',
}) {
  return <String, dynamic>{
    'msg_uuid': id,
    'conversation_id': conversationId,
    'text': text,
    'direction': direction,
    'sender_account': sender,
    'state': state,
    'sent_at': at,
    'content_type': 0,
    'seq': seq,
    if (replyTo.isNotEmpty) 'reply_to': replyTo,
  };
}

void main() {
  test('bootstrap 读取账号；history 解出正文与方向；发送按单聊/群聊分流', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.me': (_) => <String, dynamic>{
            'account_id': 'me',
            'device_id': 'device-1',
          },
      'msg.list': (Map<String, dynamic>? params) {
        expect(params!['conversation_id'], 'dm:peer');
        expect(params['limit'], 50);
        return <String, dynamic>{
          'items': <Object?>[
            _messageJson(
              id: 'm1',
              conversationId: 'dm:peer',
              text: '我发的',
              direction: 'out',
              sender: 'me',
              state: 'acked',
              at: 1700000001000,
            ),
          ],
          'has_more': false,
        };
      },
      'dm.sendText': (Map<String, dynamic>? params) {
        expect(params!['peer'], 'peer-account');
        expect(params['text'], '你好');
        return <String, dynamic>{'msg_uuid': 'kernel-dm'};
      },
      'dm.sendGroupText': (Map<String, dynamic>? params) {
        expect(params!['group_id'], 'gid');
        expect(params['text'], '群里好');
        return <String, dynamic>{'msg_uuid': 'kernel-group'};
      },
      'group.members': (Map<String, dynamic>? params) {
        expect(params!['group_id'], 'gid');
        return <String, dynamic>{
          'members': <Object?>[],
          'storage_configured': false,
        };
      },
    });
    final CoreSession session = CoreSession(transport);
    final CoreAccount account = await session.bootstrap();
    expect(account.accountId, 'me');
    expect(transport.methods, <String>['account.me']);

    const ConversationItem dm = ConversationItem(
      id: 'dm:peer',
      title: '张三',
      peer: 'peer-account',
    );
    final List<ChatMessage> history = await session.history(dm);
    expect(history.single.text, '我发的');
    expect(history.single.isMine, isTrue);
    expect(history.single.status, MessageStatus.delivered);

    expect(
      await session.senderFor(dm).sendText(
            conversationId: dm.id,
            msgUuid: 'local',
            text: '你好',
          ),
      'kernel-dm',
    );

    const ConversationItem group = ConversationItem(
      id: 'group:gid',
      title: '项目群',
      isGroup: true,
    );
    expect(groupIdOf(group.id), 'gid');
    expect(
      await session.senderFor(group).sendText(
            conversationId: group.id,
            msgUuid: 'local',
            text: '群里好',
          ),
      'kernel-group',
    );
    expect(await session.groupStorage(group), GroupStorageStatus.unconfigured);
  });

  test('since 按 seq 游标增量拉取、解析 seq 并跨页续读（P6-31）', () async {
    final List<int> afterSeqs = <int>[];
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'msg.listSince': (Map<String, dynamic>? params) {
        expect(params!['conversation_id'], 'dm:peer');
        final int after = params['after_seq'] as int;
        afterSeqs.add(after);
        if (after == 0) {
          // 满页需续读：内核单次上限与客户端 sincePageSize 对齐。
          return <String, dynamic>{
            'items': <Object?>[
              for (int i = 1; i <= sincePageSize; i++)
                _messageJson(
                  id: 'p$i',
                  conversationId: 'dm:peer',
                  text: '第$i条',
                  seq: i,
                ),
            ],
          };
        }
        if (after >= 999) {
          return <String, dynamic>{'items': <Object?>[]};
        }
        return <String, dynamic>{
          'items': <Object?>[
            _messageJson(
              id: 'tail',
              conversationId: 'dm:peer',
              text: '尾条',
              seq: sincePageSize + 1,
            ),
          ],
        };
      },
    });
    final CoreSession session = CoreSession(transport);
    const ConversationItem dm = ConversationItem(
      id: 'dm:peer',
      title: '张三',
      peer: 'peer-account',
    );

    final SincePage page = await session.since(dm, afterSeq: 0);
    expect(page.messages.length, sincePageSize + 1);
    expect(page.messages.first.seq, 1);
    expect(page.messages.last.seq, sincePageSize + 1);
    expect(page.lastSeq, sincePageSize + 1);
    expect(afterSeqs, <int>[0, sincePageSize]);

    // 空页终止，且不推进游标。
    final SincePage empty = await session.since(dm, afterSeq: 999);
    expect(empty.messages, isEmpty);
    expect(empty.lastSeq, 999);
  });

  test('引用回复：msg.list 解析 reply_to，sendText 透传且群聊忽略（P6-32）', () async {
    Map<String, dynamic>? lastSendParams;
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'msg.list': (_) => <String, dynamic>{
            'items': <Object?>[
              _messageJson(
                id: 'reply-1',
                conversationId: 'dm:peer',
                text: '引用回复',
                seq: 2,
                replyTo: 'origin-1',
              ),
            ],
            'has_more': false,
          },
      'dm.sendText': (Map<String, dynamic>? params) {
        lastSendParams = params;
        return <String, dynamic>{'msg_uuid': 'sent-1'};
      },
      'dm.sendGroupText': (Map<String, dynamic>? params) {
        lastSendParams = params;
        return <String, dynamic>{'msg_uuid': 'sent-group'};
      },
    });
    final CoreSession session = CoreSession(transport);
    const ConversationItem dm = ConversationItem(
      id: 'dm:peer',
      title: '张三',
      peer: 'peer-account',
    );

    final List<ChatMessage> history = await session.history(dm);
    expect(history.single.replyTo, 'origin-1');

    await session.senderFor(dm).sendText(
          conversationId: dm.id,
          msgUuid: 'local',
          text: '收到',
          replyTo: 'origin-1',
        );
    expect(lastSendParams!['reply_to'], 'origin-1');

    // 空引用不下发 reply_to 字段。
    await session.senderFor(dm).sendText(
          conversationId: dm.id,
          msgUuid: 'local',
          text: '普通',
        );
    expect(lastSendParams!.containsKey('reply_to'), isFalse);

    // 群聊契约无 reply_to：即使传入也不下发。
    const ConversationItem group = ConversationItem(
      id: 'group:gid',
      title: '项目群',
      isGroup: true,
    );
    await session.senderFor(group).sendText(
          conversationId: group.id,
          msgUuid: 'local',
          text: '群消息',
          replyTo: 'origin-1',
        );
    expect(lastSendParams!.containsKey('reply_to'), isFalse);
  });

  test('historyPage 以 before_id 键集翻页并返回 has_more', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.me': (_) => <String, dynamic>{
            'account_id': 'me',
            'device_id': 'device-1',
          },
      'msg.list': (Map<String, dynamic>? params) {
        expect(params!['conversation_id'], 'dm:peer');
        final Object? cursor = params['before_id'];
        if (cursor == null) {
          expect(params['limit'], 2);
          return <String, dynamic>{
            'items': <Object?>[
              _messageJson(
                id: 'm3',
                conversationId: 'dm:peer',
                text: '第三条',
                at: 1700000003000,
              ),
              _messageJson(
                id: 'm2',
                conversationId: 'dm:peer',
                text: '第二条',
                at: 1700000002000,
              ),
            ],
            'has_more': true,
          };
        }
        expect(cursor, 'm2');
        return <String, dynamic>{
          'items': <Object?>[
            _messageJson(
              id: 'm1',
              conversationId: 'dm:peer',
              text: '第一条',
              at: 1700000001000,
            ),
          ],
          'has_more': false,
        };
      },
    });
    final CoreSession session = CoreSession(transport);
    await session.bootstrap();
    const ConversationItem dm = ConversationItem(
      id: 'dm:peer',
      title: '张三',
      peer: 'peer-account',
    );

    final HistoryPage first = await session.historyPage(dm, limit: 2);
    expect(
      first.messages.map((ChatMessage m) => m.id),
      <String>['m3', 'm2'],
    );
    expect(first.hasMore, isTrue);

    final HistoryPage second = await session.historyPage(
      dm,
      limit: 2,
      beforeId: first.messages.last.id,
    );
    expect(second.messages.single.id, 'm1');
    expect(second.hasMore, isFalse);
    expect(transport.params[2]!['before_id'], 'm2');
  });

  test('A-02 文件消息：history 解出附件，单聊/群聊 sendFile 分流并透传路径与 MIME', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.me': (_) => <String, dynamic>{
            'account_id': 'me',
            'device_id': 'device-1',
          },
      'msg.list': (_) => <String, dynamic>{
            'items': <Object?>[
              <String, dynamic>{
                ..._messageJson(
                  id: 'f1',
                  conversationId: 'dm:peer',
                  text: '',
                  at: 1700000001000,
                ),
                'content_type': 2,
                'attachments': <Object?>[
                  <String, dynamic>{
                    'name': '报告.pdf',
                    'size': 2048,
                    'mime': 'application/pdf',
                    'path': r'D:\nexmem\files\f1.pdf',
                  },
                ],
              },
            ],
            'has_more': false,
          },
      'dm.sendFile': (Map<String, dynamic>? params) {
        expect(params!['peer'], 'peer-account');
        expect(params['path'], r'D:\docs\报告.pdf');
        expect(params['mime'], 'application/pdf');
        return <String, dynamic>{'msg_uuid': 'kernel-file'};
      },
      'dm.sendGroupFile': (Map<String, dynamic>? params) {
        expect(params!['group_id'], 'gid');
        expect(params['path'], r'D:\docs\群文件.pdf');
        expect(params['mime'], 'application/pdf');
        return <String, dynamic>{'msg_uuid': 'kernel-group-file'};
      },
    });
    final CoreSession session = CoreSession(transport);
    const ConversationItem dm = ConversationItem(
      id: 'dm:peer',
      title: '张三',
      peer: 'peer-account',
    );

    final ChatMessage inbound = (await session.history(dm)).single;
    expect(inbound.isFile, isTrue);
    expect(inbound.text, '报告.pdf', reason: '正文缺省时回退为附件名');
    expect(inbound.attachment?.name, '报告.pdf');
    expect(inbound.attachment?.size, 2048);
    expect(inbound.attachment?.mime, 'application/pdf');
    expect(inbound.attachment?.path, r'D:\nexmem\files\f1.pdf');

    expect(
      await session.senderFor(dm).sendFile(
            conversationId: dm.id,
            msgUuid: 'local-file',
            path: r'D:\docs\报告.pdf',
            mime: 'application/pdf',
          ),
      'kernel-file',
    );

    // 大文件 P2P 分片传输不能用文本消息的 20s 通用超时，否则客户端先把
    // 气泡标失败、内核随后成功时又因 msg_uuid 不同无法回填状态。
    expect(transport.timeouts.last, const Duration(minutes: 5));

    // A-02：群聊文件走 dm.sendGroupFile，密文写群盘、元数据随群消息广播。
    const ConversationItem group = ConversationItem(
      id: 'group:gid',
      title: '项目群',
      isGroup: true,
    );
    expect(
      await session.senderFor(group).sendFile(
            conversationId: group.id,
            msgUuid: 'local-file',
            path: r'D:\docs\群文件.pdf',
            mime: 'application/pdf',
          ),
      'kernel-group-file',
    );
    expect(transport.methods, contains('dm.sendGroupFile'));
    expect(transport.params.last!['group_id'], 'gid');
    expect(transport.params.last!['path'], r'D:\docs\群文件.pdf');
  });

  test('bootstrap 在 NOT_STARTED 时按配置启动内核', () async {
    int accountCalls = 0;
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.me': (_) {
        accountCalls++;
        if (accountCalls == 1) {
          throw const NexmemException('NOT_STARTED', '内核未启动');
        }
        return <String, dynamic>{'account_id': 'me', 'device_id': 'd'};
      },
      'core.start': (Map<String, dynamic>? params) {
        expect(params!['config'], <String, dynamic>{'data_dir': 'C:/tmp'});
        return <String, dynamic>{'state': 'online'};
      },
    });
    final CoreSession session = CoreSession(transport);
    await session.bootstrap(startConfig: <String, dynamic>{'data_dir': 'C:/tmp'});
    expect(session.accountId, 'me');
    expect(transport.methods, <String>['account.me', 'core.start', 'account.me']);

    // 未提供启动配置时保持原错误，交由调用方提示。
    final _FakeTransport failing = _FakeTransport(<String, _Handler>{});
    await expectLater(
      CoreSession(failing).bootstrap(),
      throwsA(isA<NexmemException>()),
    );
  });

  test('设置页服务经传输层调用诊断/备份/存储自检', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'diag.snapshot': (_) => <String, dynamic>{
            'uptime_ms': 65000,
            'dht_lookups': 2,
            'dht_errors': 0,
            'dht_p50_ms': 12.5,
            'dht_p95_ms': 30.0,
            'holepunch': <String, dynamic>{'quic/direct': 3},
            's3_status': <String, dynamic>{'PUT/200': 1},
          },
      'diag.export': (Map<String, dynamic>? params) {
        expect(params!['path'], startsWith(r'C:\tmp\nexmem-diagnostics-'));
        expect(params['path'], endsWith('.jsonl'));
        return <String, dynamic>{'path': params['path']};
      },
      'backup.export': (Map<String, dynamic>? params) {
        expect(params!['path'], r'C:\tmp\backup.nmbk');
        expect(params['passphrase_b64'], base64Encode(utf8.encode('口令')));
        return <String, dynamic>{'path': r'C:\tmp\backup.nmbk'};
      },
      'storage.test': (Map<String, dynamic>? params) {
        expect(params!['endpoint'], 'http://127.0.0.1:9000');
        expect(params['path_style'], isTrue);
        return <String, dynamic>{
          'ok': true,
          'latency_ms': 12,
          'writable': true,
          'listable': true,
        };
      },
    });
    final CoreSession session = CoreSession(
      transport,
      startConfig: <String, dynamic>{'data_dir': r'C:\tmp'},
    );

    final DiagnosticsSnapshot snapshot = await session.diagnostics.snapshot();
    expect(snapshot.dhtLookups, 2);
    expect(snapshot.directCount, 3);
    expect(
      await session.diagnostics.exportBundle(),
      startsWith(r'C:\tmp\nexmem-diagnostics-'),
    );
    expect(
      await session.backup.export(
        path: r'C:\tmp\backup.nmbk',
        passphrase: '口令',
      ),
      r'C:\tmp\backup.nmbk',
    );
    final StorageTestResult result = await session.storageTest.test(
      const StorageTestRequest(
        provider: StorageProvider.minio,
        endpoint: 'http://127.0.0.1:9000',
        bucket: 'nexmem',
        prefix: 'nexmem/',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        pathStyle: true,
      ),
    );
    expect(result.ok, isTrue);
    expect(result.writable, isTrue);
    expect(result.listable, isTrue);
    expect(transport.methods, <String>[
      'diag.snapshot',
      'diag.export',
      'backup.export',
      'storage.test',
    ]);
  });

  testWidgets('壳层接入内核：会话列表、历史消息、群盘提示、发送与事件', (WidgetTester tester) async {
    int listCalls = 0;
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.me': (_) => <String, dynamic>{'account_id': 'me', 'device_id': 'd'},
      'conversation.list': (Map<String, dynamic>? params) {
        expect(params!['limit'], 50);
        return <String, dynamic>{
          'items': <Object?>[
            _conversationJson(
              id: 'group:gid',
              title: '项目群',
              kind: 'group',
              lastText: '旧消息',
            ),
          ],
          'has_more': false,
        };
      },
      'msg.list': (Map<String, dynamic>? params) {
        expect(params!['conversation_id'], 'group:gid');
        listCalls++;
        return <String, dynamic>{
          'items': <Object?>[
            _messageJson(
              id: 'm1',
              conversationId: 'group:gid',
              text: '历史消息',
              seq: 10,
            ),
          ],
          'has_more': false,
        };
      },
      'msg.listSince': (Map<String, dynamic>? params) {
        expect(params!['conversation_id'], 'group:gid');
        expect(params['after_seq'], 10);
        return <String, dynamic>{
          'items': <Object?>[
            _messageJson(
              id: 'm2',
              conversationId: 'group:gid',
              text: '新来的消息',
              at: 1700000005000,
              seq: 11,
            ),
          ],
        };
      },
      'group.members': (_) => <String, dynamic>{
            'members': <Object?>[],
            'storage_configured': false,
          },
      'dm.sendGroupText': (_) =>
          <String, dynamic>{'msg_uuid': 'kernel-group'},
    });
    final CoreSession session = CoreSession(transport);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // 本测试聚焦会话/消息链路，未装配 contact.list/group.list，
    // 关闭启动检测门避免误判「服务未就绪」。
    await tester.pumpWidget(
      NexmemApp(session: session, enableStartupCheck: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('项目群'), findsOneWidget);
    expect(find.text('旧消息'), findsOneWidget);

    // 设置页三个服务均由内核会话注入，而不是保留占位实现（P6-04/05/06）。
    final SettingsPage settings = tester.widget<SettingsPage>(
      find.byType(SettingsPage, skipOffstage: false).first,
    );
    expect(settings.diagnostics, isA<TransportDiagnosticsService>());
    expect(settings.backup, isA<TransportBackupService>());
    expect(settings.storage, isA<TransportStorageTestService>());

    // 通讯录页同样由内核注入数据源（P2-06）。
    final ContactsPage contactsPage = tester.widget<ContactsPage>(
      find.byType(ContactsPage, skipOffstage: false),
    );
    expect(contactsPage.service, isA<TransportContactService>());

    await tester.tap(find.text('项目群'));
    await tester.pumpAndSettle();
    expect(find.text('历史消息'), findsOneWidget);
    expect(find.text('未配置群盘，离线消息不可补'), findsOneWidget);
    expect(
      tester.widget<ChatPage>(find.byType(ChatPage)).diagnostics,
      isA<TransportDiagnosticsService>(),
    );

    // 发送走 dm.sendGroupText，本地消息用内核 msg_uuid 落位。
    await tester.enterText(find.byType(TextField), '大家好');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(transport.methods, contains('dm.sendGroupText'));
    expect(find.text('大家好'), findsOneWidget);

    // 入站事件：补齐新消息并刷新会话摘要。
    transport.emit(
      const CoreEvent(
        seq: 7,
        type: 'message.new',
        ts: 1700000005000,
        data: <String, dynamic>{
          'conversation_id': 'group:gid',
          'msg_uuid': 'm2',
          'direction': 'in',
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('新来的消息'), findsOneWidget);
    // 已建立 seq 基准后走增量，不再全量重拉 msg.list（P6-31）。
    expect(transport.methods, contains('msg.listSince'));
    expect(listCalls, 1);

    // 返回列表后检查顶部状态条。
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();

    // 状态机事件：degraded 显示「经中继」。
    transport.emit(
      const CoreEvent(
        seq: 8,
        type: 'state.changed',
        ts: 1700000006000,
        data: <String, dynamic>{'state': 'degraded'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('经中继'), findsOneWidget);

    // A-05：内核状态机 6 态全部有明确 UI 展示，init/starting 显示「连接中」。
    for (final String state in <String>['init', 'starting']) {
      transport.emit(
        CoreEvent(
          seq: state == 'init' ? 9 : 10,
          type: 'state.changed',
          ts: 1700000007000,
          data: <String, dynamic>{'state': state},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('连接中'), findsOneWidget, reason: 'state=$state');
    }
    transport.emit(
      const CoreEvent(
        seq: 11,
        type: 'state.changed',
        ts: 1700000008000,
        data: <String, dynamic>{'state': 'online'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('在线'), findsOneWidget);
    transport.emit(
      const CoreEvent(
        seq: 12,
        type: 'state.changed',
        ts: 1700000009000,
        data: <String, dynamic>{'state': 'offline'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('离线'), findsOneWidget);
  });

  testWidgets('对端未开启离线存储：失败事件带 reason 时常驻降级提示（P3-09）', (
    WidgetTester tester,
  ) async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.me': (_) => <String, dynamic>{'account_id': 'me', 'device_id': 'd'},
      'conversation.list': (_) => <String, dynamic>{
            'items': <Object?>[_conversationJson(id: 'dm:peer')],
            'has_more': false,
          },
      'msg.list': (_) => <String, dynamic>{
            'items': <Object?>[],
            'has_more': false,
          },
      'dm.sendText': (_) => <String, dynamic>{'msg_uuid': 'kernel-dm'},
    });
    final CoreSession session = CoreSession(transport);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // 本测试聚焦会话/消息链路，未装配 contact.list/group.list，
    // 关闭启动检测门避免误判「服务未就绪」。
    await tester.pumpWidget(
      NexmemApp(session: session, enableStartupCheck: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '在吗');
    await tester.pump();
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(find.text(OfflineStorageNotice.message), findsNothing);

    // 内核确认「对端未开启离线存储」：失败事件携带 reason。
    transport.emit(
      const CoreEvent(
        seq: 21,
        type: 'message.updated',
        ts: 1700000009000,
        data: <String, dynamic>{
          'conversation_id': 'dm:peer',
          'msg_uuid': 'kernel-dm',
          'state': 'failed',
          'reason': 'OFFLINE_STORAGE_DISABLED',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('对方未开启离线存储，仅支持在线发送'), findsOneWidget);
    expect(
      tester.widget<ChatPage>(find.byType(ChatPage)).store.messages.single.status,
      MessageStatus.failed,
    );
  });

  // P6-07：对端已读回执把内核 state=read 推进为「已读」（双勾主色）。
  test('内核 read 状态映射为已读', () {
    expect(messageStatusFromState('read'), MessageStatus.read);
    expect(messageStatusFromState('acked'), MessageStatus.delivered);
    expect(messageStatusFromState('sent'), MessageStatus.sent);
  });

  // P6-29：core.info 回包解析与能力探测。
  group('P6-29 core.info 版本协商', () {
    test('CoreInfo.fromJson 解析版本、能力并忽略非法条目', () {
      final CoreInfo info = CoreInfo.fromJson(<String, dynamic>{
        'api_version': '1.0.0',
        'core_version': '0.1.0-dev',
        'features': <dynamic>['core.info', 'rtc.sendSignal', 42, null],
      });
      expect(info.apiVersion, '1.0.0');
      expect(info.coreVersion, '0.1.0-dev');
      expect(info.features, <String>['core.info', 'rtc.sendSignal']);
      expect(info.supports('rtc.sendSignal'), isTrue);
      expect(info.supports('missing.method'), isFalse);
      expect(info.apiMajorCompatible, isTrue);
    });

    test('API 主版本不一致时 apiMajorCompatible 为 false', () {
      final CoreInfo info = CoreInfo.fromJson(<String, dynamic>{
        'api_version': '2.1.0',
        'core_version': '2.0.0',
      });
      expect(info.apiMajorCompatible, isFalse);
      expect(info.features, isEmpty);
    });

    test('loadInfo 调用 core.info 并缓存解析结果', () async {
      final _FakeTransport transport = _FakeTransport(<String, _Handler>{
        'core.info': (_) => <String, dynamic>{
          'api_version': '1.0.0',
          'core_version': '0.1.0-dev',
          'features': <String>['core.info', 'msg.list'],
        },
      });
      final CoreSession session = CoreSession(transport);
      final CoreInfo? info = await session.loadInfo();
      expect(transport.methods, contains('core.info'));
      expect(info, isNotNull);
      expect(info!.coreVersion, '0.1.0-dev');
      expect(info.features.length, 2);
    });

    test('core.info 不可用时 loadInfo 返回 null 而非抛错', () async {
      // 未装配 core.info 的 FakeTransport 会抛 NOT_STARTED。
      final CoreSession session = CoreSession(_FakeTransport(<String, _Handler>{}));
      expect(await session.loadInfo(), isNull);
    });
  });
}
