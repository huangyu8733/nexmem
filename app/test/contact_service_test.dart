// P2-06 通讯录内核接入：编码工具、`contact.*` 契约、列表/添加好友与备注拉黑落库。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_detail_page.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/contacts/contacts_page.dart';
import 'package:nexmem_app/transport/transport.dart';

typedef _Handler = Object? Function(Map<String, dynamic>? params);

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
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    methods.add(method);
    this.params.add(params);
    final _Handler? handler = handlers[method];
    if (handler == null) {
      throw NexmemException('NOT_STARTED', '$method 未装配');
    }
    final Object? result = handler(params);
    return result is Map<String, dynamic> ? result : <String, dynamic>{};
  }

  @override
  Future<void> close() async {}
}

class _FakeContactService implements ContactService {
  _FakeContactService(this.items);

  final List<Contact> items;
  final List<String> calls = <String>[];
  NexmemException? listError;
  NexmemException? writeError;

  @override
  Future<List<Contact>> list({int limit = 200}) async {
    calls.add('list');
    final NexmemException? error = listError;
    if (error != null) {
      throw error;
    }
    return List<Contact>.of(items);
  }

  @override
  Future<Contact> add(String account, {String alias = ''}) async {
    calls.add('add:$account:$alias');
    final NexmemException? error = writeError;
    if (error != null) {
      throw error;
    }
    final Contact added = Contact(
      id: normalizeAccountHex(account),
      name: alias.isEmpty ? shortAccountLabel(account) : alias,
      note: alias,
      peer: peerFromAccount(account) ?? '',
    );
    items.insert(0, added);
    return added;
  }

  @override
  Future<void> setRemark(String account, String remark) async {
    calls.add('remark:$account:$remark');
    final NexmemException? error = writeError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> setGroup(String account, String group) async {
    calls.add('group:$account:$group');
    final NexmemException? error = writeError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> setBlocked(String account, bool blocked) async {
    calls.add('block:$account:$blocked');
    final NexmemException? error = writeError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> remove(String account) async {
    calls.add('remove:$account');
  }

  @override
  Future<DeviceListResult> devices({String? peer}) async {
    calls.add('devices:${peer ?? ''}');
    final NexmemException? error = listError;
    if (error != null) {
      throw error;
    }
    return const DeviceListResult(items: <DeviceInfo>[], found: true, self: true);
  }
}

const String _peerHex =
    '1f0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

void main() {
  test('contact.list 解析备注、拉黑与 base64url 账号', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'contact.list': (Map<String, dynamic>? params) {
        expect(params!['limit'], 50);
        return <String, dynamic>{
          'items': <Object?>[
            <String, dynamic>{
              'account_pub': _peerHex,
              'alias': '老王',
              'group_name': '同事',
              'blocked': true,
              'updated_at': 1700000000000,
            },
            <String, dynamic>{
              'account_pub': 'aa' * 32,
              'alias': '',
              'blocked': false,
            },
          ],
        };
      },
    });
    final List<Contact> items =
        await TransportContactService(transport).list(limit: 50);

    expect(transport.methods, <String>['contact.list']);
    expect(items, hasLength(2));
    expect(items[0].id, _peerHex);
    expect(items[0].name, '老王');
    expect(items[0].note, '老王');
    expect(items[0].groupName, '同事');
    expect(items[0].blocked, isTrue);
    expect(items[0].peer, peerFromAccount(_peerHex));
    // 无备注时退化为账号短串，避免列表出现空名字。
    expect(items[1].name, 'aaaaaa…');
    expect(items[1].note, isEmpty);
  });

