// Android / iOS / 桌面录音实现。Web 构建会替换为 voice_recorder_web.dart。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../permissions/app_permissions.dart';
import 'voice_recorder.dart';

/// 通过 `io.nexmem/core` 通道调用原生录音器。
class ChannelVoiceRecorder implements VoiceRecorder {
  ChannelVoiceRecorder({
    MethodChannel? channel,
    AppPermissions? permissions,
  })  : _channel = channel ?? const MethodChannel('io.nexmem/core'),
        _permissions = permissions ?? makeAppPermissions();

  final MethodChannel _channel;
  final AppPermissions _permissions;
  bool _recording = false;

  @override
  bool get supported => true;

  @override
  bool get isRecording => _recording;

  @override
  Future<bool> start() async {
    if (_recording) return false;
    final AppPermissionState state =
        await _permissions.request(AppPermissionKind.microphone);
    if (state == AppPermissionState.denied ||
        state == AppPermissionState.permanentlyDenied) {
      return false;
    }
    try {
      final bool? ok = await _channel.invokeMethod<bool>('startVoiceRecord');
      _recording = ok ?? false;
      return _recording;
    } on Object {
      _recording = false;
      return false;
    }
  }

  @override
  Future<VoiceRecording?> stop() async {
    if (!_recording) return null;
    _recording = false;
    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMapMethod<Object?, Object?>('stopVoiceRecord');
      if (raw == null) return null;
      final Object? path = raw['path'];
      if (path is! String || path.isEmpty) return null;
      return VoiceRecording(
        path: path,
        name: raw['name'] is String ? raw['name'] as String : 'voice.m4a',
        mime: raw['mime'] is String ? raw['mime'] as String : 'audio/mp4',
        size: (raw['size'] as num?)?.toInt() ?? 0,
        duration: Duration(
          milliseconds: (raw['durationMs'] as num?)?.toInt() ?? 0,
        ),
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    if (!_recording) return;
    _recording = false;
    try {
      await _channel.invokeMethod<void>('cancelVoiceRecord');
    } on Object {
      // 取消路径失败不影响 UI，临时文件由原生下次启动时清理。
    }
  }
}

VoiceRecorder createVoiceRecorder({Uri? endpoint, String token = ''}) {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return ChannelVoiceRecorder();
  }
  return const UnsupportedVoiceRecorder();
}
