// Windows 输入注入：SetCursorPos + mouse_event + keybd_event。
//
// 不依赖原生插件；通过 user32.dll 直接合成输入。UAC 提权窗口受 UIPI 限制，
// 普通进程无法向其注入，这是系统限制而非实现缺陷。

import 'dart:ffi' as ffi;

import 'package:flutter/services.dart';

import '../remote_input_codec.dart';
import '../remote_session.dart';
import 'desktop_input_injector.dart';

class WindowsInputInjector implements DesktopInputInjector {
  WindowsInputInjector() {
    try {
      final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
      _setCursorPos = user32.lookupFunction<
          ffi.Int32 Function(ffi.Int32, ffi.Int32),
          int Function(int, int)>('SetCursorPos');
      _mouseEvent = user32.lookupFunction<
          ffi.Void Function(
              ffi.Uint32, ffi.Int32, ffi.Int32, ffi.Uint32, ffi.UintPtr),
          void Function(int, int, int, int,
              int)>('mouse_event');
      _keybdEvent = user32.lookupFunction<
          ffi.Void Function(ffi.Uint8, ffi.Uint8, ffi.Uint32, ffi.UintPtr),
          void Function(int, int, int, int)>('keybd_event');
      _available = true;
    } on Object {
      _available = false;
    }
  }

  late int Function(int, int) _setCursorPos;
  late void Function(int, int, int, int, int) _mouseEvent;
  late void Function(int, int, int, int) _keybdEvent;
  bool _available = false;
  int _buttons = 0;

  static const int _leftDown = 0x0002;
  static const int _leftUp = 0x0004;
  static const int _rightDown = 0x0008;
  static const int _rightUp = 0x0010;
  static const int _middleDown = 0x0020;
  static const int _middleUp = 0x0040;
  static const int _wheel = 0x0800;
  static const int _hwheel = 0x01000;
  static const int _xDown = 0x0080;
  static const int _xUp = 0x0100;
  static const int _xButton1 = 0x0001;
  static const int _xButton2 = 0x0002;
  static const int _keyUp = 0x0002;
  static const int _extended = 0x0001;

  @override
  bool get supportsInput => _available;

  @override
  TargetPlatform get hostPlatform => TargetPlatform.windows;

  @override
  Future<void> combo(String comboKey, {int modifiers = 0}) async {
    final List<String> mods = RemoteKeyMap.modifierKeysFor(
      modifiers,
      platform: TargetPlatform.windows,
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

  @override
  Future<void> touch(
    String phase,
    List<Map<String, int>> points, {
    int modifiers = 0,
  }) async {
    // Windows 无通用多点注入 API；触控经 pinch → Ctrl+滚轮路径处理。
  }

  @override
  String get permissionHint => '无需额外授权；UAC 提权窗口无法被普通权限的远控操作';

  @override
  Future<InputPermissionStatus> checkPermissions() async =>
      _available ? InputPermissionStatus.granted : InputPermissionStatus.unsupported;

  @override
  Future<InputPermissionStatus> requestPermissions() async =>
      checkPermissions();

  @override
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  }) async {
    if (!_available) {
      return;
    }
    final int x = _xFor(display, event.xNorm);
    final int y = _yFor(display, event.yNorm);
    _setCursorPos(x, y);
    if (event.type == RemotePointerType.wheel ||
        event.type == RemotePointerType.pinch) {
      // pinch 带 control 修饰位；Windows 上 Ctrl+滚轮是通用缩放手势，
      // _wheelWithModifiers 会临时按下修改键以保证应用识别为缩放。
      _wheelWithModifiers(event);
      return;
    }
    if (event.type == RemotePointerType.move) {
      return; // SetCursorPos 已更新位置。
    }
    final int changed = _buttons ^ event.buttons;
    if (changed & RemoteButtons.left != 0) {
      _mouseEvent(
        event.buttons & RemoteButtons.left != 0 ? _leftDown : _leftUp,
        0,
        0,
        0,
        0,
      );
    }
    if (changed & RemoteButtons.right != 0) {
      _mouseEvent(
        event.buttons & RemoteButtons.right != 0 ? _rightDown : _rightUp,
        0,
        0,
        0,
        0,
      );
    }
    if (changed & RemoteButtons.middle != 0) {
      _mouseEvent(
        event.buttons & RemoteButtons.middle != 0 ? _middleDown : _middleUp,
        0,
        0,
        0,
        0,
      );
    }
    // X1/X2 侧键：mouse_event 的 XDOWN/XUP + XBUTTON1/2 数据位。
    if (changed & RemoteButtons.back != 0) {
      _mouseEvent(
        event.buttons & RemoteButtons.back != 0 ? _xDown : _xUp,
        0,
        0,
        _xButton1,
        0,
      );
    }
    if (changed & RemoteButtons.forward != 0) {
      _mouseEvent(
        event.buttons & RemoteButtons.forward != 0 ? _xDown : _xUp,
        0,
        0,
        _xButton2,
        0,
      );
    }
    _buttons = event.buttons;
  }

  @override
  Future<void> key(String key, {required bool down, int modifiers = 0}) async {
    if (!_available) {
      return;
    }
    final int? code = RemoteKeyMap.windowsVirtualKeys[key];
    if (code == null) {
      return;
    }
    int flags = down ? 0 : _keyUp;
    if (_isExtended(key)) {
      flags |= _extended;
    }
    _keybdEvent(code, 0, flags, 0);
  }

  @override
  Future<void> text(String text) async {
    throw UnsupportedError('Windows 端文本输入经剪贴板粘贴实现');
  }

  /// 滚动事件：pinch 带 control 修饰时临时按住 Ctrl，使应用识别为缩放。
  void _wheelWithModifiers(RemotePointerEvent event) {
    final List<String> held = RemoteKeyMap.modifierKeysFor(
      event.modifiers,
      platform: TargetPlatform.windows,
    );
    for (final String mod in held) {
      final int? code = RemoteKeyMap.windowsVirtualKeys[mod];
      if (code != null) {
        _keybdEvent(code, 0, 0, 0);
      }
    }
    if (event.wheelY != 0) {
      _mouseEvent(_wheel, 0, 0, event.wheelY * 120, 0);
    }
    if (event.wheelX != 0) {
      _mouseEvent(_hwheel, 0, 0, event.wheelX * 120, 0);
    }
    for (final String mod in held.reversed) {
      final int? code = RemoteKeyMap.windowsVirtualKeys[mod];
      if (code != null) {
        _keybdEvent(code, 0, _keyUp, 0);
      }
    }
  }

  static bool _isExtended(String key) => const <String>{
        'arrowUp',
        'arrowDown',
        'arrowLeft',
        'arrowRight',
        'home',
        'end',
        'pageUp',
        'pageDown',
        'delete',
        'insert',
        'controlRight',
        'altRight',
        'metaLeft',
        'metaRight',
        'contextMenu',
        'numPadEnter',
        'numPadDivide',
      }.contains(key);

  static int _xFor(RemoteDisplay display, int norm) {
    final double width = display.width <= 0 ? 1 : display.width.toDouble();
    return display.x + (norm / 65535.0 * (width - 1)).round();
  }

  static int _yFor(RemoteDisplay display, int norm) {
    final double height = display.height <= 0 ? 1 : display.height.toDouble();
    return display.y + (norm / 65535.0 * (height - 1)).round();
  }

  @override
  Future<void> dispose() async {}
}
