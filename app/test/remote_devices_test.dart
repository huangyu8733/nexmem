// 远程设备目录与「我的 → 远程设备」页面测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/remote/remote_device_directory.dart';
import 'package:nexmem_app/features/remote/remote_devices_page.dart';
import 'package:nexmem_app/features/remote/remote_group_controller.dart';
import 'package:nexmem_app/features/remote/remote_password.dart';
import 'package:nexmem_app/features/remote/remote_input_codec.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/features/remote/remote_storage.dart';

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

class _FakeGroupService implements RemoteGroupService {
  _FakeGroupService(this.info);

  RemoteInfo? info;

  @override
  RemoteInfo? get current => info;

  @override
  Future<void> sendKey(String key, {required bool down, int modifiers = 0}) async {}

  @override
  Future<void> sendCombo(String key, {int modifiers = 0}) async {}

  @override
  Future<void> sendText(String text) async {}

  @override
  Future<void> sendPointer(RemotePointerEvent event) async {}

  @override
  Future<void> sendTouch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  }) async {}

  @override
  Future<void> sendClipboardText(String text) async {}

  @override
  Future<void> end({String reason = '会话已结束'}) async {
    info = null;
  }
}

RemoteInfo _activeInfo(String peer, String name) => RemoteInfo(
      sid: 'sid-$peer',
      peer: peer,
      peerName: name,
      role: RemoteRole.controller,
      state: RemoteState.active,
      permissions: RemotePermissions.all,
    );

