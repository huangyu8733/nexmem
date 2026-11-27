// 离线 IP 归属地查询：解析随程序内置的 ip2region v4 xdb。
//
// IP 库作为 asset 打包进各端程序，启用功能时不需要联网下载；查询全部在本机
// 完成，不上传 IP，也不会把归属地自动发送给对端。默认不启用，只在用户明确
// 同意后使用；私网/环回/保留地址不查询。
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:typed_data';

import 'region_coordinates.dart';

/// ip2region 官方开源 IPv4 离线库（Apache-2.0）随程序内置。
/// 以下地址只用于可选的手动更新/打包时重新获取，正常启用不需要网络。
const String kIpLocationDbUrl =
    'https://fastly.jsdelivr.net/gh/lionsoul2014/ip2region@master/data/ip2region_v4.xdb';

/// 官方源地址，作为备选镜像写进文档；代码默认不直接用它。
const String kIpLocationDbOfficialUrl =
    'https://raw.githubusercontent.com/lionsoul2014/ip2region/master/data/ip2region_v4.xdb';

const String kIpLocationDbFileName = 'ip2region_v4.xdb';

/// Flutter asset 路径；桌面/移动/Web 均由 pubspec.yaml 打包。
const String kIpLocationBundledAsset = 'assets/$kIpLocationDbFileName';

/// xdb 固定头长度与 vector 索引长度（ip2region 官方格式）。
const int _headerLength = 256;
const int _vectorIndexLength = 256 * 256 * 8;
const int _ipv4SegmentSize = 14;

typedef IpLocationDownloader = Future<Uint8List> Function({
  required String url,
  void Function(int received, int total)? onProgress,
});

/// 读取随程序打包的 xdb 字节；只用于可选更新场景的下载器不依赖它。
typedef IpLocationBundledReader = Future<Uint8List?> Function();

/// 归属地结果。坐标是按城市/省份中心点近似，不表示设备精确位置。
class IpRegion {
  const IpRegion({
    required this.country,
    required this.province,
    required this.city,
    required this.isp,
    required this.displayName,
    this.latitude,
    this.longitude,
  });

  final String country;
  final String province;
  final String city;
  final String isp;
  final String displayName;
  final double? latitude;
  final double? longitude;

  bool get hasCoordinates => latitude != null && longitude != null;

  static IpRegion fromXdb(String raw) {
    final List<String> parts = raw.split('|');
    String clean(int index) {
      if (index >= parts.length) {
        return '';
      }
      final String value = parts[index].trim();
      return value == '0' ? '' : value;
    }

    final String country = clean(0);
    final String province = clean(1);
    final String city = clean(2);
    final String isp = clean(3);

    final List<String> labels = <String>[];
    if (country == '中国') {
      if (province.contains('台湾')) {
        labels.add('中国台湾');
      } else {
        labels.add('中国');
        if (province.isNotEmpty && province != city) {
          labels.add(province);
        }
        if (city.isNotEmpty) {
          labels.add(city);
        }
      }
    } else {
      for (final String part in <String>[country, province, city]) {
        if (part.isNotEmpty) {
          labels.add(part);
        }
      }
    }

    final String displayName = labels.join(' ').trim();
    final ({double? lat, double? lng}) center =
        lookupRegionCenter(country: country, province: province, city: city);
    return IpRegion(
      country: country,
      province: province,
      city: city,
      isp: isp,
      displayName: displayName.isEmpty ? raw.trim() : displayName,
      latitude: center.lat,
      longitude: center.lng,
    );
  }
}

/// 离线 IP 库服务：优先读程序内置库，解析与查询都在本机完成。
class IpLocationService {
  IpLocationService({
    required IpLocationDownloader downloader,
    IpLocationBundledReader? readBundled,
    Future<Uint8List?> Function()? readCache,
    Future<void> Function(Uint8List bytes)? writeCache,
    String url = kIpLocationDbUrl,
  })  : _downloader = downloader,
        _readBundled = readBundled,
        _readCache = readCache,
        _writeCache = writeCache,
        _url = url;

  final IpLocationDownloader _downloader;
  final IpLocationBundledReader? _readBundled;
  final Future<Uint8List?> Function()? _readCache;
  final Future<void> Function(Uint8List bytes)? _writeCache;
  final String _url;

  Uint8List? _db;

  bool get loaded => _db != null;

