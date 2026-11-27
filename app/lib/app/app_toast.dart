import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../l10n/l10n.dart';
import 'theme.dart';
import 'app_toast_speaker_native.dart'
    if (dart.library.js_interop) 'app_toast_speaker_web.dart' as speaker;

/// 右上角小提示控制器。
///
/// 替代底部 SnackBar：所有壳层提示统一从这里发出，显示时播放短提示音，
/// 4 秒后自动收起；新提示覆盖旧提示并重新计时。提示音不朗读文案。
class AppToastController extends ChangeNotifier {
  String? _message;
  String? _actionLabel;
  VoidCallback? _onAction;
  Timer? _timer;

  String? get message => _message;
  String? get actionLabel => _actionLabel;
  VoidCallback? get onAction => _onAction;

  void show(
    String message, {
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    VoidCallback? onAction,
    bool speak = true,
  }) {
    if (message.trim().isEmpty) {
      return;
    }
    _timer?.cancel();
    _message = message;
    _actionLabel = actionLabel;
    _onAction = onAction;
    notifyListeners();
    if (speak) {
      speaker.speakNotice(message);
    }
    _timer = Timer(duration, dismiss);
  }

  void dismiss() {
    if (_message == null) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    _message = null;
    _actionLabel = null;
    _onAction = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// 右上角提示浮层；需放在页面最外层 Stack 中，保证覆盖全屏通话页。
class AppToastOverlay extends StatelessWidget {
  const AppToastOverlay({
    super.key,
    required this.controller,
    this.top = 34,
  });

  final AppToastController controller;

  /// 距离屏幕顶部距离；有状态栏/来电通知条时下移，避免互相遮挡。
  final double top;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final String? message = controller.message;
        if (message == null) {
          return const Positioned(child: SizedBox.shrink());
        }
        final ColorScheme scheme = Theme.of(context).colorScheme;
        return Positioned(
          top: top,
          right: NexmemMetrics.space12,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Material(
              key: const ValueKey<String>('app-toast'),
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NexmemMetrics.space12,
                  vertical: NexmemMetrics.space8,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.notifications_active_outlined,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: NexmemMetrics.space8),
                    Expanded(
                      child: Text(
                        message,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface,
                            ),
                      ),
                    ),
                    if (controller.actionLabel != null)
                      TextButton(
                        key: const ValueKey<String>('app-toast-action'),
                        onPressed: () {
                          final VoidCallback? action = controller.onAction;
                          controller.dismiss();
                          action?.call();
                        },
                        child: Text(controller.actionLabel!),
                      ),
                    IconButton(
                      key: const ValueKey<String>('app-toast-close'),
                      icon: const Icon(Icons.close, size: 16),
                      visualDensity: VisualDensity.compact,
                      tooltip: context.t('关闭'),
                      onPressed: controller.dismiss,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
