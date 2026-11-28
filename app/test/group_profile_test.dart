// 群成员本群称呼与等级系统验收：
// - 64x64 PNG 自动居中裁剪
// - 等级/成员资料数据模型与 group.members 回包解析
// - group.setLevelConfig / group.setMemberProfile 契约映射
// - 成员资料弹窗与等级设置弹窗的权限、长度限制与保存
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/group/group_profile_dialogs.dart';
import 'package:nexmem_app/features/group/group_service.dart';
import 'package:nexmem_app/features/settings/image_crop_page.dart';
import 'package:nexmem_app/transport/transport.dart';

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handler);

  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic>? params,
  )
  handler;

  final List<(String, Map<String, dynamic>?)> calls =
      <(String, Map<String, dynamic>?)>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) {
    calls.add((method, params));
    return handler(method, params);
  }

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

Uint8List _png(int width, int height, img.Color color) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: color);
  return img.encodePng(image);
}

void main() {
  group('prepareSquarePng 自动裁剪', () {
    test('宽图取中心正方形并缩放到 64x64 PNG', () {
      // 200x100：中心 100x100 区域正好是图像中段。
      final Uint8List source = _png(
        200,
        100,
        img.ColorRgb8(12, 34, 56),
      );
      final Uint8List result = prepareSquarePng(source);
      final img.Image? decoded = img.decodeImage(result);

      expect(decoded, isNotNull);
      expect(decoded!.width, 64);
      expect(decoded.height, 64);
      expect(result.sublist(1, 4), <int>[80, 78, 71]); // PNG 标识
    });

    test('高图取中心正方形，自定义尺寸生效', () {
      final Uint8List source = _png(
        80,
        160,
        img.ColorRgb8(200, 100, 50),
      );
      final Uint8List result = prepareSquarePng(source, size: 32);
      final img.Image? decoded = img.decodeImage(result);

      expect(decoded, isNotNull);
      expect(decoded!.width, 32);
      expect(decoded.height, 32);
    });

    test('空字节与非法尺寸抛 FormatException', () {
      expect(
        () => prepareSquarePng(Uint8List.fromList(<int>[1, 2, 3])),
        throwsFormatException,
      );
      expect(
        () => prepareSquarePng(_png(4, 4, img.ColorRgb8(0, 0, 0)), size: 0),
        throwsFormatException,
      );
    });
  });

  group('等级与成员资料模型', () {
    test('GroupLevel.fromJson / toJson 使用 icon_b64 字段', () {
      const String b64 = 'iVBORw0KGgo=';
      final GroupLevel level = GroupLevel.fromJson(<String, dynamic>{
        'id': 'lv-1',
        'name': '钻石会员',
        'icon_b64': b64,
      });
      expect(level.id, 'lv-1');
      expect(level.name, '钻石会员');
      expect(level.iconB64, b64);
      expect(level.toJson(), <String, dynamic>{
        'id': 'lv-1',
        'name': '钻石会员',
        'icon_b64': b64,
      });
      expect(level.iconBytes, isNotNull);
    });

    test('非法 base64 图标回退为 null', () {
      const GroupLevel level = GroupLevel(
        id: 'lv-1',
        name: '测试',
        iconB64: 'not-base64!!!',
      );
      expect(level.iconBytes, isNull);
      expect(
        const GroupLevel(id: 'lv-2', name: '无图标').iconBytes,
        isNull,
      );
    });

    test('group.members 回包解析等级配置与本群称呼', () {
      final img.Image icon = img.Image(width: 64, height: 64);
      img.fill(icon, color: img.ColorRgb8(1, 2, 3));
      final String iconB64 = base64.encode(img.encodePng(icon));

      final GroupInfo info = GroupInfo.fromJson(<String, dynamic>{
        'group_id': 'Z3JvdXA',
        'title': '周末爬山',
        'key_version': 2,
        'level_enabled': true,
        'levels': <dynamic>[
          <String, dynamic>{
            'id': 'lv-1',
            'name': '钻石会员',
            'icon_b64': iconB64,
          },
        ],
        'members': <dynamic>[
          <String, dynamic>{
            'account': 'admin-account',
            'role': 'admin',
            'nickname': '群主大人',
            'level_id': 'lv-1',
          },
          <String, dynamic>{'account': 'member-account', 'role': 'member'},
        ],
      });

      expect(info.levelEnabled, isTrue);
      expect(info.levels, hasLength(1));
      expect(info.levelOf('lv-1')?.name, '钻石会员');
      expect(info.levelOf('missing'), isNull);
      expect(info.members.first.nickname, '群主大人');
      expect(info.members.first.displayLabel, '群主大人');
      expect(info.members.first.levelId, 'lv-1');
      expect(info.members.last.displayLabel, isNot(''));
      expect(info.members.last.levelId, '');
    });

    test('局部更新群资料保留等级与群设置字段', () {
      const GroupInfo info = GroupInfo(
        groupId: 'g',
        title: '群',
        keyVersion: 1,
        storageConfigured: true,
        allowFriendAdd: true,
        levelEnabled: true,
        levels: <GroupLevel>[GroupLevel(id: 'lv-1', name: '钻石')],
        members: <GroupMember>[
          GroupMember(account: 'a', role: 'member', levelId: 'lv-1'),
        ],
      );

      final GroupInfo updated = info.copyWith(announcement: '新公告');
      expect(updated.announcement, '新公告');
      expect(updated.alias, info.alias);
      expect(updated.allowFriendAdd, isTrue);
      expect(updated.levelEnabled, isTrue);
      expect(updated.levels, hasLength(1));
      expect(updated.members.single.levelId, 'lv-1');

      final GroupInfo aliased = updated.copyWith(alias: '本群备注');
      expect(aliased.announcement, '新公告');
      expect(aliased.alias, '本群备注');
      expect(aliased.allowFriendAdd, isTrue);
      expect(aliased.levelEnabled, isTrue);
    });

    test('等级关闭后 levelOf 返回 null', () {
      const GroupInfo info = GroupInfo(
        groupId: 'g',
        title: '群',
        keyVersion: 1,
        storageConfigured: false,
        levelEnabled: false,
        levels: <GroupLevel>[
          GroupLevel(id: 'lv-1', name: '钻石'),
        ],
        members: <GroupMember>[
          GroupMember(account: 'a', role: 'member', levelId: 'lv-1'),
        ],
      );
      expect(info.levelOf('lv-1'), isNull);
    });
  });

  group('TransportGroupService 契约映射', () {
    test('setLevelConfig 使用 group.setLevelConfig 并解析回包', () async {
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        expect(method, 'group.setLevelConfig');
        expect(params?['group_id'], 'Z3JvdXA');
        expect(params?['enabled'], isTrue);
        expect(params?['levels'], <dynamic>[
          <String, dynamic>{
            'id': 'lv-1',
            'name': '钻石会员',
            'icon_b64': 'aGk=',
          },
        ]);
        return <String, dynamic>{
          'level_enabled': true,
          'levels': params?['levels'],
        };
      });

      final GroupLevels saved = await TransportGroupService(
        transport,
      ).setLevelConfig(
        'Z3JvdXA',
        enabled: true,
        levels: const <GroupLevel>[
          GroupLevel(id: 'lv-1', name: '钻石会员', iconB64: 'aGk='),
        ],
      );

      expect(saved.enabled, isTrue);
      expect(saved.items.single.name, '钻石会员');
      expect(transport.calls, hasLength(1));
    });

    test('setMemberProfile 只带传入字段，支持清除称呼', () async {
      final List<Map<String, dynamic>?> paramsLog = <Map<String, dynamic>?>[];
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        expect(method, 'group.setMemberProfile');
        paramsLog.add(params);
        return <String, dynamic>{
          'account': params?['account'],
          'nickname': params?['nickname'] ?? '',
          'level_id': params?['level_id'] ?? '',
        };
      });
      final TransportGroupService service = TransportGroupService(transport);

      final GroupMemberProfile first = await service.setMemberProfile(
        'Z3JvdXA',
        'member-account',
        nickname: '小明',
      );
      expect(first.nickname, '小明');
      expect(paramsLog.last, <String, dynamic>{
        'group_id': 'Z3JvdXA',
        'account': 'member-account',
        'nickname': '小明',
      });

      await service.setMemberProfile(
        'Z3JvdXA',
        'member-account',
        nickname: '',
        levelId: 'lv-1',
      );
      expect(paramsLog.last, <String, dynamic>{
        'group_id': 'Z3JvdXA',
        'account': 'member-account',
        'nickname': '',
        'level_id': 'lv-1',
      });

      await service.setMemberProfile('Z3JvdXA', 'member-account');
      expect(paramsLog.last, <String, dynamic>{
        'group_id': 'Z3JvdXA',
        'account': 'member-account',
      });
    });
  });

  group('成员资料弹窗', () {
    testWidgets('成员只能改自己称呼；超长被拦截；保存调用契约', (
      WidgetTester tester,
    ) async {
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        expect(method, 'group.setMemberProfile');
        return <String, dynamic>{
          'account': 'member-account',
          'nickname': params?['nickname'],
          'level_id': '',
        };
      });
      final TransportGroupService service = TransportGroupService(transport);
      const GroupMember member = GroupMember(
        account: 'member-account',
        role: 'member',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: NexmemTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                key: const ValueKey<String>('open'),
                onPressed: () => showMemberProfileDialog(
                  context,
                  service: service,
                  groupId: 'Z3JvdXA',
                  member: member,
                  isSelf: true,
                  isAdmin: false,
                  levels: const GroupLevels(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('group-member-nickname-field')),
        findsOneWidget,
      );
      // 非管理员不显示等级下拉。
      expect(
        find.byKey(const ValueKey<String>('group-member-level-field')),
        findsNothing,
      );

      // TextField 的 maxLength=24 会拦截超长输入。
      await tester.enterText(
        find.byKey(const ValueKey<String>('group-member-nickname-field')),
        '暱' * 25,
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('group-member-nickname-field')),
            )
            .controller!
            .text
            .runes
            .length,
        24,
      );
      expect(transport.calls, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey<String>('group-member-nickname-field')),
        '小明',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('group-member-profile-save')),
      );
      await tester.pumpAndSettle();

      expect(transport.calls.single.$1, 'group.setMemberProfile');
      expect(transport.calls.single.$2?['nickname'], '小明');
      expect(transport.calls.single.$2?.containsKey('level_id'), isFalse);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('成员资料保存失败时弹窗保留并显示错误原因', (
      WidgetTester tester,
    ) async {
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        throw const NexmemException('NOT_ONLINE', '');
      });
      final TransportGroupService service = TransportGroupService(transport);
      const GroupMember member = GroupMember(
        account: 'member-account',
        role: 'member',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: NexmemTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                key: const ValueKey<String>('open'),
                onPressed: () => showMemberProfileDialog(
                  context,
                  service: service,
                  groupId: 'Z3JvdXA',
                  member: member,
                  isSelf: true,
                  isAdmin: false,
                  levels: const GroupLevels(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('group-member-nickname-field')),
        '保存失败测试',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('group-member-profile-save')),
      );
      await tester.pumpAndSettle();

      // 失败必须保留弹窗，且空 message 要回退到错误码，不能“看起来没反应”。
      expect(
        find.byKey(const ValueKey<String>('group-member-profile-save')),
        findsOneWidget,
      );
      expect(find.text('NOT_ONLINE'), findsOneWidget);
    });

    testWidgets('非本人非管理员：等级下拉隐藏且保存按钮禁用', (
      WidgetTester tester,
    ) async {
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        throw StateError('无权限时不应调用契约');
      });
      final TransportGroupService service = TransportGroupService(transport);
      const GroupMember member = GroupMember(
        account: 'member-account',
        role: 'member',
        nickname: '旧称呼',
      );
      const GroupLevels levels = GroupLevels(
        enabled: true,
        items: <GroupLevel>[GroupLevel(id: 'lv-1', name: '钻石会员')],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: NexmemTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                key: const ValueKey<String>('open'),
                onPressed: () => showMemberProfileDialog(
                  context,
                  service: service,
                  groupId: 'Z3JvdXA',
                  member: member,
                  isSelf: false,
                  isAdmin: false,
                  levels: levels,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();

      expect(find.text('只有本人或管理员可以修改称呼'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('group-member-level-field')),
        findsNothing,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey<String>('group-member-profile-save')),
            )
            .onPressed,
        isNull,
      );
      expect(transport.calls, isEmpty);
    });

    testWidgets('管理员为他人设置等级并保存 level_id', (
      WidgetTester tester,
    ) async {
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        expect(method, 'group.setMemberProfile');
        return <String, dynamic>{
          'account': params?['account'],
          'nickname': params?['nickname'],
          'level_id': params?['level_id'],
        };
      });
      final TransportGroupService service = TransportGroupService(transport);
      const GroupMember member = GroupMember(
        account: 'member-account',
        role: 'member',
      );
      const GroupLevels levels = GroupLevels(
        enabled: true,
        items: <GroupLevel>[GroupLevel(id: 'lv-1', name: '钻石会员')],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: NexmemTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                key: const ValueKey<String>('open'),
                onPressed: () => showMemberProfileDialog(
                  context,
                  service: service,
                  groupId: 'Z3JvdXA',
                  member: member,
                  isSelf: false,
                  isAdmin: true,
                  levels: levels,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();

      final Finder levelField = find.byKey(
        const ValueKey<String>('group-member-level-field'),
      );
      expect(levelField, findsOneWidget);
      await tester.tap(levelField);
      await tester.pumpAndSettle();
      await tester.tap(find.text('钻石会员').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('group-member-nickname-field')),
        '小钻',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('group-member-profile-save')),
      );
      await tester.pumpAndSettle();

      expect(transport.calls, hasLength(1));
      expect(transport.calls.single.$2?['nickname'], '小钻');
      expect(transport.calls.single.$2?['level_id'], 'lv-1');
    });
  });

  group('等级设置弹窗', () {
    testWidgets('管理员开关等级、改名并提交 base64 图标', (
      WidgetTester tester,
    ) async {
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        expect(method, 'group.setLevelConfig');
        return <String, dynamic>{
          'level_enabled': params?['enabled'],
          'levels': params?['levels'],
        };
      });
      final TransportGroupService service = TransportGroupService(transport);
      final img.Image icon = img.Image(width: 100, height: 50);
      img.fill(icon, color: img.ColorRgb8(9, 8, 7));
      final String iconB64 = base64.encode(
        prepareSquarePng(img.encodePng(icon)),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: NexmemTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                key: const ValueKey<String>('open'),
                onPressed: () => showGroupLevelDialog(
                  context,
                  service: service,
                  groupId: 'Z3JvdXA',
                  initial: GroupLevels(
                    items: <GroupLevel>[
                      GroupLevel(id: 'lv-1', name: '青铜', iconB64: iconB64),
                    ],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('group-level-enabled')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('group-level-lv-1')),
        findsOneWidget,
      );
      expect(find.text('青铜'), findsOneWidget);

      // 打开开关。
      await tester.tap(find.byKey(const ValueKey<String>('group-level-enabled')));
      await tester.pumpAndSettle();
      // 添加一个等级。
      await tester.tap(find.byKey(const ValueKey<String>('group-level-add')));
      await tester.pumpAndSettle();
      // 保存。
      await tester.tap(find.byKey(const ValueKey<String>('group-level-save')));
      await tester.pumpAndSettle();

      expect(transport.calls, hasLength(1));
      expect(transport.calls.single.$1, 'group.setLevelConfig');
      expect(transport.calls.single.$2?['enabled'], isTrue);
      final List<dynamic> levels =
          transport.calls.single.$2?['levels'] as List<dynamic>;
      expect(levels, hasLength(2));
      expect(levels.first['icon_b64'], iconB64);
      final img.Image? decoded = img.decodeImage(
        base64.decode(levels.first['icon_b64'] as String),
      );
      expect(decoded?.width, 64);
      expect(decoded?.height, 64);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
