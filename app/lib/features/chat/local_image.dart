/// 本机图片预览（P6-16）：图片消息气泡按本机绝对路径渲染缩略图。
///
/// Web 端拿不到服务端本机文件；注入 [LocalImage.sourceUri] 后改为鉴权
/// `/download?disposition=inline` 在线显示，未注入时才退化为占位提示。
/// 其余平台读取本机文件。
library;

export 'local_image_stub.dart' if (dart.library.io) 'local_image_io.dart';
