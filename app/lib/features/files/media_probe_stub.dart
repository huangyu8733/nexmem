// Web 端没有本地进程能力；媒体信息由浏览器原生解码，ffmpeg 入口不可用。

class MediaProbeInfo {
  const MediaProbeInfo({
    required this.format,
    required this.durationMs,
    this.width = 0,
    this.height = 0,
    this.videoCodec = '',
    this.audioCodec = '',
  });

  final String format;
  final int durationMs;
  final int width;
  final int height;
  final String videoCodec;
  final String audioCodec;

  bool get hasVideo => videoCodec.isNotEmpty;
  bool get hasAudio => audioCodec.isNotEmpty;

  String get durationLabel => durationMs <= 0
      ? '--:--'
      : '${(durationMs ~/ 60000).toString().padLeft(2, '0')}:'
          '${((durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}';

  String get dimensionLabel =>
      width > 0 && height > 0 ? '$width×$height' : '';
}

enum TranscodeTarget { video, audio }

bool get ffmpegAvailable => false;

Future<String?> ffmpegVersion() async => null;

Future<MediaProbeInfo?> probeMedia(String filePath) async => null;

Future<String?> transcodeMedia(
  String filePath, {
  required TranscodeTarget target,
  required String tempDir,
}) async =>
    null;
