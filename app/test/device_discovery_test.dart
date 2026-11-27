// 账号发现、搜索、合规地图与独立栏目的 Flutter 测试。
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/remote/device_map_page.dart';
import 'package:nexmem_app/features/remote/ip_location.dart';
import 'package:nexmem_app/features/remote/local_location_controller.dart';
import 'package:nexmem_app/features/remote/remote_device_directory.dart';
import 'package:nexmem_app/features/remote/remote_geo_controller.dart';
import 'package:nexmem_app/features/remote/remote_devices_page.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/features/remote/remote_storage.dart';
import 'package:nexmem_app/features/settings/settings_page.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';

class _MemoryStorage implements RemoteStorage {
  final Map<String, Map<String, dynamic>> json = <String, Map<String, dynamic>>{};
  final Map<String, List<String>> lines = <String, List<String>>{};

  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name];

  @override
  Future<void> writeJson(String name, Map<String, dynamic> data) async =>
      json[name] = data;

  @override
  Future<List<String>> readLines(String name) async => lines[name] ?? const <String>[];

  @override
  Future<void> appendLine(String name, String line) async =>
      lines.putIfAbsent(name, () => <String>[]).add(line);

  @override
  Future<void> clear(String name) async {
    json.remove(name);
    lines.remove(name);
  }

  @override
  Future<String> saveDownload(String fileName, List<int> bytes) async => fileName;
}

class _WritableSettings implements SettingsService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (value.isEmpty) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<SettingsSnapshot> exportSnapshot() async =>
      SettingsSnapshot(snapshot: 'settings://v1/', count: values.length);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async => 0;
}

class _NoopSettings implements SettingsService {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<SettingsSnapshot> exportSnapshot() async =>
      SettingsSnapshot(snapshot: 'settings://v1/', count: 0);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async => 0;
}

Future<DeviceDiscoverPage> _emptyDiscover({
  required int limit,
  required int offset,
}) async {
  return DeviceDiscoverPage(
    items: const <DiscoveredDevice>[],
    total: 0,
    offset: offset,
    limit: limit,
  );
}

Future<DeviceDiscoverPage> _discoverOne(
  DiscoveredDevice device, {
  required int limit,
  required int offset,
}) async {
  return DeviceDiscoverPage(
    items: <DiscoveredDevice>[device],
    total: 1,
    offset: offset,
    limit: limit,
  );
}

