import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// QQ 风格的统一头像：圆角方形、按 ID 稳定取色、支持文字/图标/图片。
///
/// 各列表此前各自用 `CircleAvatar` + 首字母，风格零散。统一到本组件后，
/// 会话、联系人、群成员、聊天气泡等位置视觉一致；seed 相同则配色与首字母
/// 始终相同，避免同一对象在不同页面颜色漂移。
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.seed,
    this.label,
    this.icon,
    this.imageBytes,
    this.size = NexmemMetrics.avatarSize,
    this.showPresence = false,
    this.presence = AvatarPresence.online,
    this.radius,
  });

  /// 取色与首字母的稳定种子，通常传账号 / 会话 ID。
  final String seed;

  /// 展示文字；为空时取 seed 首个字。imageBytes / icon 优先于文字。
  final String? label;

  /// 群聊等场景使用的图标；优先于文字。
  final IconData? icon;

  /// 已解码的头像图片（来自设置 KV）；优先级最高。
  final Uint8List? imageBytes;

  final double size;

  final bool showPresence;
  final AvatarPresence presence;
  final double? radius;

  Color get _base =>
      NexmemColors.avatarPalette[seed.hashCode.abs() %
          NexmemColors.avatarPalette.length];

  @override
  Widget build(BuildContext context) {
    final double side = radius ?? NexmemMetrics.avatarRadius;
    final Color base = _base;
    final String text = (label ?? seed).trim();
    final String initial = text.isEmpty ? '?' : text.substring(0, 1);

    final Widget face = ClipRRect(
      borderRadius: BorderRadius.circular(side),
      child: Container(
        width: size,
        height: size,
        color: base.withValues(alpha: 0.16),
        child: imageBytes != null
            ? Image.memory(
                imageBytes!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallback(base, initial),
              )
            : icon != null
                ? Icon(icon, size: size * 0.5, color: base)
                : _fallback(base, initial),
      ),
    );

    if (!showPresence) {
      return SizedBox(width: size, height: size, child: face);
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          face,
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: size * 0.27,
              height: size * 0.27,
              decoration: BoxDecoration(
                color: presence.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallback(Color base, String initial) => Center(
        child: Text(
          initial,
          style: TextStyle(
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
            color: base,
          ),
        ),
      );
}

/// 头像右下角的在线状态点。
enum AvatarPresence {
  online(NexmemColors.success),
  relay(NexmemColors.warning),
  offline(NexmemColors.unreadMuted);

  const AvatarPresence(this.color);

  final Color color;
}
