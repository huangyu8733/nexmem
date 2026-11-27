// 本机位置系统定位通道测试：确保定位来自系统 API 而不是用户手填坐标。
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/features/remote/device_distance.dart';
import 'package:nexmem_app/features/remote/local_location_controller.dart';
import 'package:nexmem_app/features/remote/local_location_platform.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';

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
      SettingsSnapshot(snapshot: 'settings://v1/', count: values.length);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('nexmem/location');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'isServiceEnabled':
          return true;
        case 'checkPermission':
          return 'granted';
        case 'requestPermission':
          return 'granted';
        case 'getCurrentPosition':
          return <String, double>{
            'latitude': 39.9042,
            'longitude': 116.4074,
            'accuracy': 12.5,
          };
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('wire 权限值按契约解析，未知值降级', () {
    expect(
      parseSystemLocationPermission('granted'),
      SystemLocationPermission.granted,
    );
    expect(
      parseSystemLocationPermission('deniedForever'),
      SystemLocationPermission.deniedForever,
    );
    expect(
      parseSystemLocationPermission('unsupported'),
      SystemLocationPermission.unsupported,
    );
    expect(
      parseSystemLocationPermission('nonsense'),
      SystemLocationPermission.unableToDetermine,
    );
  });

  test('系统定位成功后保存 GCJ-02 坐标与精度', () async {
    final _MemorySettings settings = _MemorySettings();
    final LocalLocationController controller = LocalLocationController(
      settings: settings,
    );
    await controller.load();

    expect(await controller.useSystemLocation(), isTrue);
    final double? lat = double.tryParse(
      settings.values[kLocalLatitudeSettingKey] ?? '',
    );
    final double? lng = double.tryParse(
      settings.values[kLocalLongitudeSettingKey] ?? '',
    );
    expect(lat, isNotNull);
    expect(lng, isNotNull);
    expect(lat, closeTo(39.9047, 0.002));
    expect(lng, closeTo(116.4133, 0.004));
    expect(controller.lastAccuracyMeters, 12.5);
    expect(controller.error, isNull);
  });

  test('定位服务关闭时不写入坐标，并给出可直接翻译的 key', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'isServiceEnabled') return false;
      return null;
    });
    final _MemorySettings settings = _MemorySettings();
    final LocalLocationController controller = LocalLocationController(
      settings: settings,
    );

    expect(await controller.useSystemLocation(), isFalse);
    expect(controller.error, '定位服务未开启，请先开启系统定位');
    expect(kLocalLocationErrorKeys.contains(controller.error), isTrue);
    expect(settings.values, isEmpty);
  });

  test('权限被永久拒绝时不调用定位，也不保存坐标', () async {
    final List<String> calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isServiceEnabled':
          return true;
        case 'checkPermission':
          return 'deniedForever';
        default:
          return null;
      }
    });
    final _MemorySettings settings = _MemorySettings();
    final LocalLocationController controller = LocalLocationController(
      settings: settings,
    );

    expect(await controller.useSystemLocation(), isFalse);
    expect(controller.error, '定位权限被拒绝，请在系统设置中允许位置权限');
    expect(calls, isNot(contains('getCurrentPosition')));
    expect(settings.values, isEmpty);
  });

  test('手工输入清除系统定位精度', () async {
    final _MemorySettings settings = _MemorySettings();
    final LocalLocationController controller = LocalLocationController(
      settings: settings,
    );
    expect(await controller.useSystemLocation(), isTrue);
    expect(controller.lastAccuracyMeters, 12.5);

    expect(await controller.save(22.54, 114.06), isTrue);
    expect(controller.lastAccuracyMeters, isNull);
    expect(controller.latitude, 22.54);

    expect(await controller.save(null, null), isTrue);
    expect(controller.hasLocation, isFalse);
    expect(controller.lastAccuracyMeters, isNull);
  });

  test('宿主未接线时安全降级，不抛异常', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final LocalLocationController controller = LocalLocationController(
      settings: _MemorySettings(),
    );

    expect(await controller.useSystemLocation(), isFalse);
    expect(controller.error, '定位服务未开启，请先开启系统定位');
  });

  testWidgets('移动端弹窗只提供系统定位按钮，点击后保存定位', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final _MemorySettings settings = _MemorySettings();
    final LocalLocationController controller = LocalLocationController(
      settings: settings,
    );
    addTearDown(controller.dispose);
    await controller.load();
    bool? confirmed;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async {
            confirmed = await showLocalLocationDialog(
              context: context,
              controller: controller,
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 移动端不再出现手填经纬度入口。
    expect(
      find.byKey(const ValueKey<String>('local-location-latitude')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('local-location-system')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey<String>('local-location-system')));
    await tester.pumpAndSettle();

    expect(confirmed, isTrue);
    expect(controller.hasLocation, isTrue);
    expect(controller.lastAccuracyMeters, 12.5);
  });

  test('系统定位坐标仍按 GCJ-02 与设备台账对齐', () {
    final ({double latitude, double longitude}) gcj = wgs84ToGcj02(
      39.9042,
      116.4074,
    );
    expect(gcj.latitude, closeTo(39.9047, 0.002));
    expect(gcj.longitude, closeTo(116.4133, 0.004));
  });
}
