// 远控群控验收：设备管理列表、勾选、输入广播与批量断开。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/remote/remote_control_page.dart';
import 'package:nexmem_app/features/remote/remote_device_directory.dart';
import 'package:nexmem_app/features/remote/remote_group_controller.dart';
import 'package:nexmem_app/features/remote/remote_input_codec.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';

class _FakeService implements RemoteGroupService {
  _FakeService(
    this.peer, {
    this.name = '',
    this.input = true,
    this.clipboard = true,
    this.state = RemoteState.active,
  });

  final String peer;
  final String name;
  final bool input;
  final bool clipboard;
  final RemoteState state;

  final List<String> keys = <String>[];
  final List<String> texts = <String>[];
  final List<RemotePointerEvent> pointers = <RemotePointerEvent>[];
  final List<String> clipboardTexts = <String>[];
  int endCount = 0;

  @override
  RemoteInfo get current => RemoteInfo(
        sid: 'sid-$peer',
        peer: peer,
        peerName: name,
        role: RemoteRole.controller,
        state: state,
        permissions: RemotePermissions(
          input: input,
          clipboard: clipboard,
          file: false,
        ),
      );

  final List<(String, int)> combos = <(String, int)>[];

  @override
  Future<void> sendKey(String key, {required bool down, int modifiers = 0}) async {
    keys.add('$key:${down ? 'down' : 'up'}');
  }

  @override
  Future<void> sendCombo(String key, {int modifiers = 0}) async {
    combos.add((key, modifiers));
  }

  @override
  Future<void> sendText(String text) async => texts.add(text);

  @override
  Future<void> sendPointer(RemotePointerEvent event) async =>
      pointers.add(event);

  final List<(String, List<Map<String, int>>, int)> touches =
      <(String, List<Map<String, int>>, int)>[];

  @override
  Future<void> sendTouch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  }) async {
    touches.add((phase, points, modifiers));
  }

  @override
  Future<void> sendClipboardText(String text) async =>
      clipboardTexts.add(text);

  @override
  Future<void> end({String reason = '会话已结束'}) async => endCount++;
}

RemoteInfo _pageInfo() => RemoteInfo(
      sid: 'sid-1',
      peer: 'p1',
      peerName: '设备 A',
      role: RemoteRole.controller,
      state: RemoteState.active,
      permissions: RemotePermissions.all,
    );

