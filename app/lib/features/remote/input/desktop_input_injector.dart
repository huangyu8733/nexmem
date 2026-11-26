// 桌面输入注入接口：把远控指针/按键事件转换为本机合成输入。
//
// 平台实现直接用 dart:ffi 调用系统 API，不新增原生插件工程：
//   - macOS: CoreGraphics CGEvent，需要「辅助功能」授权；
//   - Windows: SetCursorPos / mouse_event / keybd_event；
//   - Linux: X11 + XTest，Wayland 下不可用。

import '../remote_input_codec.dart';
import '../remote_session.dart';
import 'input_injector_stub.dart'
    if (dart.library.io) 'input_injector_io.dart' as impl;

/// 平台输入权限状态。
enum InputPermissionStatus {
  unsupported('当前平台不支持注入'),
  unknown('尚未检查'),
  granted('已授权'),
  denied('未授权');

  const InputPermissionStatus(this.label);
  final String label;
}

/// 输入注入器。
abstract class DesktopInputInjector {
  bool get supportsInput;

  /// 供设置页展示的授权说明。
  String get permissionHint;

  Future<InputPermissionStatus> checkPermissions();

  Future<InputPermissionStatus> requestPermissions();

  /// 应用一次指针事件；[display] 为当前被控屏幕。
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  });

  /// 应用一次按键（含修饰键本身）。
  Future<void> key(String key, {required bool down, int modifiers = 0});

  /// 直接注入 Unicode 文本；不支持时抛 [UnsupportedError]。
  Future<void> text(String text);

  Future<void> dispose();
}

/// 按平台创建注入器。
DesktopInputInjector createDesktopInputInjector() =>
    impl.createDesktopInputInjector();
