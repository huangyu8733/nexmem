// 桌面/移动端：调用 ffprobe/ffmpeg 读取媒体信息、探测编码能力并转码。
//
// 查找顺序：
//   1. 环境变量 NEXMEM_FFMPEG / NEXMEM_FFPROBE
//   2. 可执行文件同级目录的 ffmpeg/ 子目录（发布包布局）
//   3. 当前工作目录的 ffmpeg/ 子目录
//   4. PATH
// 找不到时所有方法安全返回 null，播放器仍可用原生解码播放常见格式。

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// ffprobe 读出的媒体信息。
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

  String get durationLabel {
    final int seconds = durationMs ~/ 1000;
    if (seconds <= 0) return '--:--';
    final int m = seconds ~/ 60;
    final int s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get dimensionLabel =>
      width > 0 && height > 0 ? '$width×$height' : '';
}

String? _ffmpegPath;
String? _ffprobePath;
bool _searched = false;

void _ensureLocated() {
  if (_searched) return;
  _searched = true;
  _ffmpegPath = _findTool('ffmpeg', 'NEXMEM_FFMPEG');
  // ffprobe 通常与 ffmpeg 同目录；找不到时退化为使用 ffmpeg -i 解析。
  final String? probe = _findTool('ffprobe', 'NEXMEM_FFPROBE');
  _ffprobePath = probe;
}