void main() {
  group('群控服务', () {
    test('默认勾选全部已连接设备，关闭时不广播', () async {
      final _FakeService a = _FakeService('p1', name: '设备 A');
      final _FakeService b = _FakeService('p2', name: '设备 B');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );

      expect(group.canGroup, isTrue);
      expect(group.targetCount, 2);
      expect(group.enabled, isFalse);

      await group.broadcastText('hello');
      expect(a.texts, isEmpty);
      expect(b.texts, isEmpty);
    });

    test('开启后按键、文字、指针与剪贴板广播到所有勾选设备', () async {
      final _FakeService a = _FakeService('p1', name: '设备 A');
      final _FakeService b = _FakeService('p2', name: '设备 B');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );
      group.setEnabled(true);

      await group.broadcastKey('enter', down: true);
      await group.broadcastCombo('c', modifiers: RemoteModifiers.control);
      await group.broadcastText('hello');
      await group.broadcastPointer(const RemotePointerEvent(
        type: RemotePointerType.move,
        xNorm: 100,
        yNorm: 200,
      ));
      await group.broadcastClipboard('copy');

      expect(a.keys, <String>['enter:down']);
      expect(b.keys, <String>['enter:down']);
      expect(a.combos, <(String, int)>[('c', RemoteModifiers.control)]);
      expect(b.combos, <(String, int)>[('c', RemoteModifiers.control)]);
      expect(a.texts, <String>['hello']);
      expect(b.texts, <String>['hello']);
      expect(a.pointers.single.xNorm, 100);
      expect(b.pointers.single.yNorm, 200);
      expect(a.clipboardTexts, <String>['copy']);
      expect(b.clipboardTexts, <String>['copy']);
    });

    test('清空勾选后重复同步不会把设备重新选上', () {
      final _FakeService a = _FakeService('p1');
      final _FakeService b = _FakeService('p2');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );
      group.setEnabled(true);
      expect(group.targetCount, 2);

      group.clearSelection();
      expect(group.targetCount, 0);

      // 壳层每次 build 都会调用 sync 刷新在线会话；清空状态必须保持。
      group.sync();
      group.sync();
      expect(group.targetCount, 0);

      // 用户重新开启群控时恢复默认全选。
      group.setEnabled(true);
      expect(group.targetCount, 2);
    });

    test('取消勾选到只剩一台时自动退出群控', () async {
      final _FakeService a = _FakeService('p1');
      final _FakeService b = _FakeService('p2');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );
      group.setEnabled(true);
      expect(group.enabled, isTrue);

      group.toggle('p1');
      expect(group.enabled, isFalse);
      expect(group.selected, isEmpty);

      await group.broadcastText('hello');
      expect(a.texts, isEmpty);
      expect(b.texts, isEmpty);
    });

    test('取消勾选与权限过滤生效，断开只影响勾选设备', () async {
      final _FakeService a = _FakeService('p1');
      final _FakeService b = _FakeService('p2', input: false, clipboard: false);
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );
      group.setEnabled(true);
      group.toggle('p1');
      expect(group.enabled, isFalse);
      expect(group.targetCount, 0);
      await group.broadcastText('ignored');
      expect(a.texts, isEmpty, reason: '取消勾选后群控已退出，不再广播');

      group.selectAll();
      group.setEnabled(true);
      await group.broadcastText('hello');
      expect(a.texts, <String>['hello']);
      expect(b.texts, isEmpty, reason: '未授权键鼠的设备不参与群控');

      await group.broadcastClipboard('copy');
      expect(a.clipboardTexts, <String>['copy']);
      expect(b.clipboardTexts, isEmpty);

      // 批量断开不依赖群控开关，只作用于当前勾选设备。
      group.clearSelection();
      group.toggle('p1');
      expect(group.targetCount, 1);
      await group.endSelected();
      expect(a.endCount, 1);
      expect(b.endCount, 0);
    });

    test('群控只作用于同类型设备，切换类型会重置勾选', () async {
      final _FakeService a = _FakeService('p1', name: 'Mac A');
      final _FakeService b = _FakeService('p2', name: 'Mac B');
      final _FakeService c = _FakeService('p3', name: 'Win C');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b, 'p3': c},
        deviceTypeOf: (String peer) => peer == 'p3'
            ? RemoteDeviceType.windows
            : RemoteDeviceType.macos,
        groupType: RemoteDeviceType.macos,
      );

      // macOS 类型下只纳入两台 Mac，Windows 设备不参与。
      expect(group.targetCount, 2);
      expect(group.isSelected('p3'), isFalse);

      group.setEnabled(true);
      await group.broadcastText('hello');
      expect(a.texts, <String>['hello']);
      expect(b.texts, <String>['hello']);
      expect(c.texts, isEmpty, reason: '不同类型设备不接收广播');

      // 切到 Windows 后清空旧勾选；只剩一台同类型设备时自动退出群控。
      group.setGroupType(RemoteDeviceType.windows);
      expect(group.enabled, isFalse);
      expect(group.targetCount, 0);
      expect(group.isSelected('p1'), isFalse);
      expect(group.isSelected('p3'), isFalse);
      expect(group.canGroup, isFalse, reason: '只剩一台同类型设备，不可继续群控');
    });

    test('会话结束后同步剔除设备，少于两台时自动退出群控', () {
      final _FakeService a = _FakeService('p1');
      final _FakeService b = _FakeService(
        'p2',
        state: RemoteState.ended,
      );
      final Map<String, RemoteGroupService> services =
          <String, RemoteGroupService>{'p1': a, 'p2': b};
      final RemoteGroupController group =
          RemoteGroupController(services: services);

      expect(group.canGroup, isFalse);
      group.setEnabled(true);
      expect(group.enabled, isFalse);

      services['p2'] = _FakeService('p2');
      group.sync();
      expect(group.canGroup, isTrue);
      group.setEnabled(true);
      expect(group.enabled, isTrue);
      expect(group.targetCount, 2);

      // 一台会话结束后不能停留在「群控中但只发一台」的漂移状态。
      services['p2'] = b;
      group.sync();
      expect(group.enabled, isFalse);
      expect(group.targetCount, 0);
      expect(group.selected, isEmpty);

      // 同类型设备重新凑够两台后，可再次开启群控。
      services['p2'] = _FakeService('p2');
      group.sync();
      expect(group.canGroup, isTrue);
      expect(group.targetCount, 2);
      group.setEnabled(true);
      expect(group.enabled, isTrue);
    });
  });

  group('群控界面', () {
    testWidgets('设备列表可开关群控、全选与批量断开',
        (WidgetTester tester) async {
      final _FakeService a = _FakeService('p1', name: '设备 A');
      final _FakeService b = _FakeService('p2', name: '设备 B');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RemoteGroupSheet(
            controller: group,
            onChanged: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.text('设备 A'), findsOneWidget);
      expect(find.text('设备 B'), findsOneWidget);

      final SwitchListTile toggle = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey<String>('remote-group-enabled')),
      );
      expect(toggle.value, isFalse);
      await tester.tap(find.byKey(const ValueKey<String>('remote-group-enabled')));
      await tester.pumpAndSettle();
      expect(group.enabled, isTrue);
      expect(find.textContaining('已选择 2 台'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('remote-device-p2')));
      await tester.pumpAndSettle();
      // 取消勾选后只剩一台，群控自动退出并清空选择。
      expect(group.enabled, isFalse);
      expect(find.textContaining('已选择 0 台'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('remote-group-clear')));
      await tester.pumpAndSettle();
      expect(group.targetCount, 0);
      expect(find.textContaining('已选择 0 台'), findsOneWidget);

      // build 期间壳层会同步会话列表，不应撤销「清空」。
      group.sync();
      await tester.pumpAndSettle();
      expect(group.targetCount, 0);

      await tester.tap(find.byKey(const ValueKey<String>('remote-group-select-all')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选择 2 台'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('remote-group-end')));
      await tester.pumpAndSettle();
      expect(a.endCount, 1);
      expect(b.endCount, 1);
    });

    testWidgets('远控页开启群控后文字广播到所有设备',
        (WidgetTester tester) async {
      final _FakeService a = _FakeService('p1', name: '设备 A');
      final _FakeService b = _FakeService('p2', name: '设备 B');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );
      await tester.pumpWidget(MaterialApp(
        home: RemoteControlPage(
          info: _pageInfo(),
          groupController: group,
        ),
      ));

      await tester.tap(find.byKey(const ValueKey<String>('remote-group-toggle')));
      await tester.pumpAndSettle();
      expect(group.enabled, isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('remote-keyboard')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('remote-text-field')),
        '群控文字',
      );
      await tester.tap(find.byKey(const ValueKey<String>('remote-text-send')));
      await tester.pumpAndSettle();

      expect(a.texts, <String>['群控文字']);
      expect(b.texts, <String>['群控文字']);
    });

    test('群控可广播多点触摸到所有设备', () async {
      final _FakeService a = _FakeService('p1', name: '设备 A');
      final _FakeService b = _FakeService('p2', name: '设备 B');
      final RemoteGroupController group = RemoteGroupController(
        services: <String, RemoteGroupService>{'p1': a, 'p2': b},
      );
      group.enabled = true;

      await group.broadcastTouch(
        'down',
        <Map<String, int>>[
          <String, int>{'id': 1, 'x': 100, 'y': 200},
        ],
        modifiers: 0,
      );

      expect(a.touches.length, 1);
      expect(b.touches.length, 1);
      expect(a.touches.first.$1, 'down');
      expect(a.touches.first.$2.first['x'], 100);
    });
  });
}