void main() {
  group('账号发现模型', () {
    test('解析分页结果与来源字段', () {
      final DeviceDiscoverPage page = DeviceDiscoverPage.fromJson(<String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'peer_id': '12D3KooWpeer',
            'account_id': 'ab' * 32,
            'label': '书房设备',
            'addrs': <String>['/ip4/192.168.1.20/tcp/4001'],
            'ip': '192.168.1.20',
            'connected': true,
            'direct': true,
            'relayed': false,
            'source': 'peerbook,mdns',
            'last_seen': 1700000000000,
          },
        ],
        'total': 7,
        'offset': 0,
        'limit': 50,
      });
      expect(page.total, 7);
      expect(page.hasMore, isTrue);
      final DiscoveredDevice device = page.items.single;
      expect(device.peerId, '12D3KooWpeer');
      expect(device.displayName, '书房设备');
      expect(device.directoryKey, 'ab' * 32);
      expect(device.ip, '192.168.1.20');
      expect(device.connected, isTrue);
      expect(device.direct, isTrue);
      expect(device.source, 'peerbook,mdns');
      expect(device.lastSeen, 1700000000000);
    });

    test('无备注时优先展示 IP 并回退 PeerID', () {
      final DiscoveredDevice withIp = DiscoveredDevice(
        peerId: 'peer-long-id',
        addrs: const <String>[],
        ip: '198.51.100.7',
      );
      final DiscoveredDevice plain = DiscoveredDevice(
        peerId: 'peer-long-id-abcdef',
        addrs: const <String>[],
      );
      expect(withIp.displayName, '198.51.100.7');
      expect(plain.displayName, 'peer-long-id');
      expect(plain.directoryKey, 'peer-long-id-abcdef');
    });
  });

  testWidgets('远程设备页只保留台账管理与群控入口', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    await dir.add(peer: 'p1', name: '书房 Mac', type: RemoteDeviceType.macos, note: '办公室备用');
    await dir.add(peer: 'p2', name: '客厅 Windows', type: RemoteDeviceType.windows);

    await tester.pumpWidget(MaterialApp(
      home: RemoteDevicesPage(
        directory: dir,
        embedded: false,
        actions: RemoteDevicesActions(sessions: const <String, RemoteInfo>{}),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('远程设备'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-devices-add')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-devices-search')), findsOneWidget);
    expect(find.text('书房 Mac'), findsOneWidget);
    expect(find.text('客厅 Windows'), findsOneWidget);

    // 发现相关能力已从台账页彻底移除，避免用户把两类设备混在一起。
    expect(find.byKey(const ValueKey<String>('remote-devices-scan')), findsNothing);
    expect(find.byKey(const ValueKey<String>('remote-devices-map')), findsNothing);
    expect(find.byKey(const ValueKey<String>('device-discovery-auto-geo')), findsNothing);
    expect(find.byKey(const ValueKey<String>('device-discovery-local-location')), findsNothing);
    expect(find.textContaining('点击右上角添加或扫描发现'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-devices-search')),
      '办公室备用',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('书房 Mac'), findsOneWidget);
    expect(find.text('客厅 Windows'), findsNothing);
  });

  testWidgets('账号发现页支持搜索、地图入口与添加好友', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();

    bool mapOpened = false;
    String? addedAccount;
    Future<DeviceDiscoverPage> discover({
      required int limit,
      required int offset,
    }) async {
      return DeviceDiscoverPage(
        items: <DiscoveredDevice>[
          DiscoveredDevice(
            peerId: 'peer-12D3KooWabc',
            accountId: 'cd' * 32,
            addrs: const <String>['/ip4/192.168.1.44/tcp/4001'],
            label: '书房 NAS',
            ip: '192.168.1.44',
            connected: true,
            source: 'peerbook,mdns',
          ),
          DiscoveredDevice(
            peerId: 'peer-other',
            accountId: 'ef' * 32,
            addrs: const <String>['/ip4/192.168.1.45/tcp/4001'],
            label: '客厅电视',
            ip: '192.168.1.45',
            source: 'mdns',
          ),
        ],
        total: 2,
        offset: offset,
        limit: limit,
      );
    }

    await tester.pumpWidget(MaterialApp(
      home: DeviceDiscoverySheet(
        directory: dir,
        onAddFriend: (device) async {
          addedAccount = device.accountId;
          return true;
        },
        embedded: false,
        discover: discover,
        onOpenMap: () => mapOpened = true,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('账号发现'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('device-discovery-map')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('device-discovery-refresh')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('device-discovery-list')), findsOneWidget);
    expect(find.text('书房 NAS'), findsOneWidget);
    expect(find.text('客厅电视'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('device-discovery-search')),
      '客厅',
    );
    await tester.pumpAndSettle();
    expect(find.text('书房 NAS'), findsNothing);
    expect(find.text('客厅电视'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('device-discovery-map')));
    await tester.pumpAndSettle();
    expect(mapOpened, isTrue);

    await tester.enterText(
      find.byKey(const ValueKey<String>('device-discovery-search')),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
      const ValueKey<String>('device-discovery-add-peer-12D3KooWabc'),
    ));
    await tester.pumpAndSettle();
    // 账号发现只发好友申请：不弹远控密码，也不写远程设备台账。
    expect(
      find.byKey(const ValueKey<String>('remote-password-input')),
      findsNothing,
    );
    expect(addedAccount, 'cd' * 32);
    expect(find.text('已发送好友申请'), findsOneWidget);
    expect(dir.devices, isEmpty);
  });

  testWidgets('账号发现页嵌入右栏时仍显示地图入口', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    bool mapOpened = false;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DeviceDiscoverySheet(
          directory: dir,
          onAddFriend: (device) async => true,
          embedded: true,
          discover: _emptyDiscover,
          onOpenMap: () => mapOpened = true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('账号发现'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('device-discovery-map')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('device-discovery-map')));
    await tester.pumpAndSettle();
    expect(mapOpened, isTrue);
  });

  group('设备地图 HTML', () {
    test('默认代理模式不写 Key 且保留占位符', () {
      final String html = buildDeviceMapHtml(
        devices: <RemoteDevice>[
          RemoteDevice(
            peer: 'p1',
            name: '书房 Mac',
            latitude: 22.54,
            longitude: 114.06,
            region: '深圳南山',
          ),
        ],
        key: '',
        useWorkBuddyProxy: true,
      );
      expect(html, contains('_TMapSecurityConfig'));
      expect(html, contains('__WB_HTTP_PORT__'));
      expect(html, contains('__WB_TMAP_SECRET__'));
      expect(html, isNot(contains('key=')));
      expect(html, contains('书房 Mac'));
    });

    test('自备 Key 模式把 Key 编码进 SDK 地址且不使用代理', () {
      final String html = buildDeviceMapHtml(
        devices: const <RemoteDevice>[],
        key: 'test key/+',
        useWorkBuddyProxy: false,
      );
      expect(html, contains('key=test%20key%2F%2B'));
      expect(html, isNot(contains('_TMapSecurityConfig')));
    });
  });

  testWidgets('自动归属地启用前显示隐私同意说明', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    final IpLocationService service = IpLocationService(
      downloader: ({required String url, void Function(int, int)? onProgress}) async {
        throw StateError('测试中不应下载');
      },
    );
    final RemoteGeoController geo = RemoteGeoController(
      service: service,
      settings: _NoopSettings(),
      directory: dir,
    );
    addTearDown(geo.dispose);

    await tester.pumpWidget(MaterialApp(
      home: DeviceDiscoverySheet(
        directory: dir,
        onAddFriend: (device) async => true,
        discover: _emptyDiscover,
        geo: geo,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('device-discovery-auto-geo')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('device-discovery-auto-geo')));
    await tester.pumpAndSettle();
    expect(find.text('启用自动归属地'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('device-discovery-geo-confirm')), findsOneWidget);
    expect(find.text('同意并启用'), findsOneWidget);
    expect(
      find.text(
        '程序已内置离线 IP 库，启用后依据 P2P 连接中的 IP 在本机推断省市与地图中心点。'
        '不会上传你的 IP 或位置，也不会把归属地发送给对端；已手动填写的地区和坐标不会被覆盖。',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('device-discovery-geo-mirror')), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(geo.enabled, isFalse);
  });

  testWidgets('确认后使用内置库启用自动归属地，不需要下载', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    final ByteData data = await rootBundle.load(kIpLocationBundledAsset);
    final IpLocationService service = IpLocationService(
      downloader: ({required String url, void Function(int, int)? onProgress}) async {
        throw StateError('启用内置库时不应下载');
      },
      readBundled: () async =>
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final RemoteGeoController geo = RemoteGeoController(
      service: service,
      settings: _NoopSettings(),
      directory: dir,
    );
    addTearDown(geo.dispose);

    await tester.pumpWidget(MaterialApp(
      home: DeviceDiscoverySheet(
        directory: dir,
        onAddFriend: (device) async => true,
        discover: _emptyDiscover,
        geo: geo,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('device-discovery-auto-geo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('device-discovery-geo-confirm')));
    await tester.pumpAndSettle();

    expect(geo.enabled, isTrue);
    expect(service.loaded, isTrue);
    expect(service.lookup('114.114.114.114'), isNotNull);
  });

  testWidgets('本机位置入口可打开设置弹窗并保存坐标', (WidgetTester tester) async {
    // 桌面端保留手工输入作为调试兜底；移动端只展示「使用系统定位」。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    final _WritableSettings settings = _WritableSettings();
    final LocalLocationController local = LocalLocationController(settings: settings);
    addTearDown(local.dispose);
    await local.load();

    await tester.pumpWidget(MaterialApp(
      home: DeviceDiscoverySheet(
        directory: dir,
        onAddFriend: (device) async => true,
        discover: _emptyDiscover,
        localLocation: local,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('device-discovery-local-location')));
    await tester.pumpAndSettle();
    // 一处是发现页状态行的入口，一处是弹窗标题。
    expect(find.text('设置本机位置'), findsNWidgets(2));
    expect(find.byKey(const ValueKey<String>('local-location-latitude')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('local-location-longitude')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('local-location-latitude')),
      '22.54',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('local-location-longitude')),
      '114.06',
    );
    await tester.tap(find.byKey(const ValueKey<String>('local-location-save')));
    // 保存按钮是异步回调，先让 microtask 完成再推进弹窗退出动画。
    await tester.pump();
    await tester.pumpAndSettle();

    expect(local.hasLocation, isTrue);
    expect(local.latitude, 22.54);
    expect(local.longitude, 114.06);
  });

  testWidgets('账号发现页在本机位置与设备坐标都可用时显示距离', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    await dir.add(
      peer: 'account-sh',
      name: '上海设备',
      latitude: 31.23,
      longitude: 121.47,
    );
    final LocalLocationController local = LocalLocationController(
      settings: _WritableSettings(),
    );
    addTearDown(local.dispose);
    await local.save(22.54, 114.06);

    final DiscoveredDevice device = DiscoveredDevice(
      peerId: 'peer-sh',
      accountId: 'account-sh',
      addrs: const <String>['/ip4/203.0.113.9/tcp/4001'],
      label: '上海设备',
      ip: '203.0.113.9',
      source: 'mdns',
    );

    await tester.pumpWidget(MaterialApp(
      home: DeviceDiscoverySheet(
        directory: dir,
        onAddFriend: (device) async => true,
        discover: ({required int limit, required int offset}) =>
            _discoverOne(device, limit: limit, offset: offset),
        localLocation: local,
      ),
    ));
    await tester.pumpAndSettle();

    // 发现页已成为独立栏目，本机位置状态只保留一处。
    expect(find.text('本机位置已设置'), findsOneWidget);
    expect(find.textContaining('距离约'), findsOneWidget);
    expect(find.textContaining('km'), findsOneWidget);
  });

  testWidgets('未设置本机位置时不显示距离并提示设置', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    final LocalLocationController local = LocalLocationController(
      settings: _WritableSettings(),
    );
    addTearDown(local.dispose);
    await local.load();

    final DiscoveredDevice device = DiscoveredDevice(
      peerId: 'peer-noloc',
      accountId: 'account-noloc',
      addrs: const <String>['/ip4/198.51.100.7/tcp/4001'],
      label: '无位置设备',
      ip: '198.51.100.7',
    );

    await tester.pumpWidget(MaterialApp(
      home: DeviceDiscoverySheet(
        directory: dir,
        onAddFriend: (device) async => true,
        discover: ({required int limit, required int offset}) =>
            _discoverOne(device, limit: limit, offset: offset),
        localLocation: local,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('未设置本机位置，无法计算距离'), findsOneWidget);
    expect(find.textContaining('距离约'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('device-discovery-local-location')),
      findsOneWidget,
    );
  });

  testWidgets('「我的」页提供独立账号发现入口', (WidgetTester tester) async {
    String? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPage(
          profileOnly: true,
          onOpenPane: (String label) => opened = label,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final Finder entry = find.byKey(
      const ValueKey<String>('settings-device-discovery'),
    );
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(opened, '账号发现');
  });
}
