// Linux 屏幕几何：XineramaQueryScreens，失败时退回 XDisplayWidth/Height。
//
// Wayland 下 X11 几何可能只覆盖 XWayland；输入注入会单独做能力检测。

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../remote_session.dart';
import 'display_geometry.dart';

final class _XineramaScreenInfo extends ffi.Struct {
  @ffi.Int16()
  external int screenNumber;

  @ffi.Int16()
  external int xOrg;

  @ffi.Int16()
  external int yOrg;

  @ffi.Int16()
  external int width;

  @ffi.Int16()
  external int height;
}

ffi.DynamicLibrary? _openFirst(List<String> names) {
  for (final String name in names) {
    try {
      return ffi.DynamicLibrary.open(name);
    } on Object {
      // 尝试下一个候选名。
    }
  }
  return null;
}

class LinuxDisplayGeometryProvider implements DisplayGeometryProvider {
  @override
  Future<List<RemoteDisplay>> list() async {
    final ffi.DynamicLibrary? x11 =
        _openFirst(<String>['libX11.so.6', 'libX11.so']);
    if (x11 == null) {
      return const <RemoteDisplay>[];
    }
    final ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>) open =
        x11.lookupFunction<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>),
            ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>)>(
        'XOpenDisplay');
    final int Function(ffi.Pointer<ffi.Void>) close = x11.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<ffi.Void>)>('XCloseDisplay');
    final int Function(ffi.Pointer<ffi.Void>, int) width = x11.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32),
        int Function(ffi.Pointer<ffi.Void>, int)>('XDisplayWidth');
    final int Function(ffi.Pointer<ffi.Void>, int) height = x11.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32),
        int Function(ffi.Pointer<ffi.Void>, int)>('XDisplayHeight');

    final ffi.Pointer<ffi.Void> display = open(ffi.nullptr);
    if (display == ffi.nullptr) {
      return const <RemoteDisplay>[];
    }
    try {
      final ffi.DynamicLibrary? xinerama =
          _openFirst(<String>['libXinerama.so.1', 'libXinerama.so']);
      if (xinerama != null) {
        final ffi.Pointer<_XineramaScreenInfo> Function(
                ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>) query =
            xinerama.lookupFunction<
                ffi.Pointer<_XineramaScreenInfo> Function(
                    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>),
                ffi.Pointer<_XineramaScreenInfo> Function(
                    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>)>(
                'XineramaQueryScreens');
        final int Function(ffi.Pointer<ffi.Void>) free = xinerama.lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Void>),
            int Function(ffi.Pointer<ffi.Void>)>('XFree');
        final ffi.Pointer<ffi.Int32> count = calloc<ffi.Int32>();
        try {
          final ffi.Pointer<_XineramaScreenInfo> screens =
              query(display, count);
          final int total = count.value;
          if (screens != ffi.nullptr && total > 0) {
            final List<RemoteDisplay> result = <RemoteDisplay>[];
            for (int i = 0; i < total; i++) {
              final _XineramaScreenInfo screen = screens[i];
              result.add(RemoteDisplay(
                id: '${screen.screenNumber}',
                name: '屏幕 ${i + 1}',
                index: i,
                x: screen.xOrg,
                y: screen.yOrg,
                width: screen.width,
                height: screen.height,
                pixelWidth: screen.width,
                pixelHeight: screen.height,
                primary: i == 0,
              ));
            }
            free(screens.cast<ffi.Void>());
            return result;
          }
        } finally {
          calloc.free(count);
        }
      }
      final int w = width(display, 0);
      final int h = height(display, 0);
      if (w > 0 && h > 0) {
        return <RemoteDisplay>[
          RemoteDisplay(
            id: '0',
            name: '屏幕 1',
            index: 0,
            x: 0,
            y: 0,
            width: w,
            height: h,
            pixelWidth: w,
            pixelHeight: h,
            primary: true,
          ),
        ];
      }
      return const <RemoteDisplay>[];
    } finally {
      close(display);
    }
  }

  @override
  Future<void> dispose() async {}

  /// Wayland 会话下输入注入不可用（无通用合成事件协议）。
  static bool get isWayland =>
      (Platform.environment['XDG_SESSION_TYPE'] ?? '').toLowerCase() ==
      'wayland';
}
