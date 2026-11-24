import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import 'profile_image.dart';
import 'settings_service.dart';

/// 本机头像的全局缓存。
///
/// 头像以 base64 分片写入设置 KV（见 [ProfileImageStore]），但壳层左栏头像、
/// 「我的」页卡片等位置此前只画了占位图标，从不读取 KV，导致用户设置了头像
/// 却在任何主界面都看不到。这里在内核就绪时加载一次，并在资料页保存/移除
/// 头像后刷新；所有展示自己头像的位置监听本缓存即可。
class ProfileAvatarStore extends ChangeNotifier {
  static final ProfileAvatarStore instance = ProfileAvatarStore._internal();

  ProfileAvatarStore._internal();

  SettingsService? _settings;
  Uint8List? _bytes;
  int _generation = 0;

  Uint8List? get bytes => _bytes;

  /// 仅供测试重置单例状态，避免用例间相互污染。
  @visibleForTesting
  void resetForTest() {
    _generation++;
    _settings = null;
    _bytes = null;
  }

  /// 绑定设置服务并加载头像；重复调用只会覆盖绑定并重新读取。
  void attach(SettingsService settings) {
    _settings = settings;
    unawaited(reload());
  }

  /// 从 KV 重新读取头像。并发调用以最后一次为准，避免旧结果覆盖新结果。
  Future<void> reload() async {
    final SettingsService? settings = _settings;
    if (settings == null) {
      return;
    }
    final int generation = ++_generation;
    try {
      final ProfileImageData? data = await ProfileImageStore(settings)
          .load(ProfileImageSlot.avatar);
      if (generation != _generation) {
        return;
      }
      _bytes = data?.bytes;
    } on Object {
      // 读取失败（例如内核尚未启动）时保留已有图片，避免短暂错误把头像清掉。
      if (generation != _generation) {
        return;
      }
    }
    notifyListeners();
  }
}

/// 展示本机头像的圆形组件：有已保存图片则显示图片，否则显示占位图标。
class SelfAvatar extends StatelessWidget {
  const SelfAvatar({
    super.key,
    this.radius = NexmemMetrics.avatarSize / 2,
    this.iconSize = 22,
  });

  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: ProfileAvatarStore.instance,
      builder: (BuildContext context, Widget? child) {
        final Uint8List? bytes = ProfileAvatarStore.instance.bytes;
        return CircleAvatar(
          radius: radius,
          backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
          child: bytes == null
              ? Icon(
                  Icons.person_outline,
                  size: iconSize,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                )
              : ClipOval(
                  child: Image.memory(
                    bytes,
                    width: radius * 2,
                    height: radius * 2,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.person_outline,
                      size: iconSize,
                      color: scheme.onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
