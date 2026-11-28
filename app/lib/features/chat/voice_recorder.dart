/// 按住说话（PTT）录音能力，基于 `record` 包。
///
/// - Android / iOS / 桌面：`record` 直接写本机临时 m4a 文件。
/// - Web：`record` 返回 blob URL，读出字节后经鉴权 `/upload` 上传到网关。
library;

import 'dart:async';

import 'package:record/record.dart';

import 'voice_recorder_platform.dart'
    if (dart.library.html) 'voice_recorder_platform_web.dart';

/// 一次完成的录音结果，可直接交给 `ChatStore.sendFile`。
class VoiceRecording {
  const VoiceRecording({
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
    required this.duration,
  });

  final String path;
  final String name;
  final String mime;
  final int size;

  /// 录音时长，用于气泡上展示语音秒数。
  final Duration duration;
}

abstract class VoiceRecorder {
  bool get supported;

  bool get isRecording;

  /// 开始录音。权限拒绝 / 设备不可用时返回 false。
  Future<bool> start();

  /// 停止录音并返回结果；过短或没有录音时返回 null。
  Future<VoiceRecording?> stop();

  /// 取消录音并删除临时文件。
  Future<void> cancel();
}

/// 无录音通道的平台安全降级。
class UnsupportedVoiceRecorder implements VoiceRecorder {
  const UnsupportedVoiceRecorder();

  @override
  bool get supported => false;

  @override
  bool get isRecording => false;

  @override
  Future<bool> start() async => false;

  @override
  Future<VoiceRecording?> stop() async => null;

  @override
  Future<void> cancel() async {}
}

/// 基于 `record` 的跨平台实现。
///
/// 平台差异只在输出路径与结果落地：[VoiceOutput.preparePath] 给出录音目标，
/// [VoiceOutput.finish] 把 `record` 的结果转成内核可读的路径与附件元数据。
class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder({
    this._recorder,
    VoiceOutput? output,
    this.endpoint,
    this.token = '',
  }) : _output = output ?? createVoiceOutput(endpoint: endpoint, token: token);

  AudioRecorder? _recorder;
  final VoiceOutput _output;

  /// 延迟创建：AudioRecorder() 构造时会调用原生 `create`，不能在会话构建阶段触发。
  AudioRecorder get recorder => _recorder ??= AudioRecorder();

  /// Web 上传网关地址；桌面 / 移动端忽略。
  final Uri? endpoint;
  final String token;

  DateTime? _startedAt;
  bool _recording = false;

  @override
  bool get supported => true;

  @override
  bool get isRecording => _recording;

  @override
  Future<bool> start() async {
    if (_recording) return false;
    try {
      if (!await recorder.hasPermission(request: true)) return false;
      final String path = await _output.preparePath();
      await recorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: path,
      );
      _startedAt = DateTime.now();
      _recording = true;
      return true;
    } on Object {
      _recording = false;
      _startedAt = null;
      return false;
    }
  }

  @override
  Future<VoiceRecording?> stop() async {
    if (!_recording) return null;
    final Duration duration =
        DateTime.now().difference(_startedAt ?? DateTime.now());
    _recording = false;
    _startedAt = null;
    try {
      final String? path = await recorder.stop();
      if (path == null || path.isEmpty || duration.inMilliseconds < 400) {
        return null;
      }
      return await _output.finish(path, duration);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    if (!_recording) return;
    _recording = false;
    _startedAt = null;
    try {
      await recorder.cancel();
    } on Object {
      // 取消失败不影响 UI，临时文件由平台下次启动清理。
    }
  }

  Future<void> dispose() => _recorder?.dispose() ?? Future<void>.value();
}

/// 平台输出差异：开始前的目标路径，结束后的附件落地。
abstract class VoiceOutput {
  Future<String> preparePath();

  Future<VoiceRecording> finish(String path, Duration duration);
}

/// 工厂：Web 需要网关地址以上传录音字节；其他平台忽略这两个参数。
VoiceRecorder makeVoiceRecorder({Uri? endpoint, String token = ''}) =>
    RecordVoiceRecorder(endpoint: endpoint, token: token);
