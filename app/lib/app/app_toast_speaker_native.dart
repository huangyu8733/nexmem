import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'message_notification_sound.dart';

/// 非 Web 端提示音：播放与新消息相同的「叮咚」短音，不朗读提示文字。
/// 无音频设备或测试环境缺少插件时静默降级，不影响提示条本身。
final AudioPlayer _toastPlayer = AudioPlayer();

void speakNotice(String text) {
  if (text.isEmpty) {
    return;
  }
  try {
    unawaited(_toastPlayer.stop().catchError((Object _) {}));
    unawaited(
      _toastPlayer
          .play(AssetSource(kMessageSoundAsset.replaceFirst('assets/', '')))
          .catchError((Object _) {}),
    );
  } catch (_) {
    // 无音频设备/无插件环境：保留右上角文字提示。
  }
}
