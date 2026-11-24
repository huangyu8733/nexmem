/// 媒体信息探测与 ffmpeg 工具链统一入口。
///
/// 桌面/移动端调用本地 ffprobe/ffmpeg（随 Windows 包附带在 `ffmpeg/` 目录，
/// 也可用 `NEXMEM_FFMPEG` / `NEXMEM_FFPROBE` 指定）；Web 端没有进程能力，
/// 由条件导出的 stub 返回空结果，播放器使用浏览器原生解码。
library;

export 'media_probe_io.dart' if (dart.library.html) 'media_probe_stub.dart';
