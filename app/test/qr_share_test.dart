// P6-39 二维码加好友：CoreSession 契约调用 + QrMatrixView 渲染 + 名片解析预填。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/contacts/add_friend_dialog.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/contacts/qr_share.dart';
import 'package:nexmem_app/transport/transport.dart';

typedef _Handler = Object? Function(Map<String, dynamic>? params);

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handlers);

  final Map<String, _Handler> handlers;
  final List<String> methods = <String>[];
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
    final _Handler? handler = handlers[method];
    if (handler == null) {
      throw NexmemException('NOT_STARTED', '$method 未装配');
    }
    final Object? result = handler(params);
    return result is Map<String, dynamic> ? result : <String, dynamic>{};
  }

  @override
  Future<void> close() async {
    await _events.close();
  }
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('QrPayload / QrCard 解析字段', () {
    final QrPayload payload = QrPayload.fromJson(<String, dynamic>{
      'payload': 'nexmem://add/abc',
      'account_id': 'a' * 64,
      'device_id': 'device1',
    });
    expect(payload.payload, 'nexmem://add/abc');
    expect(payload.accountId, 'a' * 64);
    expect(payload.deviceId, 'device1');

    final QrCard card = QrCard.fromJson(<String, dynamic>{
      'account_id': 'b' * 64,
      'device_id': 'device2',
      'display_name': '张三',
    });
    expect(card.accountId, 'b' * 64);
    expect(card.displayName, '张三');
  });

  test('QrPayload / QrCard 缺字段时抛 FormatException', () {
    expect(
      () => QrPayload.fromJson(<String, dynamic>{}),
      throwsFormatException,
    );
    expect(
      () => QrCard.fromJson(<String, dynamic>{}),
      throwsFormatException,
    );
  });

  test('CoreSession.qrPayload / qrParse 透传契约调用', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.qrPayload': (_) => <String, dynamic>{
            'payload': 'nexmem://add/xyz',
            'account_id': 'c' * 64,
            'device_id': 'dev',
          },
      'account.qrParse': (Map<String, dynamic>? p) => <String, dynamic>{
            'account_id': 'd' * 64,
            'device_id': 'dev2',
            'display_name': '李四',
          },
    });
    final CoreSession session = CoreSession(transport);
    final QrPayload payload = await session.qrPayload();
    expect(payload.payload, 'nexmem://add/xyz');
    final QrCard card = await session.qrParse('nexmem://add/xyz');
    expect(card.displayName, '李四');
    expect(transport.methods, <String>['account.qrPayload', 'account.qrParse']);
  });

  testWidgets('QrMatrixView 渲染二维码矩阵', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(const QrMatrixView(data: 'nexmem://add/test', size: 200)),
    );
    expect(find.byKey(const ValueKey<String>('qr-matrix')), findsOneWidget);
  });

  testWidgets('AddFriendDialog 支持预填账号与备注', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService();
    await tester.pumpWidget(
      _wrap(AddFriendDialog(
        service: service,
        initialAccount: 'e' * 64,
        initialAlias: '预填昵称',
      )),
    );
    final TextField accountField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('contact-add-account')),
    );
    final TextField aliasField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('contact-add-alias')),
    );
    expect(accountField.controller!.text, 'e' * 64);
    expect(aliasField.controller!.text, '预填昵称');
  });
}

class _FakeContactService implements ContactService {
  @override
  Future<List<Contact>> list({int limit = 200}) async => const <Contact>[];

  @override
  Future<Contact> add(String account, {String alias = ''}) async => Contact(
        id: account,
        name: alias,
        peer: '',
      );

  @override
  Future<void> setRemark(String account, String remark) async {}

  @override
  Future<void> setGroup(String account, String group) async {}

  @override
  Future<void> setBlocked(String account, bool blocked) async {}

  @override
  Future<void> remove(String account) async {}

  @override
  Future<DeviceListResult> devices({String? peer}) async =>
      const DeviceListResult.empty();
}
