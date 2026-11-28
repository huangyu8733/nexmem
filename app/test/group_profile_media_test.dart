// 群头像与群介绍验收：512x512 裁剪、字段解析、契约调用与编辑刷新。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/group/group_info_page.dart';
import 'package:nexmem_app/features/group/group_service.dart';
import 'package:nexmem_app/features/settings/image_crop_page.dart';
import 'package:nexmem_app/transport/transport.dart';

String _account(int seed) =>
    List<int>.generate(32, (int i) => (seed + i * 7) % 256)
        .map((int v) => v.toRadixString(16).padLeft(2, '0'))
        .join();

Uint8List _sampleImage() {
  final img.Image image = img.Image(width: 300, height: 600);
  img.fill(image, color: img.ColorRgb8(40, 120, 220));
  img.fillRect(image, x1: 50, y1: 150, x2: 250, y2: 450, color: img.ColorRgb8(220, 80, 60));
  return img.encodePng(image);
}

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

class _FakeGroups implements GroupService {
  _FakeGroups(this.info);

  GroupInfo info;
  final List<(String, String)> avatarUpdates = <(String, String)>[];
  final List<(String, String)> descriptionUpdates = <(String, String)>[];

  @override
  Future<String> create({required String title, required List<String> members}) async => 'g';

  @override
  Future<List<GroupSummary>> list() async => <GroupSummary>[];

  @override
  Future<GroupInfo> members(String groupId) async => info;

  @override
  Future<int> invite(String groupId, String account) async => 1;

  @override
  Future<GroupInviteResult> inviteDetailed(String groupId, String account) async {
    return GroupInviteResult(keyVersion: await invite(groupId, account));
  }

  @override
  Future<int> remove(String groupId, String account) async => 2;

  @override
  Future<void> leave(String groupId) async {}

  @override
  Future<void> dissolve(String groupId) async {}

  @override
  Future<void> configureStorage(String groupId, GroupStorageConfig config) async {}

  @override
  Future<int> removeStorage(String groupId) async => 0;

  @override
  Future<String> setAnnouncement(String groupId, String announcement) async => announcement;

  @override
  Future<String> setAvatar(String groupId, String avatarB64) async {
    avatarUpdates.add((groupId, avatarB64));
    info = info.copyWith(avatarB64: avatarB64);
    return avatarB64;
  }

  @override
  Future<String> setDescription(String groupId, String description) async {
    descriptionUpdates.add((groupId, description));
    info = info.copyWith(description: description);
    return description;
  }

  @override
  Future<bool> setAllowFriendAdd(String groupId, bool enabled) async => enabled;

  @override
  Future<String> setAlias(String groupId, String alias) async => alias;

  @override
  Future<GroupLevels> setLevelConfig(
    String groupId, {
    required bool enabled,
    required List<GroupLevel> levels,
  }) async =>
      GroupLevels(enabled: enabled, items: levels);

  @override
  Future<GroupMemberProfile> setMemberProfile(
    String groupId,
    String account, {
    String? nickname,
    String? levelId,
  }) async =>
      GroupMemberProfile(account: account, nickname: nickname ?? '', levelId: levelId ?? '');
}

Widget _page(_FakeGroups groups) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: GroupInfoPage(
      groupId: 'Z3JvdXA',
      title: '测试群',
      service: groups,
      selfAccount: _account(1),
    ),
  );
}

void main() {
  group('群头像图片处理', () {
    test('裁剪后严格输出 512x512 JPEG 且 base64 在上限内', () {
      final Uint8List jpeg = prepareGroupAvatarJpeg(_sampleImage());
      final img.Image? decoded = img.decodeJpg(jpeg);
      expect(decoded, isNotNull);
      expect(decoded!.width, kGroupAvatarSize);
      expect(decoded.height, kGroupAvatarSize);
      expect(base64.encode(jpeg).length, lessThanOrEqualTo(kGroupAvatarMaxBase64Chars));
    });

    test('无法解码的图片抛出 FormatException', () {
      expect(
        () => prepareGroupAvatarJpeg(Uint8List.fromList(<int>[1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('群资料字段解析与契约', () {
    test('GroupInfo.fromJson 解析头像与群介绍', () {
      final String b64 = base64.encode(prepareGroupAvatarJpeg(_sampleImage()));
      final GroupInfo info = GroupInfo.fromJson(<String, dynamic>{
        'group_id': 'Z3JvdXA',
        'title': '测试群',
        'key_version': 1,
        'members': <dynamic>[],
        'avatar_b64': b64,
        'description': '这是一个测试群',
      });
      expect(info.description, '这是一个测试群');
      expect(info.avatarBytes, isNotNull);
      expect(info.avatarBytes!.length, greaterThan(0));
    });

    test('TransportGroupService 调用 group.setAvatar / group.setDescription', () async {
      final _FakeTransport transport = _FakeTransport((
        String method,
        Map<String, dynamic>? params,
      ) async {
        if (method == 'group.setAvatar') {
          return <String, dynamic>{'avatar_b64': params?['avatar_b64']};
        }
        return <String, dynamic>{'description': params?['description']};
      });
      final TransportGroupService service = TransportGroupService(transport);
      expect(await service.setAvatar('Z3JvdXA', 'AVATAR'), 'AVATAR');
      expect(await service.setDescription('Z3JvdXA', '群介绍'), '群介绍');
      expect(
        transport.calls.map((dynamic c) => c.$1).toList(),
        <String>['group.setAvatar', 'group.setDescription'],
      );
      expect(transport.calls[0].$2?['group_id'], 'Z3JvdXA');
      expect(transport.calls[1].$2?['description'], '群介绍');
    });
  });

  group('群资料界面', () {
    testWidgets('管理员可编辑群介绍并立即刷新展示', (WidgetTester tester) async {
      final String b64 = base64.encode(prepareGroupAvatarJpeg(_sampleImage()));
      final _FakeGroups groups = _FakeGroups(
        GroupInfo(
          groupId: 'Z3JvdXA',
          title: '测试群',
          keyVersion: 1,
          storageConfigured: true,
          avatarB64: b64,
          members: <GroupMember>[
            GroupMember(account: _account(1), role: 'admin'),
          ],
        ),
      );
      await tester.pumpWidget(_page(groups));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('group-avatar-header')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('group-description-empty')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('group-description-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('group-description-field')),
        '欢迎加入测试群',
      );
      await tester.tap(find.byKey(const ValueKey<String>('group-description-save')));
      await tester.pumpAndSettle();

      expect(groups.descriptionUpdates.single.$2, '欢迎加入测试群');
      expect(find.byKey(const ValueKey<String>('group-description-text')), findsOneWidget);
      expect(find.text('欢迎加入测试群'), findsOneWidget);
    });
  });
}
