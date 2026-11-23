/// 本机图片预览（P6-16）：图片消息气泡按本机绝对路径渲染缩略图。
///
/// Web 端拿不到服务端本机文件，退化为占位提示；其余平台读取本机文件。
library;

export 'local_image_stub.dart' if (dart.library.io) 'local_image_io.dart';
