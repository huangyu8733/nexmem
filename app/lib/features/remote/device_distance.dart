// 设备间近似距离：Haversine 大圆距离 + 展示格式化。
//
// 坐标来源：用户手动标注（GCJ-02）或 IP 归属地城市中心点（近似）。
// 两者都不是设备精确定位，结果只用于界面上显示「距离约」，不做导航或风控。

import 'dart:math' as math;

/// 地球平均半径（米），与 WGS84 常用值一致。
const double kEarthRadiusMeters = 6371008.8;

/// 经纬度是否可用于距离计算。
bool isValidCoordinate(double? latitude, double? longitude) =>
    latitude != null &&
    longitude != null &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180;

bool _outOfChina(double lat, double lng) =>
    lng < 73.66 || lng > 135.05 || lat < 3.86 || lat > 53.55;

double _transformLat(double x, double y) {
  double ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y +
      0.1 * x * y + 0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
          40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
          320.0 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLng(double x, double y) {
  double ret = 300.0 + x + 2.0 * y + 0.1 * x * x +
      0.1 * x * y + 0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
          40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}

/// 系统定位返回 WGS84；设备台账/IP 归属地使用 GCJ-02，先转换再比较。
/// 境外坐标按原值返回，避免无意义偏移。
({double latitude, double longitude}) wgs84ToGcj02(
  double latitude,
  double longitude,
) {
  if (!isValidCoordinate(latitude, longitude) ||
      _outOfChina(latitude, longitude)) {
    return (latitude: latitude, longitude: longitude);
  }
  const double a = 6378245.0;
  const double ee = 0.00669342162296594323;
  final double radLat = latitude / 180.0 * math.pi;
  double magic = math.sin(radLat);
  magic = 1 - ee * magic * magic;
  final double sqrtMagic = math.sqrt(magic);
  final double dLat = (_transformLat(longitude - 105.0, latitude - 35.0) *
      180.0) /
      ((a / sqrtMagic) * math.pi);
  final double dLng = (_transformLng(longitude - 105.0, latitude - 35.0) *
      180.0) /
      (a / sqrtMagic * math.cos(radLat) * math.pi);
  return (
    latitude: latitude + dLat,
    longitude: longitude + dLng,
  );
}

/// 两点间大圆距离（米）；任一坐标非法时返回 null。
double? distanceMeters({
  required double? fromLatitude,
  required double? fromLongitude,
  required double? toLatitude,
  required double? toLongitude,
}) {
  if (!isValidCoordinate(fromLatitude, fromLongitude) ||
      !isValidCoordinate(toLatitude, toLongitude)) {
    return null;
  }
  final double lat1 = fromLatitude! * math.pi / 180;
  final double lat2 = toLatitude! * math.pi / 180;
  final double dLat = (toLatitude - fromLatitude) * math.pi / 180;
  final double dLng = (toLongitude! - fromLongitude!) * math.pi / 180;

  final double a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLng / 2), 2);
  final double c = 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
  return kEarthRadiusMeters * c;
}

/// 短距离用米，长距离用公里；只做近似展示，不追求高精度。
String formatDistance(double meters) {
  if (meters < 1000) {
    return '${meters.round()} m';
  }
  final double km = meters / 1000;
  if (km < 100) {
    return '${km.toStringAsFixed(1)} km';
  }
  return '${km.round()} km';
}
