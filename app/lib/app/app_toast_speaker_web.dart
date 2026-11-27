import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'message_notification_sound.dart';

/// Web 端提示音：播放与新消息相同的「叮咚」短音，不朗读提示文字。
///
/// 浏览器自动播放策略可能拦截首次交互前的音频，这里静默降级，
/// 不影响右上角文字提示本身。
final AudioPlayer _toastPlayer = AudioPlayer();

void speakNotice(String text) {
  if (text.trim().isEmpty) {
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
    // 音频不可用时保留右上角文字提示。
  }
}
