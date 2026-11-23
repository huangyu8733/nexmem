import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../transport/transport.dart';

/// 备份导出的方向，用于区分文案与确认项。
enum BackupMode { export, import }

/// 加密备份服务，对应 gateway 的 `backup.export` / `backup.import`（P6-05）。
///
/// 备份包始终由 Go 侧在本机写盘，通道内只传绝对路径与口令（口令以 base64 传输）。
abstract class BackupService {
  /// 导出到 [path]，返回实际落盘路径。
  Future<String> export({required String path, required String passphrase});

  /// 从 [path] 导入，返回来源路径。
  Future<String> import({required String path, required String passphrase});
}

/// 通过统一传输层调用备份方法。
class TransportBackupService implements BackupService {
  TransportBackupService(this._transport);

  final CoreTransport _transport;

  @override
  Future<String> export({
    required String path,
    required String passphrase,
  }) async {
    final Map<String, dynamic> data = await _transport.call(
      'backup.export',
      params: _params(path, passphrase),
    );
    final Object? result = data['path'];
    if (result is! String || result.isEmpty) {
      throw const NexmemException('INVALID_ARG', 'backup.export 未返回备份路径');
    }
    return result;
  }

  @override
  Future<String> import({required String path, required String passphrase}) async {
    await _transport.call('backup.import', params: _params(path, passphrase));
    return path;
  }

  Map<String, dynamic> _params(String path, String passphrase) {
    return <String, dynamic>{
      'path': path,
      'passphrase_b64': base64Encode(utf8.encode(passphrase)),
    };
  }
}

/// 未接入内核时的占位实现：明确抛 `NOT_STARTED`，UI 不做静默失败。
class UnavailableBackupService implements BackupService {
  const UnavailableBackupService();

  @override
  Future<String> export({
    required String path,
    required String passphrase,
  }) async {
    throw const NexmemException('NOT_STARTED', '备份能力尚未接入内核');
  }

  @override
  Future<String> import({required String path, required String passphrase}) async {
    throw const NexmemException('NOT_STARTED', '备份能力尚未接入内核');
  }
}

/// 「账号与安全」：导出 / 导入加密备份。
class AccountSecurityDialog extends StatelessWidget {
  const AccountSecurityDialog({super.key, required this.backup});

  final BackupService backup;

  Future<void> _open(BuildContext context, BackupMode mode) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool? done = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          _BackupFlowDialog(mode: mode, backup: backup),
    );
    if (done != true) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          mode == BackupMode.export
              ? '备份已导出，请妥善保管文件与口令'
              : '备份已导入，重启后可查看恢复的好友与消息',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('账号与安全'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ListTile(
              key: const ValueKey<String>('account-export'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.upload_file_outlined, size: 22),
              title: const Text('导出备份'),
              subtitle: const Text('账号密钥、好友与历史消息，口令加密'),
              onTap: () => _open(context, BackupMode.export),
            ),
            ListTile(
              key: const ValueKey<String>('account-import'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.download_outlined, size: 22),
              title: const Text('导入备份'),
              subtitle: const Text('从备份文件恢复好友与历史消息'),
              onTap: () => _open(context, BackupMode.import),
            ),
            const SizedBox(height: NexmemMetrics.space8),
            Text(
              '备份只在本机生成，不会上传。口令丢失将无法恢复，请离线保存。',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _BackupFlowDialog extends StatefulWidget {
  const _BackupFlowDialog({required this.mode, required this.backup});

  final BackupMode mode;
  final BackupService backup;

  @override
  State<_BackupFlowDialog> createState() => _BackupFlowDialogState();
}

class _BackupFlowDialogState extends State<_BackupFlowDialog> {
  final TextEditingController _path = TextEditingController();
  final TextEditingController _passphrase = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  bool get _isExport => widget.mode == BackupMode.export;

  @override
  void dispose() {
    _path.dispose();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String path = _path.text.trim();
    final String passphrase = _passphrase.text;
    if (path.isEmpty) {
      setState(() => _error = '请填写备份文件路径');
      return;
    }
    if (passphrase.isEmpty) {
      setState(() => _error = '请填写备份口令');
      return;
    }
    if (_isExport && _confirm.text != passphrase) {
      setState(() => _error = '两次输入的口令不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isExport) {
        await widget.backup.export(path: path, passphrase: passphrase);
      } else {
        await widget.backup.import(path: path, passphrase: passphrase);
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on NexmemException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = _errorText(e);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = _isExport ? '导出失败，请检查路径后重试' : '导入失败，请检查文件后重试';
      });
    }
  }

  String _errorText(NexmemException e) {
    switch (e.code) {
      case 'NOT_STARTED':
        return '备份能力尚未接入内核';
      case 'CRYPTO_ERROR':
        return '口令错误或备份文件已损坏';
      case 'INVALID_ARG':
        return '参数不合法：${e.message}';
      default:
        return '${_isExport ? '导出' : '导入'}失败（${e.code}），请稍后再试';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isExport ? '导出备份' : '导入备份'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const ValueKey<String>('backup-path'),
                controller: _path,
                decoration: const InputDecoration(
                  labelText: '备份文件路径',
                  hintText: '/data/nexmem/account.nexbak',
                ),
              ),
              const SizedBox(height: NexmemMetrics.space12),
              TextField(
                key: const ValueKey<String>('backup-passphrase'),
                controller: _passphrase,
                obscureText: true,
                decoration: const InputDecoration(labelText: '备份口令'),
              ),
              if (_isExport) ...<Widget>[
                const SizedBox(height: NexmemMetrics.space12),
                TextField(
                  key: const ValueKey<String>('backup-passphrase-confirm'),
                  controller: _confirm,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认口令'),
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: NexmemMetrics.space12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    key: const ValueKey<String>('backup-error'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey<String>('backup-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(_isExport ? '开始导出' : '开始导入'),
        ),
      ],
    );
  }
}
