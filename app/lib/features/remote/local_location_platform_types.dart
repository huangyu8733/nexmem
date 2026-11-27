// 系统定位能力的跨平台契约。
//
// 移动端由宿主实现 MethodChannel 'nexmem/location'；Web / 桌面未提供实现时
// 安全降级，不会让「设置本机位置」弹窗崩溃。

/// 与原生侧 wire 值一一对应，未知值统一落到 unableToDetermine。
enum SystemLocationPermission {
  granted,
  denied,
  deniedForever,
  unableToDetermine,
  unsupported,
}

SystemLocationPermission parseSystemLocationPermission(Object? raw) =>
    switch (raw?.toString()) {
      'granted' => SystemLocationPermission.granted,
      'denied' => SystemLocationPermission.denied,
      'deniedForever' => SystemLocationPermission.deniedForever,
      'unsupported' => SystemLocationPermission.unsupported,
      _ => SystemLocationPermission.unableToDetermine,
    };

/// 原生返回 WGS84 坐标；精度单位为米。
class SystemPosition {
  const SystemPosition({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
}

abstract class SystemLocationPlatform {
  const SystemLocationPlatform();

  Future<bool> isServiceEnabled();
  Future<SystemLocationPermission> checkPermission();
  Future<SystemLocationPermission> requestPermission();
  Future<SystemPosition> getCurrentPosition();
}

class SystemLocationException implements Exception {
  const SystemLocationException(this.message, {this.code = 'LOCATION_FAILED'});
  const SystemLocationException.unsupported()
      : this('当前设备不支持系统定位', code: 'UNSUPPORTED');

  final String message;
  final String code;

  @override
  String toString() => '$code: $message';
}