  Future<void> ensureLoaded({
    bool forceRefresh = false,
    String? url,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!forceRefresh && _db != null) {
      return;
    }
    // 内置库优先：正常运行不需要网络，也不需要用户下载。asset 读取失败时
    // 继续尝试缓存与下载，避免打包问题让整个功能不可用。
    if (!forceRefresh && _readBundled != null) {
      Uint8List? bundled;
      try {
        bundled = await _readBundled();
      } on Object {
        bundled = null;
      }
      if (bundled != null && _validHeader(bundled)) {
        _db = bundled;
        return;
      }
    }
    if (!forceRefresh && _readCache != null) {
      final Uint8List? cached = await _readCache();
      if (cached != null && _validHeader(cached)) {
        _db = cached;
        return;
      }
    }
    final Uint8List bytes = await _downloader(
      url: url ?? _url,
      onProgress: onProgress,
    );
    if (!_validHeader(bytes)) {
      throw const FormatException('IP 库文件格式不正确');
    }
    if (_writeCache != null) {
      await _writeCache(bytes);
    }
    _db = bytes;
  }

  /// 查询公网 IPv4 的归属地；私网/保留地址和 IPv6 返回 null。
  IpRegion? lookup(String ip, {bool allowPrivate = false}) {
    final Uint8List? db = _db;
    if (db == null) {
      return null;
    }
    final List<int>? bytes = parseIpv4(ip);
    if (bytes == null) {
      return null;
    }
    if (!allowPrivate && !isPublicIpv4(bytes)) {
      return null;
    }
    final String? raw = _search(db, bytes);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return IpRegion.fromXdb(raw);
  }

  bool _validHeader(Uint8List bytes) {
    if (bytes.length < _headerLength + _vectorIndexLength + _ipv4SegmentSize) {
      return false;
    }
    final int version = _u16(bytes, 0);
    final int policy = _u16(bytes, 2);
    final int ipVersion = _u16(bytes, 16);
    final bool validVersion = version == 2 || (version == 3 && ipVersion == 4);
    return validVersion && policy == 1;
  }

  String? _search(Uint8List db, List<int> ipBytes) {
    final int idx = ipBytes[0] * 256 * 8 + ipBytes[1] * 8;
    final int vectorOffset = _headerLength + idx;
    final int start = _u32(db, vectorOffset);
    final int end = _u32(db, vectorOffset + 4);
    if (start == 0 || end == 0 || end <= start) {
      return null;
    }
    final int count = (end - start) ~/ _ipv4SegmentSize;
    int low = 0;
    int high = count - 1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      final int offset = start + mid * _ipv4SegmentSize;
      if (offset < 0 || offset + _ipv4SegmentSize > db.length) {
        return null;
      }
      final int beginCompare = _compareIpv4(ipBytes, db, offset);
      if (beginCompare < 0) {
        high = mid - 1;
        continue;
      }
      final int endCompare = _compareIpv4(ipBytes, db, offset + 4);
      if (endCompare > 0) {
        low = mid + 1;
        continue;
      }
      final int dataLen = _u16(db, offset + 8);
      final int dataPtr = _u32(db, offset + 10);
      if (dataLen == 0 ||
          dataPtr < _headerLength ||
          dataPtr + dataLen > db.length) {
        return null;
      }
      return utf8.decode(
        db.sublist(dataPtr, dataPtr + dataLen),
        allowMalformed: true,
      );
    }
    return null;
  }

  /// xdb 中 IPv4 索引用小端存储；查询 IP 是大端。按官方 Go binding 对齐。
  static int _compareIpv4(List<int> query, Uint8List db, int offset) {
    for (int i = 0; i < 4; i++) {
      final int a = query[i];
      final int b = db[offset + (3 - i)];
      if (a < b) {
        return -1;
      }
      if (a > b) {
        return 1;
      }
    }
    return 0;
  }

  static int _u16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _u32(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static List<int>? parseIpv4(String ip) {
    final List<String> parts = ip.trim().split('.');
    if (parts.length != 4) {
      return null;
    }
    final List<int> bytes = <int>[];
    for (final String part in parts) {
      final int? value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) {
        return null;
      }
      bytes.add(value);
    }
    return bytes;
  }

  /// 私网、环回、链路本地、文档示例与组播地址不做归属地查询。
  static bool isPublicIpv4(List<int> b) {
    final int a = b[0];
    final int c = b[1];
    if (a == 0 || a == 10 || a == 127 || a >= 224) {
      return false;
    }
    if (a == 100 && c >= 64 && c <= 127) {
      return false;
    }
    if (a == 169 && c == 254) {
      return false;
    }
    if (a == 172 && c >= 16 && c <= 31) {
      return false;
    }
    if (a == 192 && c == 168) {
      return false;
    }
    if (a == 192 && c == 0) {
      return false;
    }
    if (a == 192 && c == 0 && b[2] == 2) {
      return false;
    }
    if (a == 198 && (c == 18 || c == 19)) {
      return false;
    }
    if (a == 198 && c == 51 && b[2] == 100) {
      return false;
    }
    if (a == 203 && c == 0 && b[2] == 113) {
      return false;
    }
    return true;
  }
}
