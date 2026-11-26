// Windows 屏幕几何：EnumDisplayMonitors + GetMonitorInfoW。
//
// 进程已是 PerMonitorV2，此处拿到的 rcMonitor 为物理像素，与 SendInput /
// SetCursorPos 使用的坐标系一致。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../remote_session.dart';
import 'display_geometry.dart';

final class _RECT extends ffi.Struct {
  @ffi.Int32()
  external int left;

  @ffi.Int32()
  external int top;

  @ffi.Int32()
  external int right;

  @ffi.Int32()
  external int bottom;
}

final class _MONITORINFOEXW extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;

  external _RECT rcMonitor;

  external _RECT rcWork;

  @ffi.Uint32()
  external int dwFlags;

  @ffi.Array(32)
  external ffi.Array<ffi.Uint16> szDevice;
}

final List<int> _monitorHandles = <int>[];

int _monitorProc(
  int hMonitor,
  int hdc,
  ffi.Pointer<_RECT> rect,
  int data,
) {
  _monitorHandles.add(hMonitor);
  return 1;
}

class WindowsDisplayGeometryProvider implements DisplayGeometryProvider {
  @override
  Future<List<RemoteDisplay>> list() async {
    final ffi.DynamicLibrary user32;
    try {
      user32 = ffi.DynamicLibrary.open('user32.dll');
    } on Object {
      return const <RemoteDisplay>[];
    }
    final int Function(ffi.Pointer<_RECT>, ffi.Pointer<_RECT>,
            ffi.Pointer<ffi.NativeFunction<
                ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr,
                    ffi.Pointer<_RECT>, ffi.IntPtr)>>,
            int) enumMonitors = user32.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<_RECT>, ffi.Pointer<_RECT>,
            ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.IntPtr,
                ffi.IntPtr, ffi.Pointer<_RECT>, ffi.IntPtr)>>, ffi.IntPtr),
        int Function(ffi.Pointer<_RECT>, ffi.Pointer<_RECT>,
            ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.IntPtr,
                ffi.IntPtr, ffi.Pointer<_RECT>, ffi.IntPtr)>>,
            int)>('EnumDisplayMonitors');
    final int Function(int, ffi.Pointer<_MONITORINFOEXW>) getInfo =
        user32.lookupFunction<
            ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_MONITORINFOEXW>),
            int Function(int, ffi.Pointer<_MONITORINFOEXW>)>(
        'GetMonitorInfoW');
    final int Function(int) metrics = user32.lookupFunction<
        ffi.Int32 Function(ffi.Int32),
        int Function(int)>('GetSystemMetrics');

    _monitorHandles.clear();
    final ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.IntPtr,
            ffi.IntPtr, ffi.Pointer<_RECT>, ffi.IntPtr)>> callback =
        ffi.Pointer.fromFunction<ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr,
            ffi.Pointer<_RECT>, ffi.IntPtr)>(_monitorProc, 0);
    enumMonitors(ffi.nullptr, ffi.nullptr, callback, 0);

    final List<RemoteDisplay> result = <RemoteDisplay>[];
    for (int i = 0; i < _monitorHandles.length; i++) {
      final ffi.Pointer<_MONITORINFOEXW> info = calloc<_MONITORINFOEXW>();
      try {
        info.ref.cbSize = ffi.sizeOf<_MONITORINFOEXW>();
        if (getInfo(_monitorHandles[i], info) == 0) {
          continue;
        }
        final _RECT rect = info.ref.rcMonitor;
        final int width = rect.right - rect.left;
        final int height = rect.bottom - rect.top;
        result.add(RemoteDisplay(
          id: '${_monitorHandles[i]}',
          name: _deviceName(info.ref),
          index: i,
          x: rect.left,
          y: rect.top,
          width: width,
          height: height,
          pixelWidth: width,
          pixelHeight: height,
          primary: info.ref.dwFlags & 1 != 0,
        ));
      } finally {
        calloc.free(info);
      }
    }
    if (result.isEmpty) {
      // 兜底：至少给出主屏，避免输入完全不可用。
      final int width = metrics(0);
      final int height = metrics(1);
      if (width > 0 && height > 0) {
        result.add(RemoteDisplay(
          id: '0',
          name: '屏幕 1',
          index: 0,
          x: metrics(76),
          y: metrics(77),
          width: width,
          height: height,
          pixelWidth: width,
          pixelHeight: height,
          primary: true,
        ));
      }
    }
    return result;
  }

  static String _deviceName(_MONITORINFOEXW info) {
    final List<int> units = <int>[];
    for (int i = 0; i < 32; i++) {
      final int unit = info.szDevice[i];
      if (unit == 0) {
        break;
      }
      units.add(unit);
    }
    final String name = String.fromCharCodes(units).trim();
    return name.isEmpty ? '屏幕' : name;
  }

  @override
  Future<void> dispose() async {}
}
