/// 多设备设置同步（P6-41，本地闭环）：导出本机设置快照文本，或从另一台
/// 设备粘贴快照导入合并。实时跨设备推送依赖共用 S3 桶 / 真机，按 R-17 挂起；
/// 本弹窗只做「文件/剪贴板搬运」闭环，不伪造实时同步能力。
library;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart' show NexmemColors, NexmemMetrics;
import '../../transport/transport.dart' show NexmemException;
import 'settings_service.dart';

/// 打开多设备设置同步弹窗。
Future<void> showSettingsSyncDialog(
  BuildContext context,
  SettingsService settings,
) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => SettingsSyncDialog(settings: settings),
  );
}

class SettingsSyncDialog extends StatefulWidget {
  const SettingsSyncDialog({super.key, required this.settings});

  final SettingsService settings;

  @override
  State<SettingsSyncDialog> createState() => _SettingsSyncDialogState();
}

class _SettingsSyncDialogState extends State<SettingsSyncDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _feedback(String text, {bool error = false}) {
    setState(() {
      _message = text;
      _error = error;
    });
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final SettingsSnapshot snapshot = await widget.settings.exportSnapshot();
      _controller.text = snapshot.snapshot;
      await Clipboard.setData(ClipboardData(text: snapshot.snapshot));
      _feedback('已导出 ${snapshot.count} 项设置并复制到剪贴板');
    } on Object catch (error) {
      _feedback('导出失败：$error', error: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _import() async {
    final String snapshot = _controller.text.trim();
    if (snapshot.isEmpty) {
      _feedback('请先粘贴另一设备导出的设置快照', error: true);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final int applied = await widget.settings.importSnapshot(snapshot);
      _feedback('已合并 $applied 项设置；部分设置需重启生效');
    } on NexmemException catch (error) {
      _feedback(
        error.code == 'INVALID_ARG'
            ? '设置快照无效或校验失败'
            : (error.message.isEmpty ? error.code : error.message),
        error: true,
      );
    } on Object catch (error) {
      _feedback('导入失败：$error', error: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('多设备设置同步'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '导出本机设置后，把文本复制到另一台设备即可导入合并；实时同步需多端共用存储，暂未开放。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: NexmemMetrics.space12),
            TextField(
              key: const ValueKey<String>('settings-sync-snapshot'),
              controller: _controller,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '设置快照文本',
                hintText: 'settings://v1/...',
                border: OutlineInputBorder(),
              ),
            ),
            if (_message != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _message!,
                key: const ValueKey<String>('settings-sync-message'),
                style: TextStyle(
                  fontSize: 12,
                  color: _error ? NexmemColors.danger : NexmemColors.primary,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('settings-sync-export'),
          onPressed: _busy ? null : _export,
          child: const Text('导出并复制'),
        ),
        TextButton(
          key: const ValueKey<String>('settings-sync-import'),
          onPressed: _busy ? null : _import,
          child: const Text('导入合并'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
