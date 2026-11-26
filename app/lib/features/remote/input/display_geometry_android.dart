// Android 屏幕几何：来自 Flutter 的 Display API。
//
// Android 的 getDisplayMedia 始终采集默认屏幕，不提供多屏选择；这里只暴露
// 一块屏幕，尺寸用于控制端按比例渲染与坐标归一化。

import 'dart:ui' as ui;

import '../remote_session.dart';
import 'display_geometry.dart';

class AndroidDisplayGeometryProvider implements DisplayGeometryProvider {
  @override
  Future<List<RemoteDisplay>> list() async {
    final Iterable<ui.Display> displays =
        ui.PlatformDispatcher.instance.displays;
    if (displays.isEmpty) {
      return const <RemoteDisplay>[];
    }
    final ui.Display display = displays.first;
    final double ratio =
        display.devicePixelRatio <= 0 ? 1 : display.devicePixelRatio;
    return <RemoteDisplay>[
      RemoteDisplay(
        id: 'screen',
        name: '本机屏幕',
        index: 0,
        x: 0,
        y: 0,
        width: (display.size.width / ratio).round(),
        height: (display.size.height / ratio).round(),
        pixelWidth: display.size.width.round(),
        pixelHeight: display.size.height.round(),
        scale: ratio,
        primary: true,
      ),
    ];
  }

  @override
  Future<void> dispose() async {}
}