String? _findTool(String base, String envKey) {
  final String suffix = Platform.isWindows ? '.exe' : '';
  final String name = '$base$suffix';
  final String? fromEnv = Platform.environment[envKey];
  if (fromEnv != null && fromEnv.isNotEmpty && File(fromEnv).existsSync()) {
    return fromEnv;
  }
  final List<String> dirs = <String>[
    p.dirname(Platform.resolvedExecutable),
    p.join(p.dirname(Platform.resolvedExecutable), 'ffmpeg'),
    p.join(Directory.current.path, 'ffmpeg'),
    Directory.current.path,
  ];
  for (final String dir in dirs) {
    final String candidate = p.join(dir, name);
    if (File(candidate).existsSync()) return candidate;
  }
  final String? pathEnv = Platform.environment['PATH'];
  if (pathEnv != null) {
    for (final String dir in pathEnv.split(Platform.pathSeparator)) {
      if (dir.isEmpty) continue;
      final String candidate = p.join(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

/// 当前环境是否可用 ffmpeg（用于 UI 显示“转码播放”入口）。
bool get ffmpegAvailable {
  _ensureLocated();
  return _ffmpegPath != null;
}

/// ffmpeg 版本字符串；未找到时返回 null。
Future<String?> ffmpegVersion() async {
  _ensureLocated();
  final String? exe = _ffmpegPath;
  if (exe == null) return null;
  try {
    final ProcessResult result = await Process.run(exe, <String>['-version']);
    final String output = '${result.stdout}${result.stderr}';
    return output.split('\n').first.trim();
  } catch (_) {
    return null;
  }
}

/// 读取媒体信息：优先 ffprobe -print_format json，失败回退 ffmpeg -i。
Future<MediaProbeInfo?> probeMedia(String filePath) async {
  _ensureLocated();
  if (!File(filePath).existsSync()) return null;
  final String? probe = _ffprobePath;
  if (probe != null) {
    try {
      final ProcessResult result = await Process.run(probe, <String>[
        '-v',
        'quiet',
        '-print_format',
        'json',
        '-show_format',
        '-show_streams',
        filePath,
      ]);
      if (result.exitCode == 0) {
        final Object? decoded = jsonDecode('${result.stdout}');
        if (decoded is Map<String, dynamic>) {
          final MediaProbeInfo? info = _infoFromProbeJson(decoded);
          if (info != null) return info;
        }
      }
    } catch (_) {
      // 继续回退到 ffmpeg -i。
    }
  }
  final String? exe = _ffmpegPath;
  if (exe == null) return null;
  try {
    final ProcessResult result = await Process.run(exe, <String>['-i', filePath]);
    return _infoFromFfmpegOutput('${result.stderr}', filePath);
  } catch (_) {
    return null;
  }
}

MediaProbeInfo? _infoFromProbeJson(Map<String, dynamic> json) {
  final Object? format = json['format'];
  final String formatName = format is Map ? '${format['format_name'] ?? ''}' : '';
  int durationMs = 0;
  if (format is Map && format['duration'] is num) {
    durationMs = (format['duration'] as num).toDouble() * 1000 ~/ 1;
  }
  final Object? streams = json['streams'];
  int width = 0;
  int height = 0;
  String videoCodec = '';
  String audioCodec = '';
  if (streams is List) {
    for (final Object? raw in streams) {
      if (raw is! Map) continue;
      final String codec = '${raw['codec_name'] ?? ''}';
      final String type = '${raw['codec_type'] ?? ''}';
      if (type == 'video' && videoCodec.isEmpty) {
        videoCodec = codec;
        width = (raw['width'] as num?)?.toInt() ?? 0;
        height = (raw['height'] as num?)?.toInt() ?? 0;
      } else if (type == 'audio' && audioCodec.isEmpty) {
        audioCodec = codec;
      }
    }
    if (durationMs == 0) {
      for (final Object? raw in streams) {
        if (raw is Map && raw['duration'] is num) {
          durationMs = (raw['duration'] as num).toDouble() * 1000 ~/ 1;
          if (durationMs > 0) break;
        }
      }
    }
  }
  if (formatName.isEmpty && videoCodec.isEmpty && audioCodec.isEmpty) {
    return null;
  }
  return MediaProbeInfo(
    format: formatName,
    durationMs: durationMs,
    width: width,
    height: height,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
  );
}

MediaProbeInfo? _infoFromFfmpegOutput(String output, String filePath) {
  final RegExp durationRe = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)');
  final RegExpMatch? match = durationRe.firstMatch(output);
  int durationMs = 0;
  if (match != null) {
    final int h = int.tryParse(match.group(1) ?? '0') ?? 0;
    final int m = int.tryParse(match.group(2) ?? '0') ?? 0;
    final double s = double.tryParse(match.group(3) ?? '0') ?? 0;
    durationMs = ((h * 3600 + m * 60 + s) * 1000).toInt();
  }
  String videoCodec = '';
  String audioCodec = '';
  final RegExp streamRe = RegExp(r'Stream #\d+:\d+.*?:\s*(\w+)', multiLine: true);
  for (final RegExpMatch m in streamRe.allMatches(output)) {
    final String line = output.substring(m.start, m.end);
    final String codec = m.group(1) ?? '';
    if (line.contains('Video:') && videoCodec.isEmpty) videoCodec = codec;
    if (line.contains('Audio:') && audioCodec.isEmpty) audioCodec = codec;
  }
  if (durationMs == 0 && videoCodec.isEmpty && audioCodec.isEmpty) return null;
  return MediaProbeInfo(
    format: p.extension(filePath).replaceFirst('.', ''),
    durationMs: durationMs,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
  );
}

/// 转码目标：视频转 H.264/AAC MP4，音频转 MP3。
enum TranscodeTarget { video, audio }

/// 将原生播放器无法识别的媒体转码到临时目录，返回产物路径。
///
/// 返回 null 表示没有 ffmpeg 或转码失败；调用方应提示用户原文件仍可直接打开。
Future<String?> transcodeMedia(
  String filePath, {
  required TranscodeTarget target,
  required String tempDir,
}) async {
  _ensureLocated();
  final String? exe = _ffmpegPath;
  if (exe == null) return null;
  final String base = p.basenameWithoutExtension(filePath);
  final String extension = target == TranscodeTarget.video ? 'mp4' : 'mp3';
  final String output = p.join(
    tempDir,
    'nexmem-transcode-$base-${DateTime.now().microsecondsSinceEpoch}.$extension',
  );
  final List<String> args = <String>[
    '-y',
    '-i',
    filePath,
    if (target == TranscodeTarget.video) ...<String>[
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
    ] else ...<String>['-vn', '-c:a', 'libmp3lame'],
    output,
  ];
  try {
    final ProcessResult result = await Process.run(exe, args);
    if (result.exitCode == 0 && File(output).existsSync()) return output;
  } catch (_) {
    // 忽略：由调用方展示“转码失败”提示。
  }
  return null;
}
