// 新消息提示音：入站响一次、节流防轰炸、失败静默降级。
import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/app/message_notification_sound.dart';

class _FakePlayer implements MessageSoundPlayer {
  final List<String> played = <String>[];
  bool fail = false;

  @override
  Future<void> play(String asset) async {
    if (fail) {
      throw StateError('no audio device');
    }
    played.add(asset);
  }
}

void main() {
  test('入站消息播放叮咚音', () async {
    final _FakePlayer player = _FakePlayer();
    final MessageNotificationSound sound = MessageNotificationSound(player: player);
    expect(await sound.notify(), isTrue);
    expect(player.played, <String>[kMessageSoundAsset]);
  });

  test('节流窗口内不重复播放', () async {
    final _FakePlayer player = _FakePlayer();
    DateTime now = DateTime(2026, 11, 27, 12);
    final MessageNotificationSound sound = MessageNotificationSound(
      player: player,
      now: () => now,
    );
    expect(await sound.notify(), isTrue);
    now = now.add(const Duration(milliseconds: 300));
    expect(await sound.notify(), isFalse);
    now = now.add(const Duration(milliseconds: 500));
    expect(await sound.notify(), isTrue);
    expect(player.played.length, 2);
  });

  test('播放失败静默降级', () async {
    final _FakePlayer player = _FakePlayer()..fail = true;
    final MessageNotificationSound sound = MessageNotificationSound(player: player);
    expect(await sound.notify(), isFalse);
  });
}
