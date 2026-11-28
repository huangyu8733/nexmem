// macOS 输入注入：CoreGraphics CGEvent + 辅助功能授权检测。
//
// 沙箱内无法向其他应用注入事件，因此 macOS 构建需关闭 App Sandbox；
// 首次使用还需在「系统设置 → 隐私与安全性 → 辅助功能」中勾选本应用。

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../remote_input_codec.dart';
import '../remote_session.dart';
import 'desktop_input_injector.dart';

final class _CGPoint extends ffi.Struct {
  @ffi.Double()
  external double x;

  @ffi.Double()
  external double y;
}

class MacInputInjector implements DesktopInputInjector {
  MacInputInjector() {
    try {
      _cg = ffi.DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
      );
      _cf = ffi.DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      );
      _as = ffi.DynamicLibrary.open(
        '/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices',
      );
      _mouseEvent = _cg.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32,
              _CGPoint, ffi.Uint32),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, _CGPoint,
              int)>('CGEventCreateMouseEvent');
      _keyEvent = _cg.lookupFunction<
          ffi.Pointer<ffi.Void> Function(
              ffi.Pointer<ffi.Void>, ffi.Uint16, ffi.Uint8),
          ffi.Pointer<ffi.Void> Function(
              ffi.Pointer<ffi.Void>, int, int)>('CGEventCreateKeyboardEvent');
      _eventSetFlags = _cg.lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Uint64),
          void Function(ffi.Pointer<ffi.Void>, int)>('CGEventSetFlags');
      _eventPost = _cg.lookupFunction<
          ffi.Void Function(ffi.Uint32, ffi.Pointer<ffi.Void>),
          void Function(int, ffi.Pointer<ffi.Void>)>('CGEventPost');
      _scrollEvent = _cg.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32,
              ffi.Uint32, ffi.Int32, ffi.Int32, ffi.Int32),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, int, int,
              int, int)>('CGEventCreateScrollWheelEvent2');
      _setUnicode = _cg.lookupFunction<
          ffi.Void Function(
              ffi.Pointer<ffi.Void>, ffi.Uint64, ffi.Pointer<ffi.Uint16>),
          void Function(ffi.Pointer<ffi.Void>, int,
              ffi.Pointer<ffi.Uint16>)>('CGEventKeyboardSetUnicodeString');
      _release = _cf.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('CFRelease');
      _axTrusted = _as.lookupFunction<ffi.Uint8 Function(),
          int Function()>('AXIsProcessTrusted');
      _available = true;
    } on Object {
      _available = false;
    }
  }

  late ffi.DynamicLibrary _cg;
  late ffi.DynamicLibrary _cf;
  late ffi.DynamicLibrary _as;
  late ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>, int, _CGPoint, int) _mouseEvent;
  late ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>, int, int) _keyEvent;
  late void Function(ffi.Pointer<ffi.Void>, int) _eventSetFlags;
  late void Function(int, ffi.Pointer<ffi.Void>) _eventPost;
  late ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>, int, int, int, int, int) _scrollEvent;
  late void Function(
      ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint16>) _setUnicode;
  late void Function(ffi.Pointer<ffi.Void>) _release;
  late int Function() _axTrusted;
  bool _available = false;
  int _buttons = 0;

  /// 复用的点结构，避免每次指针事件都分配并泄漏 FFI 内存。
  final ffi.Pointer<_CGPoint> _point = calloc<_CGPoint>();

  static const int _kCGHIDEventTap = 0;
  static const int _kCGScrollEventUnitLine = 1;
  static const int _leftDown = 1;
  static const int _leftUp = 2;
  static const int _rightDown = 3;
  static const int _rightUp = 4;
  static const int _mouseMoved = 5;
  static const int _leftDragged = 6;
  static const int _rightDragged = 7;
  static const int _otherDown = 25;
  static const int _otherUp = 26;
  static const int _otherDragged = 27;

  @override
  bool get supportsInput => _available;

  @override
  TargetPlatform get hostPlatform => TargetPlatform.macOS;

  @override
  String get permissionHint => '需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许本应用控制电脑';

  @override
  Future<InputPermissionStatus> checkPermissions() async {
    if (!_available) {
      return InputPermissionStatus.unsupported;
    }
    return _axTrusted() != 0
        ? InputPermissionStatus.granted
        : InputPermissionStatus.denied;
  }

  @override
  Future<InputPermissionStatus> requestPermissions() async {
    if (!_available) {
      return InputPermissionStatus.unsupported;
    }
    if (_axTrusted() != 0) {
      return InputPermissionStatus.granted;
    }
    try {
      await Process.run('open', <String>[
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
      ]);
      await Process.run('open', <String>[
        'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
      ]);
    } on Object {
      // 打不开设置时保持拒绝，由 UI 提示手动前往。
    }
    return InputPermissionStatus.denied;
  }

  @override
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  }) async {
    if (!_available) {
      return;
    }
    final _CGPoint point = _pointFor(display, event);
    if (event.type == RemotePointerType.wheel ||
        event.type == RemotePointerType.pinch) {
      _postScroll(event, point);
      return;
    }
    if (event.type == RemotePointerType.move) {
      final int type = switch (_buttons) {
        1 => _leftDragged,
        2 => _rightDragged,
        4 => _otherDragged,
        _ => _mouseMoved,
      };
      _postMouse(type, point, _buttonFor(_buttons));
      return;
    }
    final int changed = _buttons ^ event.buttons;
    if (changed & RemoteButtons.left != 0) {
      _postMouse(
        event.buttons & RemoteButtons.left != 0 ? _leftDown : _leftUp,
        point,
        0,
      );
    }
    if (changed & RemoteButtons.right != 0) {
      _postMouse(
        event.buttons & RemoteButtons.right != 0 ? _rightDown : _rightUp,
        point,
        1,
      );
    }
    if (changed & RemoteButtons.middle != 0) {
      _postMouse(
        event.buttons & RemoteButtons.middle != 0 ? _otherDown : _otherUp,
        point,
        2,
      );
    }
    // 侧键 back/forward 复用 CGEvent 的 otherButton（buttonNumber 3/4）。
    if (changed & RemoteButtons.back != 0) {
      _postMouse(
        event.buttons & RemoteButtons.back != 0 ? _otherDown : _otherUp,
        point,
        3,
      );
    }
    if (changed & RemoteButtons.forward != 0) {
      _postMouse(
        event.buttons & RemoteButtons.forward != 0 ? _otherDown : _otherUp,
        point,
        4,
      );
    }
    _buttons = event.buttons;
  }

  @override
  Future<void> key(String key, {required bool down, int modifiers = 0}) async {
    if (!_available) {
      return;
    }
    final int? code = RemoteKeyMap.macVirtualKeys[key];
    if (code == null) {
      return;
    }
    final ffi.Pointer<ffi.Void> event = _keyEvent(ffi.nullptr, code, down ? 1 : 0);
    if (event == ffi.nullptr) {
      return;
    }
    try {
      final int flags = _flags(modifiers);
      if (flags != 0) {
        _eventSetFlags(event, flags);
      }
      _eventPost(_kCGHIDEventTap, event);
    } finally {
      _release(event);
    }
  }

  @override
  Future<void> combo(String comboKey, {int modifiers = 0}) async {
    final List<String> mods = RemoteKeyMap.modifierKeysFor(
      modifiers,
      platform: TargetPlatform.macOS,
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
    // macOS 触控板缩放已由 pinch → Ctrl+滚轮路径处理，无需额外多点注入。
  }

  @override
  Future<void> text(String text) async {
    if (!_available || text.isEmpty) {
      return;
    }
    final List<int> units = text.codeUnits;
    final ffi.Pointer<ffi.Uint16> buffer = calloc<ffi.Uint16>(units.length);
    try {
      buffer.asTypedList(units.length).setAll(0, units);
      for (final int down in <int>[1, 0]) {
        final ffi.Pointer<ffi.Void> event =
            _keyEvent(ffi.nullptr, 0, down);
        if (event == ffi.nullptr) {
          continue;
        }
        try {
          _setUnicode(event, units.length, buffer);
          _eventPost(_kCGHIDEventTap, event);
        } finally {
          _release(event);
        }
      }
    } finally {
      calloc.free(buffer);
    }
  }

  _CGPoint _pointFor(RemoteDisplay display, RemotePointerEvent event) {
    final _CGPoint point = _point.ref;
    final double width = display.width <= 0 ? 1 : display.width.toDouble();
    final double height = display.height <= 0 ? 1 : display.height.toDouble();
    point.x = display.x + (event.xNorm / 65535.0) * (width - 1);
    point.y = display.y + (event.yNorm / 65535.0) * (height - 1);
    return point;
  }

  void _postMouse(int type, _CGPoint point, int button) {
    final ffi.Pointer<ffi.Void> event =
        _mouseEvent(ffi.nullptr, type, point, button);
    if (event == ffi.nullptr) {
      return;
    }
    try {
      _eventPost(_kCGHIDEventTap, event);
    } finally {
      _release(event);
    }
  }

  void _postScroll(RemotePointerEvent event, _CGPoint point) {
    _postMouse(_mouseMoved, point, 0);
    final ffi.Pointer<ffi.Void> scroll = _scrollEvent(
      ffi.nullptr,
      _kCGScrollEventUnitLine,
      2,
      event.wheelY,
      event.wheelX,
      0,
    );
    if (scroll == ffi.nullptr) {
      return;
    }
    try {
      // 带上修饰位，使 pinch（带 control）被应用识别为缩放手势。
      final int flags = _flags(event.modifiers);
      if (flags != 0) {
        _eventSetFlags(scroll, flags);
      }
      _eventPost(_kCGHIDEventTap, scroll);
    } finally {
      _release(scroll);
    }
  }

  static int _buttonFor(int buttons) {
    if (buttons & RemoteButtons.right != 0) return 1;
    if (buttons & RemoteButtons.middle != 0) return 2;
    return 0;
  }

  static int _flags(int modifiers) {
    int flags = 0;
    if (modifiers & RemoteModifiers.shift != 0) flags |= 1 << 17;
    if (modifiers & RemoteModifiers.control != 0) flags |= 1 << 18;
    if (modifiers & RemoteModifiers.alt != 0) flags |= 1 << 19;
    if (modifiers & RemoteModifiers.meta != 0) flags |= 1 << 20;
    return flags;
  }

  @override
  Future<void> dispose() async {
    calloc.free(_point);
  }
}
