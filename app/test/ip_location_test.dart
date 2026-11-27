// 离线 IP 归属地：xdb 解析、缓存、私网过滤与坐标映射。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/remote/ip_location.dart';
import 'package:nexmem_app/features/remote/region_coordinates.dart';
import 'package:nexmem_app/features/remote/remote_device_directory.dart';
import 'package:nexmem_app/features/remote/remote_geo_controller.dart';
import 'package:nexmem_app/features/remote/remote_storage.dart';
import 'package:nexmem_app/features/settings/settings_service.dart';

class _MemoryStorage implements RemoteStorage {
  final Map<String, Map<String, dynamic>> json = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> readJson(String name) async => json[name];

  @override
  Future<void> writeJson(String name, Map<String, dynamic> data) async =>
      json[name] = data;

  @override
  Future<List<String>> readLines(String name) async => const <String>[];

  @override
  Future<void> appendLine(String name, String line) async {}

  @override
  Future<void> clear(String name) async => json.remove(name);

  @override
  Future<String> saveDownload(String fileName, List<int> bytes) async => fileName;
}

class _FakeSettings implements SettingsService {
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
      SettingsSnapshot(snapshot: 'settings://v1/', count: 0);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async => 0;
}

Uint8List _buildXdb({
  required List<int> startIp,
  required List<int> endIp,
  required String region,
}) {
  const int header = 256;
  const int vector = 256 * 256 * 8;
  final List<int> regionBytes = utf8.encode(region);
  final int dataStart = header + vector;
  final int indexStart = dataStart + regionBytes.length;
  final int indexEnd = indexStart + 14;
  final Uint8List bytes = Uint8List(indexEnd);

  void put16(int offset, int value) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >> 8) & 0xff;
  }

  void put32(int offset, int value) {
    bytes[offset] = value & 0xff;
    bytes[offset + 1] = (value >> 8) & 0xff;
    bytes[offset + 2] = (value >> 16) & 0xff;
    bytes[offset + 3] = (value >> 24) & 0xff;
  }

  // header: version=3, policy=vector, v4, pointer=4
  put16(0, 3);
  put16(2, 1);
  put32(8, indexStart);
  put32(12, indexEnd);
  put16(16, 4);
  put16(18, 4);

  final int vectorOffset = header + (startIp[0] * 256 + startIp[1]) * 8;
  put32(vectorOffset, indexStart);
  put32(vectorOffset + 4, indexEnd);

  bytes.setRange(dataStart, dataStart + regionBytes.length, regionBytes);

  // 索引中的 IP 用小端存储，查询 IP 用大端。
  for (int i = 0; i < 4; i++) {
    bytes[indexStart + i] = startIp[3 - i];
    bytes[indexStart + 4 + i] = endIp[3 - i];
  }
  put16(indexStart + 8, regionBytes.length);
  put32(indexStart + 10, dataStart);
  return bytes;
}

