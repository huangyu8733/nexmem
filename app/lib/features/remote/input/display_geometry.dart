// 屏幕几何枚举：为输入坐标换算提供每块屏幕的全局 bounds 与像素尺寸。
//
// Web / 不支持注入的平台返回空列表；被控端仍可看屏，只是无法精确定位输入。

import '../remote_session.dart';
import 'display_geometry_stub.dart'
    if (dart.library.io) 'display_geometry_io.dart' as impl;

/// 屏幕几何提供者。
abstract class DisplayGeometryProvider {
  /// 枚举当前系统屏幕，按采集源顺序排列。
  Future<List<RemoteDisplay>> list();

  Future<void> dispose();
}

/// 空实现：无注入能力的平台。
class EmptyDisplayGeometryProvider implements DisplayGeometryProvider {
  const EmptyDisplayGeometryProvider();

  @override
  Future<List<RemoteDisplay>> list() async => const <RemoteDisplay>[];

  @override
  Future<void> dispose() async {}
}

/// 按平台创建几何提供者。
DisplayGeometryProvider createDisplayGeometryProvider() =>
    impl.createDisplayGeometryProvider();
