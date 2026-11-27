import 'package:material_ui/material_ui.dart';

import '../l10n/l10n.dart';
import 'app_toast_speaker_native.dart'
    if (dart.library.js_interop) 'app_toast_speaker_web.dart' as speaker;
import 'theme.dart';

/// Web 端「仅在线接收」说明文案，提示条与语音播报共用。
const String webOnlineNoticeText =
    '浏览器关闭后不再实时接收消息，离线消息将在下次打开时补齐。';

/// Web 端「仅在线接收」说明条（ui-spec.md §5 / §7）。
///
/// 浏览器关闭后没有实时通道，首次进入时提示一次；关闭后由壳层落
/// `localStorage`，不再重复弹出。设置页另有常驻说明。
class WebOnlineNoticeBanner extends StatefulWidget {
  const WebOnlineNoticeBanner({super.key, required this.onDismiss});

  /// 用户点击「知道了」；由壳层负责记录并收起。
  final VoidCallback onDismiss;

  @override
  State<WebOnlineNoticeBanner> createState() => _WebOnlineNoticeBannerState();
}

class _WebOnlineNoticeBannerState extends State<WebOnlineNoticeBanner> {
  bool _spoken = false;

  @override
  Widget build(BuildContext context) {
    if (!_spoken) {
      _spoken = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          speaker.speakNotice(context.t(webOnlineNoticeText));
        }
      });
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('web-online-notice'),
      width: double.infinity,
      color: scheme.primary.withValues(alpha: 0.08),
      padding: EdgeInsetsDirectional.only(
        start: NexmemMetrics.space12,
        end: NexmemMetrics.space4,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: scheme.primary),
          const SizedBox(width: NexmemMetrics.space8),
          Expanded(
            child: Text(
              context.t(webOnlineNoticeText),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey<String>('web-online-notice-dismiss'),
            onPressed: widget.onDismiss,
            child: Text(context.t('知道了')),
          ),
        ],
      ),
    );
  }
}