IpLocationService _serviceWith(Uint8List xdb, {Uint8List? cache}) {
  return IpLocationService(
    downloader: ({required String url, void Function(int, int)? onProgress}) async {
      onProgress?.call(xdb.length, xdb.length);
      return xdb;
    },
    readCache: () async => cache,
    writeCache: (Uint8List bytes) async {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ip2region xdb 离线解析', () {
    test('解析省市区并映射到 GCJ-02 中心点', () async {
      final Uint8List xdb = _buildXdb(
        startIp: const <int>[1, 0, 1, 0],
        endIp: const <int>[1, 0, 1, 255],
        region: '中国|广东省|深圳市|电信|CN',
      );
      final IpLocationService service = _serviceWith(xdb);
      await service.ensureLoaded();

      final IpRegion? region = service.lookup('1.0.1.5');
      expect(region, isNotNull);
      expect(region!.displayName, '中国 广东省 深圳市');
      expect(region.city, '深圳市');
      expect(region.latitude, closeTo(22.5431, 0.0001));
      expect(region.longitude, closeTo(114.0579, 0.0001));
    });

    test('私网与保留地址不查询', () async {
      final Uint8List xdb = _buildXdb(
        startIp: const <int>[1, 0, 1, 0],
        endIp: const <int>[1, 0, 1, 255],
        region: '中国|广东省|深圳市|电信|CN',
      );
      final IpLocationService service = _serviceWith(xdb);
      await service.ensureLoaded();
      expect(service.lookup('10.0.0.8'), isNull);
      expect(service.lookup('192.168.1.2'), isNull);
      expect(service.lookup('127.0.0.1'), isNull);
      expect(service.lookup('not-an-ip'), isNull);
      expect(service.lookup('1.0.1.5', allowPrivate: true), isNotNull);
    });

    test('命中缓存后不重复下载', () async {
      final Uint8List xdb = _buildXdb(
        startIp: const <int>[1, 0, 1, 0],
        endIp: const <int>[1, 0, 1, 255],
        region: '中国|广东省|深圳市|电信|CN',
      );
      int downloads = 0;
      final IpLocationService service = IpLocationService(
        downloader: ({required String url, void Function(int, int)? onProgress}) async {
          downloads++;
          return xdb;
        },
        readCache: () async => xdb,
      );
      await service.ensureLoaded();
      await service.ensureLoaded();
      expect(downloads, 0);
      await service.ensureLoaded(forceRefresh: true);
      expect(downloads, 1);
    });

    test('内置库优先于缓存与下载，启用不需要网络', () async {
      final Uint8List xdb = _buildXdb(
        startIp: const <int>[1, 0, 1, 0],
        endIp: const <int>[1, 0, 1, 255],
        region: '中国|广东省|深圳市|电信|CN',
      );
      int downloads = 0;
      final IpLocationService service = IpLocationService(
        downloader: ({required String url, void Function(int, int)? onProgress}) async {
          downloads++;
          return xdb;
        },
        readBundled: () async => xdb,
        readCache: () async => null,
      );
      await service.ensureLoaded();
      expect(downloads, 0);
      expect(service.lookup('1.0.1.5')!.city, '深圳市');
      // 只有显式刷新才走网络更新通道。
      await service.ensureLoaded(forceRefresh: true);
      expect(downloads, 1);
    });

    test('内置库读取失败时回退缓存', () async {
      final Uint8List xdb = _buildXdb(
        startIp: const <int>[1, 0, 1, 0],
        endIp: const <int>[1, 0, 1, 255],
        region: '中国|广东省|深圳市|电信|CN',
      );
      int downloads = 0;
      final IpLocationService service = IpLocationService(
        downloader: ({required String url, void Function(int, int)? onProgress}) async {
          downloads++;
          return xdb;
        },
        readBundled: () async => throw StateError('asset 不存在'),
        readCache: () async => xdb,
      );
      await service.ensureLoaded();
      expect(downloads, 0);
      expect(service.lookup('1.0.1.5'), isNotNull);
    });

    test('程序内置的真实 ip2region 库可直接解析公网 IP', () async {
      final ByteData data = await rootBundle.load(kIpLocationBundledAsset);
      final IpLocationService service = IpLocationService(
        downloader: ({required String url, void Function(int, int)? onProgress}) async {
          throw StateError('内置库可用时不应下载');
        },
        readBundled: () async =>
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await service.ensureLoaded();
      expect(service.loaded, isTrue);

      final IpRegion? nanjing = service.lookup('114.114.114.114');
      expect(nanjing, isNotNull);
      expect(nanjing!.province, '江苏省');
      expect(nanjing.city, '南京市');
      expect(nanjing.hasCoordinates, isTrue);

      final IpRegion? hangzhou = service.lookup('223.5.5.5');
      expect(hangzhou, isNotNull);
      expect(hangzhou!.city, '杭州市');

      final IpRegion? mountainView = service.lookup('8.8.8.8');
      expect(mountainView, isNotNull);
      expect(mountainView!.country == '中国', isFalse);
      expect(mountainView.hasCoordinates, isFalse);
    });

    test('镜像地址覆盖默认下载地址', () async {
      final Uint8List xdb = _buildXdb(
        startIp: const <int>[1, 0, 1, 0],
        endIp: const <int>[1, 0, 1, 255],
        region: '中国|广东省|深圳市|电信|CN',
      );
      String? usedUrl;
      final IpLocationService service = IpLocationService(
        downloader: ({required String url, void Function(int, int)? onProgress}) async {
          usedUrl = url;
          return xdb;
        },
      );
      await service.ensureLoaded();
      expect(usedUrl, kIpLocationDbUrl);
      await service.ensureLoaded(forceRefresh: true, url: 'https://mirror.example/ip.xdb');
      expect(usedUrl, 'https://mirror.example/ip.xdb');
    });

    test('控制器保存镜像地址并拒绝非 http(s)', () async {
      final Uint8List xdb = _buildXdb(
        startIp: const <int>[1, 0, 1, 0],
        endIp: const <int>[1, 0, 1, 255],
        region: '中国|广东省|深圳市|电信|CN',
      );
      String? usedUrl;
      final IpLocationService service = IpLocationService(
        downloader: ({required String url, void Function(int, int)? onProgress}) async {
          usedUrl = url;
          return xdb;
        },
      );
      final _FakeSettings settings = _FakeSettings();
      final RemoteDeviceDirectory directory = RemoteDeviceDirectory(_MemoryStorage());
      await directory.load();
      final RemoteGeoController controller = RemoteGeoController(
        service: service,
        settings: settings,
        directory: directory,
      );
      addTearDown(controller.dispose);

      expect(await controller.setMirrorUrl('file:///etc/passwd'), isFalse);
      expect(controller.error, isNotNull);
      expect(await controller.setMirrorUrl('https://mirror.example/ip.xdb'), isTrue);
      expect(settings.values[kIpDbUrlSettingKey], 'https://mirror.example/ip.xdb');

      await controller.setEnabled(true);
      expect(usedUrl, 'https://mirror.example/ip.xdb');

      await controller.load();
      expect(controller.mirrorUrl, 'https://mirror.example/ip.xdb');
    });

    test('台湾地区按中国台湾展示', () {
      final IpRegion region = IpRegion.fromXdb('中国|台湾|台北市|中华电信|TW');
      expect(region.displayName, '中国台湾');
      expect(region.latitude, isNotNull);
    });

    test('境外 IP 不映射到国内坐标', () {
      final IpRegion region = IpRegion.fromXdb('美国|加利福尼亚|洛杉矶|0|US');
      expect(region.latitude, isNull);
      expect(region.longitude, isNull);
    });
  });

  test('自动归属地只补全空白字段', () async {
    final Uint8List xdb = _buildXdb(
      startIp: const <int>[1, 0, 1, 0],
      endIp: const <int>[1, 0, 1, 255],
      region: '中国|广东省|深圳市|电信|CN',
    );
    final IpLocationService service = _serviceWith(xdb);
    await service.ensureLoaded();
    final RemoteDeviceDirectory directory = RemoteDeviceDirectory(_MemoryStorage());
    await directory.load();
    await directory.add(peer: 'auto', name: '自动设备', ip: '1.0.1.5');
    await directory.add(
      peer: 'manual',
      name: '手动设备',
      ip: '1.0.1.6',
      region: '手动地区',
      latitude: 31.23,
      longitude: 121.47,
    );

    final _FakeSettings settings = _FakeSettings();
    final RemoteGeoController controller = RemoteGeoController(
      service: service,
      settings: settings,
      directory: directory,
    );
    addTearDown(controller.dispose);
    controller.enabled = true;
    await controller.enrichAll();

    expect(directory.find('auto')!.region, '中国 广东省 深圳市');
    expect(directory.find('auto')!.hasLocation, isTrue);
    expect(directory.find('manual')!.region, '手动地区');
    expect(directory.find('manual')!.latitude, 31.23);
  });

  test('地区中心点优先使用城市坐标', () {
    final ({double? lat, double? lng}) center = lookupRegionCenter(
      country: '中国',
      province: '广东省',
      city: '深圳市',
    );
    expect(center.lat, closeTo(22.5431, 0.0001));
    expect(center.lng, closeTo(114.0579, 0.0001));
  });
}
