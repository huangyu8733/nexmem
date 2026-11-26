// Linux 输入注入：X11 + XTest。
//
// Wayland 会话没有通用的全局注入协议，v1 将被控端降级为只读；
// X11 / XWayland 下可正常控制 X11 应用。

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../remote_input_codec.dart';
import '../remote_session.dart';
import 'desktop_input_injector.dart';

class LinuxInputInjector implements DesktopInputInjector {
  LinuxInputInjector() {
    _wayland =
        (Platform.environment['XDG_SESSION_TYPE'] ?? '').toLowerCase() ==
            'wayland';
    try {
      final ffi.DynamicLibrary x11 = _open(<String>[
        'libX11.so.6',
        'libX11.so',
      ]);
      final ffi.DynamicLibrary xtst = _open(<String>[
        'libXtst.so.6',
        'libXtst.so',
      ]);
      _openDisplay = x11.lookupFunction<
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>),
          ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>)>(
          'XOpenDisplay');
      _closeDisplay = x11.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Void>),
          int Function(ffi.Pointer<ffi.Void>)>('XCloseDisplay');
      _flush = x11.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>),
          int Function(ffi.Pointer<ffi.Void>)>('XFlush');
      _stringToKeysym = x11.lookupFunction<
          ffi.Uint64 Function(ffi.Pointer<ffi.Char>),
          int Function(ffi.Pointer<ffi.Char>)>('XStringToKeysym');
      _keysymToKeycode = x11.lookupFunction<
          ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Uint64),
          int Function(ffi.Pointer<ffi.Void>, int)>('XKeysymToKeycode');
      _fakeMotion = xtst.lookupFunction<
          ffi.Int32 Function(
              ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32, ffi.Int32, ffi.Uint64),
          int Function(ffi.Pointer<ffi.Void>, int, int, int,
              int)>('XTestFakeMotionEvent');
      _fakeButton = xtst.lookupFunction<
          ffi.Int32 Function(
              ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Int32, ffi.Uint64),
          int Function(ffi.Pointer<ffi.Void>, int, int, int)>(
          'XTestFakeButtonEvent');
      _fakeKey = xtst.lookupFunction<
          ffi.Int32 Function(
              ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Int32, ffi.Uint64),
          int Function(ffi.Pointer<ffi.Void>, int, int, int)>(
          'XTestFakeKeyEvent');
      _display = _openDisplay(ffi.nullptr);
      _available = _display != ffi.nullptr;
    } on Object {
      _available = false;
    }
  }

  late bool _wayland;
  late ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>) _openDisplay;
  late int Function(ffi.Pointer<ffi.Void>) _closeDisplay;
  late int Function(ffi.Pointer<ffi.Void>) _flush;
  late int Function(ffi.Pointer<ffi.Char>) _stringToKeysym;
  late int Function(ffi.Pointer<ffi.Void>, int) _keysymToKeycode;
  late int Function(ffi.Pointer<ffi.Void>, int, int, int, int) _fakeMotion;
  late int Function(ffi.Pointer<ffi.Void>, int, int, int) _fakeButton;
  late int Function(ffi.Pointer<ffi.Void>, int, int, int) _fakeKey;
  ffi.Pointer<ffi.Void> _display = ffi.nullptr;
  bool _available = false;
  int _buttons = 0;

  static ffi.DynamicLibrary _open(List<String> names) {
    Object? last;
    for (final String name in names) {
      try {
        return ffi.DynamicLibrary.open(name);
      } on Object catch (error) {
        last = error;
      }
    }
    throw StateError('无法加载 $names: $last');
  }

  @override
  bool get supportsInput => _available && !_wayland;

  @override
  String get permissionHint => _wayland
      ? 'Wayland 会话不支持全局输入注入，请切换到 X11 会话'
      : 'X11 下无需额外授权；Wayland 仅能查看屏幕';

  @override
  Future<InputPermissionStatus> checkPermissions() async => supportsInput
      ? InputPermissionStatus.granted
      : InputPermissionStatus.unsupported;

  @override
  Future<InputPermissionStatus> requestPermissions() async =>
      checkPermissions();

  @override
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  }) async {
    if (!supportsInput) {
      return;
    }
    final int x = display.x + (event.xNorm / 65535.0 * (display.width - 1)).round();
    final int y = display.y + (event.yNorm / 65535.0 * (display.height - 1)).round();
    _fakeMotion(_display, -1, x, y, 0);
    if (event.type == RemotePointerType.wheel) {
      _wheel(event.wheelY, 4, 5);
      _wheel(event.wheelX, 6, 7);
      _flush(_display);
      return;
    }
    if (event.type == RemotePointerType.move) {
      _flush(_display);
      return;
    }
    final int changed = _buttons ^ event.buttons;
    if (changed & RemoteButtons.left != 0) {
      _fakeButton(_display, 1, event.buttons & RemoteButtons.left != 0 ? 1 : 0, 0);
    }
    if (changed & RemoteButtons.middle != 0) {
      _fakeButton(_display, 2, event.buttons & RemoteButtons.middle != 0 ? 1 : 0, 0);
    }
    if (changed & RemoteButtons.right != 0) {
      _fakeButton(_display, 3, event.buttons & RemoteButtons.right != 0 ? 1 : 0, 0);
    }
    _buttons = event.buttons;
    _flush(_display);
  }

  void _wheel(int delta, int positiveButton, int negativeButton) {
    if (delta == 0) {
      return;
    }
    final int button = delta > 0 ? positiveButton : negativeButton;
    final int times = delta.abs().clamp(1, 10);
    for (int i = 0; i < times; i++) {
      _fakeButton(_display, button, 1, 0);
      _fakeButton(_display, button, 0, 0);
    }
  }

  @override
  Future<void> key(String key, {required bool down, int modifiers = 0}) async {
    if (!supportsInput) {
      return;
    }
    final String? keysym = RemoteKeyMap.x11Keysyms[key];
    if (keysym == null) {
      return;
    }
    final ffi.Pointer<ffi.Char> name = keysym.toNativeUtf8().cast<ffi.Char>();
    try {
      final int sym = _stringToKeysym(name);
      if (sym == 0) {
        return;
      }
      final int code = _keysymToKeycode(_display, sym);
      if (code == 0) {
        return;
      }
      _fakeKey(_display, code, down ? 1 : 0, 0);
      _flush(_display);
    } finally {
      calloc.free(name);
    }
  }

  @override
  Future<void> text(String text) async {
    throw UnsupportedError('Linux 端文本输入经剪贴板粘贴实现');
  }

  @override
  Future<void> dispose() async {
    if (_display != ffi.nullptr) {
      _closeDisplay(_display);
      _display = ffi.nullptr;
    }
  }
}
