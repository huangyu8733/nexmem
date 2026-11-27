// 设备间近似距离工具与本机位置设置测试。
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/remote/device_distance.dart';
import 'package:nexmem_app/features/remote/local_location_controller.dart';
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
  group('Haversine 距离', () {
    test('同一点为 0，跨纬度 1 度约 111 km', () {
      final double? same = distanceMeters(
        fromLatitude: 22.54,
        fromLongitude: 114.06,
        toLatitude: 22.54,
        toLongitude: 114.06,
      );
      expect(same, 0);
      final double? oneDegree = distanceMeters(
        fromLatitude: 0,
        fromLongitude: 0,
        toLatitude: 1,
        toLongitude: 0,
      );
      expect(oneDegree, closeTo(111195, 10));
    });

    test('北京到上海约 1068 km', () {
      final double? meters = distanceMeters(
        fromLatitude: 39.9087,
        fromLongitude: 116.3975,
        toLatitude: 31.24,
        toLongitude: 121.49,
      );
      expect(meters, isNotNull);
      expect(meters, closeTo(1067797, 5000));
    });

    test('非法坐标返回 null', () {
      expect(
        distanceMeters(
          fromLatitude: null,
          fromLongitude: 114,
          toLatitude: 22,
          toLongitude: 114,
        ),
        isNull,
      );
      expect(
        distanceMeters(
          fromLatitude: 91,
          fromLongitude: 0,
          toLatitude: 22,
          toLongitude: 114,
        ),
        isNull,
      );
      expect(isValidCoordinate(22, 181), isFalse);
      expect(isValidCoordinate(-90, 180), isTrue);
    });
  });

  group('WGS84 转 GCJ-02', () {
    test('中国境内坐标换算，境外保持原值', () {
      final ({double latitude, double longitude}) beijing =
          wgs84ToGcj02(39.9042, 116.4074);
      expect(beijing.latitude, closeTo(39.9047, 0.002));
      expect(beijing.longitude, closeTo(116.4133, 0.004));
      final ({double latitude, double longitude}) tokyo =
          wgs84ToGcj02(35.6762, 139.6503);
      expect(tokyo.latitude, 35.6762);
      expect(tokyo.longitude, 139.6503);
    });
  });

  group('距离格式化', () {
    test('短距离用米，长距离用公里', () {
      expect(formatDistance(349.6), '350 m');
      expect(formatDistance(999), '999 m');
      expect(formatDistance(1000), '1.0 km');
      expect(formatDistance(15400), '15.4 km');
      expect(formatDistance(154600), '155 km');
    });
  });

  test('本机位置默认空，写入与清除都落本机 KV', () async {
    final _MemorySettings settings = _MemorySettings();
    final LocalLocationController controller = LocalLocationController(
      settings: settings,
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.loaded, isTrue);
    expect(controller.hasLocation, isFalse);

    expect(await controller.save(22.54, 114.06), isTrue);
    expect(controller.hasLocation, isTrue);
    expect(settings.values[kLocalLatitudeSettingKey], '22.54');
    expect(settings.values[kLocalLongitudeSettingKey], '114.06');

    final LocalLocationController reloaded = LocalLocationController(
      settings: settings,
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.latitude, 22.54);
    expect(reloaded.longitude, 114.06);

    expect(await controller.save(null, null), isTrue);
    expect(controller.hasLocation, isFalse);
    expect(settings.values.containsKey(kLocalLatitudeSettingKey), isFalse);
  });

  test('本机位置拒绝非法坐标与只填一半', () async {
    final _MemorySettings settings = _MemorySettings();
    final LocalLocationController controller = LocalLocationController(
      settings: settings,
    );
    addTearDown(controller.dispose);

    expect(await controller.save(91, 0), isFalse);
    expect(await controller.save(22, null), isFalse);
    expect(settings.values, isEmpty);
    expect(controller.hasLocation, isFalse);
  });
}
