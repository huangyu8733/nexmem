// 被控端远控请求弹窗：逐项选择授权能力，60 秒未处理自动拒绝。
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 'remote_session.dart';

class RemoteIncomingDialog extends StatefulWidget {
  const RemoteIncomingDialog({
    super.key,
    required this.info,
    required this.onAccept,
    required this.onReject,
  });

  final RemoteInfo info;
  final ValueChanged<RemotePermissions> onAccept;
  final VoidCallback onReject;

  @override
  State<RemoteIncomingDialog> createState() => _RemoteIncomingDialogState();
}

class _RemoteIncomingDialogState extends State<RemoteIncomingDialog> {
  late bool _input;
  late bool _clipboard;
  late bool _file;
  Timer? _timer;
  int _seconds = 60;

  @override
  void initState() {
    super.initState();
    _input = widget.info.requested.input;
    _clipboard = widget.info.requested.clipboard;
    _file = widget.info.requested.file;
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _seconds--);
      if (_seconds <= 0) {
        timer.cancel();
        widget.onReject();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  RemotePermissions get _selected => RemotePermissions(
        input: _input && widget.info.requested.input,
        clipboard: _clipboard && widget.info.requested.clipboard,
        file: _file && widget.info.requested.file,
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  CircleAvatar(
                    backgroundColor:
                        theme.colorScheme.primary.withValues(alpha: 0.15),
                    child: Icon(Icons.desktop_windows, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          context.t('远程控制请求'),
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          widget.info.peerName.isEmpty
                              ? widget.info.peer
                              : widget.info.peerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '$_seconds s',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                context.t('对方请求查看并控制你的屏幕，请选择允许的能力：'),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              if (widget.info.requested.input)
                CheckboxListTile(
                  key: const ValueKey<String>('remote-perm-input'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _input,
                  onChanged: (bool? value) =>
                      setState(() => _input = value ?? false),
                  title: Text(context.t(RemotePermission.input.label)),
                  subtitle: Text(context.t('模拟鼠标与键盘操作')),
                ),
              if (widget.info.requested.clipboard)
                CheckboxListTile(
                  key: const ValueKey<String>('remote-perm-clipboard'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _clipboard,
                  onChanged: (bool? value) =>
                      setState(() => _clipboard = value ?? false),
                  title: Text(context.t(RemotePermission.clipboard.label)),
                  subtitle: Text(context.t('发送/获取文本剪贴板')),
                ),
              if (widget.info.requested.file)
                CheckboxListTile(
                  key: const ValueKey<String>('remote-perm-file'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _file,
                  onChanged: (bool? value) =>
                      setState(() => _file = value ?? false),
                  title: Text(context.t(RemotePermission.file.label)),
                  subtitle: Text(context.t('接收对方发送的文件')),
                ),
              if (widget.info.requested.set.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    context.t('未请求额外能力，将仅查看屏幕'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                context.t('不勾选任何能力时仍可查看屏幕，但不能操作本机。'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    key: const ValueKey<String>('remote-reject'),
                    onPressed: widget.onReject,
                    child: Text(context.t('拒绝')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey<String>('remote-accept'),
                    onPressed: () => widget.onAccept(_selected),
                    child: Text(context.t('允许一次')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