  test('添加好友、备注、分组与拉黑按契约参数下发', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'contact.add': (_) => <String, dynamic>{'account_pub': _peerHex},
      'contact.list': (_) => <String, dynamic>{
            'items': <Object?>[
              <String, dynamic>{'account_pub': _peerHex, 'alias': '老王'},
            ],
          },
      'contact.remark': (_) => <String, dynamic>{},
      'contact.setGroup': (_) => <String, dynamic>{},
      'contact.block': (_) => <String, dynamic>{},
    });
    final TransportContactService service = TransportContactService(transport);

    final Contact added = await service.add(_peerHex, alias: '老王');
    expect(added.id, _peerHex);
    expect(transport.params.first!['peer'], _peerHex);
    expect(transport.params.first!['alias'], '老王');

    await service.setRemark(_peerHex, '同事');
    await service.setGroup(_peerHex, '家人');
    await service.setBlocked(_peerHex, true);
    expect(transport.methods, <String>[
      'contact.add',
      'contact.list',
      'contact.remark',
      'contact.setGroup',
      'contact.block',
    ]);
    expect(transport.params[2], <String, dynamic>{'peer': _peerHex, 'remark': '同事'});
    expect(transport.params[3], <String, dynamic>{'peer': _peerHex, 'group': '家人'});
    expect(transport.params[4], <String, dynamic>{'peer': _peerHex, 'blocked': true});
  });

  test('删除好友按契约调用 contact.delete', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'contact.delete': (_) => <String, dynamic>{'peer': _peerHex},
    });
    await TransportContactService(transport).remove(_peerHex);
    expect(transport.methods, <String>['contact.delete']);
    expect(transport.params.single, <String, dynamic>{'peer': _peerHex});
  });

  test('账号编码互转与单聊会话 ID 与内核一致', () {
    // 32 字节全零公钥的 base64url 为 43 个 A。
    expect(peerFromAccount('00' * 32), 'A' * 43);
    expect(normalizeAccountHex('A' * 43), '00' * 32);
    expect(normalizeAccountHex(_peerHex.toUpperCase()), _peerHex);
    expect(
      dmConversationId(selfAccount: 'ff' * 32, peer: '00' * 32),
      'dm:${'00' * 32}|${'ff' * 32}',
    );
    expect(
      dmConversationId(selfAccount: '00' * 32, peer: 'ff' * 32),
      'dm:${'00' * 32}|${'ff' * 32}',
    );
    expect(
      () => dmConversationId(selfAccount: 'not-an-account', peer: '00' * 32),
      throwsFormatException,
    );
  });

  test('内核未接通时明确抛 NOT_STARTED，不展示假数据', () async {
    const UnavailableContactService service = UnavailableContactService();
    await expectLater(
      service.list(),
      throwsA(isA<NexmemException>()
          .having((NexmemException e) => e.code, 'code', 'NOT_STARTED')),
    );
  });

  testWidgets('通讯录页从内核加载并以备注作为展示名', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService(<Contact>[
      Contact(
        id: _peerHex,
        name: '老王',
        note: '老王',
        peer: peerFromAccount(_peerHex) ?? '',
      ),
      Contact(id: 'aa' * 32, name: 'aaaaaa…', peer: 'x'),
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ContactsPage(service: service)),
    ));
    await tester.pump();
    await tester.pump();

    expect(service.calls, <String>['list']);
    expect(find.text('老王'), findsOneWidget);
    expect(find.text('aaaaaa…'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('contact-empty')), findsNothing);
  });

  testWidgets('添加好友成功后刷新列表；失败留在弹窗并提示', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService(<Contact>[]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ContactsPage(service: service)),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('contact-empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('contact-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-add-account')),
      _peerHex,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-add-alias')),
      '老王',
    );
    service.writeError =
        const NexmemException('INVALID_ARG', 'bad account');
    await tester.tap(find.byKey(const ValueKey<String>('contact-add-submit')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('contact-add-error')), findsOneWidget);
    expect(find.text('账号格式不正确，请粘贴完整公钥'), findsOneWidget);

    service.writeError = null;
    await tester.tap(find.byKey(const ValueKey<String>('contact-add-submit')));
    await tester.pumpAndSettle();
    expect(service.calls, contains('add:$_peerHex:老王'));
    expect(find.text('老王'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('contact-empty')), findsNothing);
  });

  testWidgets('列表加载失败展示重试入口', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService(<Contact>[]);
    service.listError = const NexmemException('UNAVAILABLE', '内核未就绪');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ContactsPage(service: service)),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('内核未就绪'), findsOneWidget);

    service.listError = null;
    await tester.tap(find.byKey(const ValueKey<String>('contact-retry')));
    await tester.pump();
    await tester.pump();
    expect(service.calls.where((String c) => c == 'list'), hasLength(2));
    expect(find.text('内核未就绪'), findsNothing);
  });

  testWidgets('资料页备注与拉黑写入内核，发消息回调壳层', (WidgetTester tester) async {
    // 资料页新增分组字段后内容更高，加大视口确保底部「发消息」按钮被构建。
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final _FakeContactService service = _FakeContactService(<Contact>[]);
    Contact? sent;
    final Contact contact = Contact(
      id: _peerHex,
      name: '老王',
      note: '老王',
      peer: peerFromAccount(_peerHex) ?? '',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContactDetailPage(
          contact: contact,
          service: service,
          onSendMessage: () => sent = contact,
        ),
      ),
    ));

    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-remark-field')),
      '同事',
    );
    await tester.tap(find.byKey(const ValueKey<String>('contact-note-save')));
    await tester.pump();
    await tester.pump();
    expect(service.calls, contains('remark:$_peerHex:同事'));

    await tester.tap(find.byKey(const ValueKey<String>('contact-block-switch')));
    await tester.pump();
    await tester.pump();
    expect(service.calls, contains('block:$_peerHex:true'));
    // 拉黑后「发消息」按钮禁用。
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey<String>('contact-send-button')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey<String>('contact-block-switch')));
    await tester.pump();
    await tester.pump();
    expect(service.calls, contains('block:$_peerHex:false'));

    await tester.tap(find.byKey(const ValueKey<String>('contact-send-button')));
    await tester.pump();
    expect(sent?.id, _peerHex);
  });

  testWidgets('备注写入失败回滚并提示', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService(<Contact>[]);
    final Contact contact = Contact(
      id: _peerHex,
      name: '老王',
      note: '老王',
      peer: peerFromAccount(_peerHex) ?? '',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ContactDetailPage(contact: contact, service: service),
      ),
    ));

    service.writeError = const NexmemException('INTERNAL', '数据库忙');
    await tester.enterText(
      find.byKey(const ValueKey<String>('contact-remark-field')),
      '同事',
    );
    await tester.tap(find.byKey(const ValueKey<String>('contact-note-save')));
    await tester.pump();
    await tester.pump();
    expect(find.text('数据库忙'), findsOneWidget);
    final TextField field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('contact-remark-field')),
    );
    expect(field.controller?.text, '老王');
  });
}

