// macOS 屏幕几何：CoreGraphics 的 CGGetActiveDisplayList / CGDisplayBounds。
//
// CGDisplayBounds 返回逻辑点坐标（与 CGEvent 鼠标坐标一致），Retina 的物理
// 像素通过 CGDisplayPixelsWide/High 获取，用于展示分辨率与估算画质。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import '../remote_session.dart';
import 'display_geometry.dart';

final class _CGPoint extends ffi.Struct {
  @ffi.Double()
  external double x;

  @ffi.Double()
  external double y;
}

final class _CGSize extends ffi.Struct {
  @ffi.Double()
  external double width;

  @ffi.Double()
  external double height;
}

final class _CGRect extends ffi.Struct {
  external _CGPoint origin;
  external _CGSize size;
}

class MacDisplayGeometryProvider implements DisplayGeometryProvider {
  static const int _maxDisplays = 16;

  @override
  Future<List<RemoteDisplay>> list() async {
    final ffi.DynamicLibrary lib;
    try {
      lib = ffi.DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
      );
    } on Object {
      return const <RemoteDisplay>[];
    }
    final int Function(int, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint32>)
        getActive = lib.lookupFunction<
            ffi.Int32 Function(ffi.Uint32, ffi.Pointer<ffi.Uint32>,
                ffi.Pointer<ffi.Uint32>),
            int Function(int, ffi.Pointer<ffi.Uint32>,
                ffi.Pointer<ffi.Uint32>)>('CGGetActiveDisplayList');
    final _CGRect Function(int) bounds = lib.lookupFunction<
        _CGRect Function(ffi.Uint32),
        _CGRect Function(int)>('CGDisplayBounds');
    final int Function(int) pixelsWide = lib.lookupFunction<
        ffi.Uint32 Function(ffi.Uint32),
        int Function(int)>('CGDisplayPixelsWide');
    final int Function(int) pixelsHigh = lib.lookupFunction<
        ffi.Uint32 Function(ffi.Uint32),
        int Function(int)>('CGDisplayPixelsHigh');
    final int Function(int) isMain = lib.lookupFunction<
        ffi.Uint32 Function(ffi.Uint32),
        int Function(int)>('CGDisplayIsMain');

    final ffi.Pointer<ffi.Uint32> ids = calloc<ffi.Uint32>(_maxDisplays);
    final ffi.Pointer<ffi.Uint32> count = calloc<ffi.Uint32>();
    try {
      final int code = getActive(_maxDisplays, ids, count);
      if (code != 0) {
        return const <RemoteDisplay>[];
      }
      final int total = count.value.clamp(0, _maxDisplays);
      final List<RemoteDisplay> result = <RemoteDisplay>[];
      for (int i = 0; i < total; i++) {
        final int id = ids[i];
        final _CGRect rect = bounds(id);
        final int pw = pixelsWide(id);
        final int ph = pixelsHigh(id);
        final double scale = rect.size.width <= 0
            ? 1
            : (pw / rect.size.width).clamp(1, 4).toDouble();
        result.add(RemoteDisplay(
          id: '$id',
          name: '屏幕 ${i + 1}',
          index: i,
          x: rect.origin.x.round(),
          y: rect.origin.y.round(),
          width: rect.size.width.round(),
          height: rect.size.height.round(),
          pixelWidth: pw,
          pixelHeight: ph,
          scale: scale,
          primary: isMain(id) != 0,
        ));
      }
      return result;
    } finally {
      calloc.free(ids);
      calloc.free(count);
    }
  }

  @override
  Future<void> dispose() async {}
}