void main() {
  group('RemoteDeviceDirectory', () {
    test('增改删与持久化', () async {
      final _MemoryStorage storage = _MemoryStorage();
      final RemoteDeviceDirectory dir = RemoteDeviceDirectory(storage);
      await dir.load();

      final RemoteDevice added = await dir.add(
        peer: 'peer-a',
        name: 'MacBook',
        type: RemoteDeviceType.macos,
        note: '办公室',
        nowMs: 1000,
      );
      expect(added.peer, 'peer-a');
      expect(dir.devices.length, 1);

      await dir.update('peer-a', name: 'Mac', type: RemoteDeviceType.windows);
      expect(dir.devices.single.name, 'Mac');
      expect(dir.devices.single.type, RemoteDeviceType.windows);

      // 新实例从存储恢复。
      final RemoteDeviceDirectory reloaded = RemoteDeviceDirectory(storage);
      await reloaded.load();
      expect(reloaded.devices.single.name, 'Mac');
      expect(reloaded.devices.single.type, RemoteDeviceType.windows);

      await reloaded.remove('peer-a');
      expect(reloaded.devices, isEmpty);

      final RemoteDeviceDirectory after = RemoteDeviceDirectory(storage);
      await after.load();
      expect(after.devices, isEmpty);
    });

    test('重复添加同一账号只更新不产生重复项', () async {
      final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
      await dir.load();
      await dir.add(peer: 'p', name: 'A', nowMs: 1);
      await dir.add(peer: 'p', name: 'B', type: RemoteDeviceType.android, nowMs: 2);
      expect(dir.devices.length, 1);
      expect(dir.devices.single.name, 'B');
      expect(dir.devices.single.type, RemoteDeviceType.android);
    });

    test('类型筛选只显示对应设备', () async {
      final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
      await dir.load();
      await dir.add(peer: 'p1', name: 'A', type: RemoteDeviceType.windows, nowMs: 1);
      await dir.add(peer: 'p2', name: 'B', type: RemoteDeviceType.macos, nowMs: 2);
      expect(
        dir.devices.where((RemoteDevice d) => d.type == RemoteDeviceType.macos).length,
        1,
      );
    });

    test('密码校验值随台账持久化且不保存明文', () async {
      final _MemoryStorage storage = _MemoryStorage();
      final RemoteDeviceDirectory dir = RemoteDeviceDirectory(storage);
      await dir.load();
      final String credential = remotePasswordCredential('123456');
      await dir.add(peer: 'p', name: 'A', credential: credential, nowMs: 1);

      final String raw = storage.json['devices.json'].toString();
      expect(raw, contains(credential));
      expect(raw, isNot(contains('123456')));

      final RemoteDeviceDirectory reloaded = RemoteDeviceDirectory(storage);
      await reloaded.load();
      expect(reloaded.devices.single.credential, credential);
    });
  });

  testWidgets('远程设备页展示台账、类型筛选与群控开关', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    await dir.add(peer: 'p1', name: '设备一', type: RemoteDeviceType.macos, nowMs: 1);
    await dir.add(peer: 'p2', name: '设备二', type: RemoteDeviceType.macos, nowMs: 2);
    await dir.add(peer: 'p3', name: '设备三', type: RemoteDeviceType.windows, nowMs: 3);

    final Map<String, RemoteGroupService> services = <String, RemoteGroupService>{
      'p1': _FakeGroupService(_activeInfo('p1', '设备一')),
      'p2': _FakeGroupService(_activeInfo('p2', '设备二')),
      'p3': _FakeGroupService(_activeInfo('p3', '设备三')),
    };
    final RemoteGroupController group = RemoteGroupController(
      services: services,
      deviceTypeOf: (String peer) => dir.find(peer)?.type ?? RemoteDeviceType.other,
    );

    await tester.pumpWidget(MaterialApp(
      home: RemoteDevicesPage(
        directory: dir,
        embedded: false,
        actions: RemoteDevicesActions(
          sessions: <String, RemoteInfo>{
            'p1': _activeInfo('p1', '设备一'),
            'p2': _activeInfo('p2', '设备二'),
            'p3': _activeInfo('p3', '设备三'),
          },
          groupController: group,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('设备一'), findsOneWidget);
    expect(find.text('设备二'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-devices-add')), findsOneWidget);

    final SwitchListTile toggle = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('remote-devices-group-enabled')),
    );
    expect(toggle.value, isFalse);

    // 切换到 macOS 类型后只显示两台 Mac，Windows 设备被隐藏。
    await tester.tap(find.byKey(const ValueKey<String>('remote-devices-filter-macos')));
    await tester.pumpAndSettle();
    expect(find.text('设备一'), findsOneWidget);
    expect(find.text('设备二'), findsOneWidget);
    expect(find.text('设备三'), findsNothing);
    expect(group.groupType, RemoteDeviceType.macos);

    // 同类型两台在线，群控开关可用且只勾选两台 Mac。
    await tester.tap(find.byKey(const ValueKey<String>('remote-devices-group-enabled')));
    await tester.pumpAndSettle();
    expect(group.enabled, isTrue);
    expect(group.targetCount, 2);
    expect(group.isSelected('p3'), isFalse);
  });

  testWidgets('同类型在线设备可直接勾选，选择设备入口打开完整面板',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    await dir.add(peer: 'p1', name: '设备一', type: RemoteDeviceType.macos, nowMs: 1);
    await dir.add(peer: 'p2', name: '设备二', type: RemoteDeviceType.macos, nowMs: 2);
    await dir.add(peer: 'p3', name: '设备三', type: RemoteDeviceType.windows, nowMs: 3);

    final Map<String, RemoteGroupService> services = <String, RemoteGroupService>{
      'p1': _FakeGroupService(_activeInfo('p1', '设备一')),
      'p2': _FakeGroupService(_activeInfo('p2', '设备二')),
      'p3': _FakeGroupService(_activeInfo('p3', '设备三')),
    };
    final RemoteGroupController group = RemoteGroupController(
      services: services,
      deviceTypeOf: (String peer) => dir.find(peer)?.type ?? RemoteDeviceType.other,
    );
    int connects = 0;
    await tester.pumpWidget(MaterialApp(
      home: RemoteDevicesPage(
        directory: dir,
        embedded: false,
        actions: RemoteDevicesActions(
          sessions: <String, RemoteInfo>{
            'p1': _activeInfo('p1', '设备一'),
            'p2': _activeInfo('p2', '设备二'),
            'p3': _activeInfo('p3', '设备三'),
          },
          groupController: group,
          onConnect: (_, _) => connects++,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 默认类型「其他」下没有同类型在线设备，不渲染勾选框。
    expect(find.byKey(const ValueKey<String>('remote-devices-select-p1')),
        findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('remote-devices-filter-macos')));
    await tester.pumpAndSettle();

    // 两台 Mac 都显示勾选框；Windows 设备不显示。
    expect(find.byKey(const ValueKey<String>('remote-devices-select-p1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-devices-select-p2')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-devices-select-p3')),
        findsNothing);

    // 切换类型后勾选为空，由用户自己挑；「全选」后会列出设备名。
    expect(find.byKey(const ValueKey<String>('remote-devices-selected-设备一')),
        findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('remote-devices-select-all')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('remote-devices-selected-设备一')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-devices-selected-设备二')),
        findsOneWidget);

    // 点勾选框只切换群控选中，不会误触发「断开/连接」。
    await tester.tap(find.byKey(const ValueKey<String>('remote-devices-select-p1')));
    await tester.pumpAndSettle();
    expect(group.isSelected('p1'), isFalse);
    expect(connects, 0);

    // 「选择设备」入口打开完整的类型选择 + 勾选面板。
    await tester.tap(
      find.byKey(const ValueKey<String>('remote-devices-select-device')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RemoteGroupSheet), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-group-type')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('remote-device-p1')), findsOneWidget);
  });

  testWidgets('会话掉线后重建页面会同步群控开关，避免出现假群控中',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    await dir.add(peer: 'p1', name: '设备一', type: RemoteDeviceType.macos, nowMs: 1);
    await dir.add(peer: 'p2', name: '设备二', type: RemoteDeviceType.macos, nowMs: 2);

    final Map<String, RemoteGroupService> services = <String, RemoteGroupService>{
      'p1': _FakeGroupService(_activeInfo('p1', '设备一')),
      'p2': _FakeGroupService(_activeInfo('p2', '设备二')),
    };
    final RemoteGroupController group = RemoteGroupController(
      services: services,
      deviceTypeOf: (String peer) => dir.find(peer)?.type ?? RemoteDeviceType.other,
    );
    group.setGroupType(RemoteDeviceType.macos);
    group.setEnabled(true);
    expect(group.enabled, isTrue);

    Widget buildPage() => MaterialApp(
          home: RemoteDevicesPage(
            directory: dir,
            embedded: false,
            actions: RemoteDevicesActions(
              sessions: <String, RemoteInfo>{
                'p1': _activeInfo('p1', '设备一'),
                'p2': _activeInfo('p2', '设备二'),
              },
              groupController: group,
            ),
          ),
        );
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();
    final SwitchListTile enabledTile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('remote-devices-group-enabled')),
    );
    expect(enabledTile.value, isTrue);

    // 两台设备掉线：壳层重建时会对控制器调用 sync，目标不足两台自动退出群控。
    services['p1'] = _FakeGroupService(null);
    services['p2'] = _FakeGroupService(null);
    group.sync();
    expect(group.enabled, isFalse);

    // 父级以新的会话快照重建页面（State 复用，不重跑 initState）。
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteDevicesPage(
          directory: dir,
          embedded: false,
          actions: RemoteDevicesActions(
            sessions: const <String, RemoteInfo>{},
            groupController: group,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final SwitchListTile afterTile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('remote-devices-group-enabled')),
    );
    expect(afterTile.value, isFalse);
  });

  testWidgets('添加远程设备必须填写密码并只保存校验值', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RemoteDevicesPage(
          directory: dir,
          embedded: false,
          actions: RemoteDevicesActions(
            sessions: const <String, RemoteInfo>{},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('remote-devices-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('remote-device-password')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('remote-device-password-confirm')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('remote-device-region')), findsNothing);
    expect(find.byKey(const ValueKey<String>('remote-device-lat')), findsNothing);
    expect(find.byKey(const ValueKey<String>('remote-device-lng')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-peer')),
      'peer-pwd',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-name')),
      '书房电脑',
    );
    await tester.tap(find.byKey(const ValueKey<String>('remote-device-save')));
    await tester.pumpAndSettle();
    expect(find.text('远程控制密码至少 6 位'), findsOneWidget);
    expect(dir.devices, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-password')),
      '123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-password-confirm')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey<String>('remote-device-save')));
    await tester.pumpAndSettle();

    expect(dir.devices.single.peer, 'peer-pwd');
    expect(dir.devices.single.credential, remotePasswordCredential('123456'));
  });

  testWidgets('备注包含换行不会污染远控密码校验值', (WidgetTester tester) async {
    final RemoteDeviceDirectory dir = RemoteDeviceDirectory(_MemoryStorage());
    await dir.load();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RemoteDevicesPage(
          directory: dir,
          embedded: false,
          actions: RemoteDevicesActions(
            sessions: const <String, RemoteInfo>{},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('remote-devices-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-peer')),
      'peer-note',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-note')),
      '第一行\n第二行',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-password')),
      '123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('remote-device-password-confirm')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey<String>('remote-device-save')));
    await tester.pumpAndSettle();

    expect(dir.devices.single.note, '第一行\n第二行');
    expect(dir.devices.single.credential, remotePasswordCredential('123456'));
  });
}
