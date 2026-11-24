// P6-21 验收：设备列表读取公开档案、本机标记、空态/错误重试与资料页内联展示。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/contacts/contact.dart';
import 'package:nexmem_app/features/contacts/contact_detail_page.dart';
import 'package:nexmem_app/features/contacts/contact_service.dart';
import 'package:nexmem_app/features/contacts/device_list_page.dart';
import 'package:nexmem_app/transport/transport.dart';

typedef _Handler = Object? Function(Map<String, dynamic>? params);

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handlers);

  final Map<String, _Handler> handlers;
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
  _FakeContactService({this.result = const DeviceListResult.empty()});

  DeviceListResult result;
  NexmemException? error;
  String? lastPeer;
  int deviceCalls = 0;

  @override
  Future<DeviceListResult> devices({String? peer}) async {
    deviceCalls++;
    lastPeer = peer;
    final NexmemException? failure = error;
    if (failure != null) {
      throw failure;
    }
    return result;
  }

  @override
  Future<List<Contact>> list({int limit = 200}) async => const <Contact>[];

  @override
  Future<Contact> add(String account, {String alias = ''}) async =>
      throw UnimplementedError();

  @override
  Future<void> setRemark(String account, String remark) async {}

  @override
  Future<void> setGroup(String account, String group) async {}

  @override
  Future<void> setBlocked(String account, bool blocked) async {}

  @override
  Future<void> remove(String account) async {}
}

const DeviceInfo _phone = DeviceInfo(
  name: 'Pixel 8',
  deviceId: '12D3KooWabcdefghijklmnopqrstuvwxyz',
  issuedAt: null,
  notAfter: null,
  current: true,
);

const DeviceInfo _tablet = DeviceInfo(
  name: '平板',
  deviceId: '12D3KooWzyxwvutsrqponmlkjihgfedcba',
  issuedAt: null,
  notAfter: null,
  current: false,
);

Widget _wrap(Widget child) {
  return MaterialApp(theme: NexmemTheme.light(), home: child);
}

void main() {
  test('TransportContactService.devices 解析设备字段并按需传 peer', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'account.devices': (Map<String, dynamic>? params) {
        return <String, dynamic>{
          'items': <Object?>[
            <String, dynamic>{
              'device_name': 'Pixel 8',
              'device_id': '12D3KooWabc',
              'issued_at': 1730000000,
              'not_after': 1761536000,
              'current': true,
            },
            <String, dynamic>{},
          ],
          'found': true,
          'self': true,
        };
      },
    });
    final TransportContactService service = TransportContactService(transport);
    final DeviceListResult result = await service.devices();
    expect(transport.params.single, isEmpty);
    expect(result.found, isTrue);
    expect(result.self, isTrue);
    expect(result.items, hasLength(2));
    expect(result.items.first.name, 'Pixel 8');
    expect(result.items.first.deviceId, '12D3KooWabc');
    expect(result.items.first.issuedAt, isNotNull);
    expect(result.items.first.current, isTrue);
    // 缺字段的条目降级为「未命名设备」，不抛异常。
    expect(result.items.last.name, '未命名设备');
    expect(result.items.last.current, isFalse);

    await service.devices(peer: 'aabb');
    expect(transport.params.last, <String, dynamic>{'peer': 'aabb'});
  });

  test('deviceActiveLabel 按时间段给出活跃文案', () {
    expect(deviceActiveLabel(null), '最近活跃未知');
    expect(deviceActiveLabel(DateTime.now()), '刚刚活跃');
    expect(
      deviceActiveLabel(DateTime.now().subtract(const Duration(hours: 3))),
      '3 小时前活跃',
    );
    expect(
      deviceActiveLabel(DateTime.now().subtract(const Duration(days: 2))),
      '2 天前活跃',
    );
  });

  testWidgets('设备列表展示名称、本机标记与有效期', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService(
      result: DeviceListResult(
        items: <DeviceInfo>[
          _phone.copyWithIssued(DateTime.now()),
          _tablet.copyWithIssued(DateTime.now()),
        ],
        found: true,
        self: true,
      ),
    );
    await tester.pumpWidget(_wrap(DeviceListPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text('平板'), findsOneWidget);
    expect(find.text('本机'), findsOneWidget);
    expect(find.textContaining('最近一次发布档案'), findsOneWidget);
  });

  testWidgets('未发布档案时给出空态提示', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService();
    await tester.pumpWidget(_wrap(DeviceListPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('尚未发布设备信息'), findsOneWidget);
    expect(find.text('重新检查'), findsOneWidget);
  });

  testWidgets('读取失败给出错误与重试入口', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService()
      ..error = const NexmemException('NOT_STARTED', '未配置索引服务');
    await tester.pumpWidget(_wrap(DeviceListPage(service: service)));
    await tester.pumpAndSettle();

    expect(find.text('设备列表读取失败'), findsOneWidget);
    expect(find.text('未配置索引服务'), findsOneWidget);

    service
      ..error = null
      ..result = const DeviceListResult(items: <DeviceInfo>[_tablet], found: true, self: true);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('平板'), findsOneWidget);
    expect(service.deviceCalls, 2);
  });

  testWidgets('好友资料页内联展示设备并可进入全部设备', (WidgetTester tester) async {
    final _FakeContactService service = _FakeContactService(
      result: const DeviceListResult(
        items: <DeviceInfo>[_phone, _tablet],
        found: true,
        self: false,
      ),
    );
    await tester.pumpWidget(
      _wrap(
        ContactDetailPage(
          contact: const Contact(id: 'peer-1', name: '老王'),
          service: service,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(service.lastPeer, 'peer-1');
    expect(find.text('设备（2 台）'), findsOneWidget);
    expect(find.textContaining('Pixel 8'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('contact-devices-tile')));
    await tester.pumpAndSettle();

    expect(find.text('老王的设备'), findsOneWidget);
  });
}

extension on DeviceInfo {
  DeviceInfo copyWithIssued(DateTime at) => DeviceInfo(
        name: name,
        deviceId: deviceId,
        issuedAt: at,
        notAfter: null,
        current: current,
      );
}
