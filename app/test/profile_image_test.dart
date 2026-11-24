// 个人资料增强验收：昵称、GIF 拒绝与 1024x1024 压缩、base64 分片存储、
// 完整账号展示与复制、头像/推广图片回显。
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/settings/profile_avatar.dart';
import 'package:nexmem_app/features/settings/profile_image.dart';
import 'package:nexmem_app/features/settings/profile_panel.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

class _MemorySettings implements SettingsService {
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
      const SettingsSnapshot(snapshot: 'settings://v1/e30', count: 0);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async => 0;
}

/// 模拟内核尚未启动：前 [failures] 次读取抛 NOT_STARTED。
class _BootingSettings extends _MemorySettings {
  _BootingSettings(this.failures);

  int failures;

  @override
  Future<String?> read(String key) async {
    if (failures > 0) {
      failures--;
      throw StateError('NOT_STARTED');
    }
    return super.read(key);
  }
}

Future<ProfileImageData> _sampleImage({int width = 8, int height = 8}) async {
  final img.Image image = img.Image(width: width, height: height);
  return prepareProfileImage(img.encodePng(image), 'sample.png');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      return null;
    });
  });

  test('GIF 按扩展名与文件头双重拒绝', () async {
    final Uint8List gif = Uint8List.fromList(
      <int>[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
        0x01, 0x00, 0x01, 0x00,
      ],
    );
    await expectLater(
      prepareProfileImage(gif, 'avatar.gif'),
      throwsA(
        isA<ProfileImageException>().having(
          (ProfileImageException e) => e.code,
          'code',
          'GIF_UNSUPPORTED',
        ),
      ),
    );
    await expectLater(
      prepareProfileImage(gif, 'avatar.png'),
      throwsA(
        isA<ProfileImageException>().having(
          (ProfileImageException e) => e.code,
          'code',
          'GIF_UNSUPPORTED',
        ),
      ),
    );
  });

  test('超过 1024 的图片等比缩小并编码为 JPEG/base64', () async {
    final img.Image big = img.Image(width: 1600, height: 800);
    final ProfileImageData data = await prepareProfileImage(
      img.encodePng(big),
      'big.png',
    );
    expect(data.width, 1024);
    expect(data.height, 512);
    expect(data.mime, 'image/jpeg');
    expect(data.bytes[0], 0xff);
    expect(data.bytes[1], 0xd8);
    expect(base64Decode(data.base64).length, data.encodedBytes);
  });

  test('图片 base64 分片写入与清空 KV', () async {
    final _MemorySettings settings = _MemorySettings();
    final ProfileImageStore store = ProfileImageStore(settings);
    final String base64 = base64Encode(
      Uint8List.fromList(List<int>.generate(7000, (int i) => i % 256)),
    );
    final ProfileImageData data = ProfileImageData(
      base64: base64,
      bytes: base64Decode(base64),
      width: 4,
      height: 4,
      mime: 'image/jpeg',
    );

    await store.save(ProfileImageSlot.avatar, data);
    expect(
      settings.values.keys.where((String key) => key.startsWith('profile.avatar.0')).length,
      greaterThan(1),
    );
    expect(settings.values['profile.avatar.meta'], contains('base64_length'));

    final ProfileImageData? loaded = await store.load(ProfileImageSlot.avatar);
    expect(loaded, isNotNull);
    expect(loaded!.base64, base64);
    expect(loaded.width, 4);

    await store.clear(ProfileImageSlot.avatar);
    expect(await store.load(ProfileImageSlot.avatar), isNull);
  });

  testWidgets('个人资料展示昵称、完整账号、复制按钮与两张图片', (
    WidgetTester tester,
  ) async {
    final _MemorySettings settings = _MemorySettings();
    final ProfileImageStore store = ProfileImageStore(settings);
    final ProfileImageData sample = await _sampleImage();
    await store.save(ProfileImageSlot.avatar, sample);
    await store.save(ProfileImageSlot.promo, sample);
    await settings.write(profileNicknameSettingKey, '新昵称');
    await settings.write(profileIntroSettingKey, '个人介绍内容');
    await settings.write(profilePromoSettingKey, '推广信息内容');

    await tester.pumpWidget(
      _wrap(
        ProfileDetailPanel(
          account: CoreAccount(
            accountId: 'f' * 64,
            deviceId: 'e' * 64,
            displayName: '原账号名',
          ),
          settings: settings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey<String>('profile-nickname')))
          .controller!
          .text,
      '新昵称',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('profile-display-name')))
          .data,
      '新昵称',
    );
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey<String>('profile-account-id-full')),
          )
          .data,
      'f' * 64,
    );
    expect(find.byKey(const ValueKey<String>('profile-copy-account')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-avatar-image')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-promo-image')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-avatar-pick')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-promo-image-pick')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-avatar-crop')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('profile-promo-crop')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('profile-copy-account')));
    await tester.pumpAndSettle();
    expect(find.text('账号已复制'), findsOneWidget);
  });

  testWidgets('昵称修改后保存写入 KV', (WidgetTester tester) async {
    final _MemorySettings settings = _MemorySettings();
    await tester.pumpWidget(
      _wrap(
        ProfileDetailPanel(
          account: CoreAccount(accountId: 'a' * 64, deviceId: 'b' * 64),
          settings: settings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('profile-nickname')),
      '测试昵称',
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('profile-save')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('profile-save')));
    await tester.pumpAndSettle();

    expect(settings.values[profileNicknameSettingKey], '测试昵称');
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('全局头像缓存读取已保存头像，SelfAvatar 显示图片而非占位图标',
      (WidgetTester tester) async {
    final _MemorySettings settings = _MemorySettings();
    final ProfileImageData image = await _sampleImage();
    await ProfileImageStore(settings).save(ProfileImageSlot.avatar, image);

    final ProfileAvatarStore store = ProfileAvatarStore.instance;
    store.attach(settings);
    await tester.pumpAndSettle();
    addTearDown(() => store.resetForTest());

    expect(store.bytes, isNotNull);
    expect(store.bytes!.length, image.bytes.length);

    await tester.pumpWidget(_wrap(const SelfAvatar()));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('内核启动前头像读取失败，就绪后 reload 能补上头像', (
    WidgetTester tester,
  ) async {
    final _BootingSettings settings = _BootingSettings(0);
    final ProfileImageData image = await _sampleImage();
    await ProfileImageStore(settings).save(ProfileImageSlot.avatar, image);
    settings.failures = 1; // 模拟壳层初始化早于 core.start

    final ProfileAvatarStore store = ProfileAvatarStore.instance;
    store.resetForTest();
    addTearDown(store.resetForTest);
    store.attach(settings);
    await tester.pumpAndSettle();
    expect(store.bytes, isNull);

    // 内核就绪后壳层再次 reload（见 AppShell._boot）。
    await store.reload();
    await tester.pumpAndSettle();
    expect(store.bytes, isNotNull);
    expect(store.bytes!.length, image.bytes.length);
  });

  testWidgets('未设置头像时 SelfAvatar 显示占位图标', (WidgetTester tester) async {
    final ProfileAvatarStore store = ProfileAvatarStore.instance;
    store.attach(_MemorySettings());
    await tester.pumpAndSettle();
    addTearDown(() => store.resetForTest());

    await tester.pumpWidget(_wrap(const SelfAvatar()));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
