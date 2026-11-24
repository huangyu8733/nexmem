/// 平台相关的小型桥接：把 `dart:io` 的 File/Directory 限制在条件导出内部，
/// 让媒体预览组件本身可以被 Web 编译器编译。
library;

export 'media_io_bridge_io.dart' if (dart.library.html) 'media_io_bridge_stub.dart';
