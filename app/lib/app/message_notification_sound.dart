// 新消息提示音：经典 QQ 风格「叮咚」短音。
//
// 只给内核标记 direction=in 的入站消息响；带节流，避免群消息轰炸时
// 音频叠加。Web 端 audioplayers 走浏览器 Audio 元素，首次交互前可能被
// 浏览器自动播放策略拦截，这里静默降级，不影响消息本身。

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

const String kMessageSoundAsset = 'assets/message_dingdong.wav';

/// 两条提示音最短间隔；低于此间隔的后续消息不重复响。
const Duration kMessageSoundGap = Duration(milliseconds: 700);

/// 可注入的播放器，便于 Widget 测试替身。
abstract class MessageSoundPlayer {
  Future<void> play(String asset);
}

class _AudioPlayersSoundPlayer implements MessageSoundPlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> play(String asset) async {
    await _player.stop();
    await _player.play(AssetSource(asset.replaceFirst('assets/', '')));
  }

  Future<void> dispose() => _player.dispose();
}

/// 新消息提示音控制器：调用 [notify] 即尝试播放，内部按时间节流。
class MessageNotificationSound {
  MessageNotificationSound({MessageSoundPlayer? player, DateTime Function()? now})
      : _player = player ?? _AudioPlayersSoundPlayer(),
        _now = now ?? DateTime.now;

  final MessageSoundPlayer _player;
  final DateTime Function() _now;
  DateTime? _lastPlayed;

  /// 收到一条入站消息时调用。返回是否实际播放。
  Future<bool> notify() async {
    final DateTime current = _now();
    final DateTime? last = _lastPlayed;
    if (last != null && current.difference(last) < kMessageSoundGap) {
      return false;
    }
    _lastPlayed = current;
    try {
      await _player.play(kMessageSoundAsset);
      return true;
    } on Object catch (_) {
      // 无音频设备、浏览器自动播放被拒、测试环境无插件：静默降级。
      return false;
    }
  }

  Future<void> dispose() async {
    final Object player = _player;
    if (player is _AudioPlayersSoundPlayer) {
      await player.dispose();
    }
  }
}
