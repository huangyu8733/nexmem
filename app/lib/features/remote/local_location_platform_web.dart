// Web 端没有宿主定位通道；本机位置入口在 Web 上本来就不展示系统定位按钮，
// 这里只提供安全降级实现，避免条件编译缺符号。

import 'local_location_platform_types.dart';

class BrowserSystemLocation implements SystemLocationPlatform {
  const BrowserSystemLocation();

  @override
  Future<bool> isServiceEnabled() async => false;

  @override
  Future<SystemLocationPermission> checkPermission() async =>
      SystemLocationPermission.unsupported;

  @override
  Future<SystemLocationPermission> requestPermission() async =>
      SystemLocationPermission.unsupported;

  @override
  Future<SystemPosition> getCurrentPosition() async =>
      throw const SystemLocationException.unsupported();
}

SystemLocationPlatform makeSystemLocationPlatform() =>
    const BrowserSystemLocation();
