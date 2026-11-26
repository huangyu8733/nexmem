// 桌面/移动平台选择对应的屏幕几何实现。
import 'dart:io';

import 'display_geometry.dart';
import 'display_geometry_android.dart';
import 'display_geometry_linux.dart';
import 'display_geometry_macos.dart';
import 'display_geometry_windows.dart';

DisplayGeometryProvider createDisplayGeometryProvider() {
  if (Platform.isMacOS) {
    return MacDisplayGeometryProvider();
  }
  if (Platform.isWindows) {
    return WindowsDisplayGeometryProvider();
  }
  if (Platform.isLinux) {
    return LinuxDisplayGeometryProvider();
  }
  if (Platform.isAndroid) {
    return AndroidDisplayGeometryProvider();
  }
  return const EmptyDisplayGeometryProvider();
}
