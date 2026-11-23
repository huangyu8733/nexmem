import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Web 端「仅在线接收」说明条（ui-spec.md §5 / §7）。
///
/// 浏览器关闭后没有实时通道，首次进入时提示一次；关闭后由壳层落
/// `localStorage`，不再重复弹出。设置页另有常驻说明。
class WebOnlineNoticeBanner extends StatelessWidget {
  const WebOnlineNoticeBanner({super.key, required this.onDismiss});

  /// 用户点击「知道了」；由壳层负责记录并收起。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('web-online-notice'),
      width: double.infinity,
      color: scheme.primary.withValues(alpha: 0.08),
      padding: const EdgeInsets.only(
        left: NexmemMetrics.space12,
        right: NexmemMetrics.space4,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: scheme.primary),
          const SizedBox(width: NexmemMetrics.space8),
          Expanded(
            child: Text(
              '浏览器关闭后不再实时接收消息，离线消息将在下次打开时补齐。',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey<String>('web-online-notice-dismiss'),
            onPressed: onDismiss,
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
