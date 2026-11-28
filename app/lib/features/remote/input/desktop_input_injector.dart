// 桌面输入注入接口：把远控指针/按键事件转换为本机合成输入。
//
// 平台实现直接用 dart:ffi 调用系统 API，不新增原生插件工程：
//   - macOS: CoreGraphics CGEvent，需要「辅助功能」授权；
//   - Windows: SetCursorPos / mouse_event / keybd_event；
//   - Linux: X11 + XTest，Wayland 下不可用。

import 'package:flutter/services.dart';

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

  /// 应用一个原子组合键。默认实现把修饰位解析为逻辑键，按下主键后逆序松开，
  /// 保证修饰键在主键按下期间始终处于按下态。各平台可覆写为系统级组合输入。
  Future<void> combo(String comboKey, {int modifiers = 0}) async {
    final List<String> mods = RemoteKeyMap.modifierKeysFor(
      modifiers,
      platform: hostPlatform,
    );
    for (final String mod in mods) {
      await key(mod, down: true, modifiers: modifiers);
    }
    await key(comboKey, down: true, modifiers: modifiers);
    await key(comboKey, down: false, modifiers: modifiers);
    for (final String mod in mods.reversed) {
      await key(mod, down: false);
    }
  }

  /// 注入多点触摸手势。[points] 每项含归一化 x/y 与触点 id；[phase] 为
  /// down/move/up。默认忽略，支持触屏的被控端（Android）覆写。
  Future<void> touch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  }) async {}

  /// 当前被控端平台，用于组合键的主修饰键解析（macOS → Cmd）。
  TargetPlatform get hostPlatform => TargetPlatform.windows;

  /// 直接注入 Unicode 文本；不支持时抛 [UnsupportedError]。
  Future<void> text(String text);

  Future<void> dispose();
}

/// 按平台创建注入器。
DesktopInputInjector createDesktopInputInjector() =>
    impl.createDesktopInputInjector();
