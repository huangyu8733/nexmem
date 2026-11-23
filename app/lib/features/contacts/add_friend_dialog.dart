import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../transport/transport.dart';
import 'contact_service.dart';

/// 打开「添加好友」弹窗（ui-spec.md §2 / §4）。
///
/// 供通讯录顶部按钮与会话列表 `+` 菜单共用；添加成功返回 `true`，
/// 取消返回 `false`，用户直接关闭返回 `null`。
Future<bool?> showAddFriendDialog(
  BuildContext context,
  ContactService service,
) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AddFriendDialog(service: service),
  );
}

/// 预填账号与备注打开添加好友弹窗（P6-39 二维码名片解析后复用）。
Future<bool?> showAddFriendDialogWithPreset(
  BuildContext context,
  ContactService service, {
  required String account,
  required String alias,
}) {
  return showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AddFriendDialog(
      service: service,
      initialAccount: account,
      initialAlias: alias,
    ),
  );
}

/// 添加好友弹窗：账号公钥（十六进制或 base64url）加可选备注。
class AddFriendDialog extends StatefulWidget {
  const AddFriendDialog({
    super.key,
    required this.service,
    this.initialAccount = '',
    this.initialAlias = '',
  });

  final ContactService service;

  /// 二维码名片解析后的预填账号与备注（P6-39）。
  final String initialAccount;
  final String initialAlias;

  @override
  State<AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<AddFriendDialog> {
  late final TextEditingController _account = TextEditingController(
    text: widget.initialAccount,
  );
  late final TextEditingController _alias = TextEditingController(
    text: widget.initialAlias,
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _account.dispose();
    _alias.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String account = _account.text.trim();
    if (account.isEmpty) {
      setState(() => _error = '请输入对方账号公钥');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.add(account, alias: _alias.text.trim());
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on NexmemException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.code == 'INVALID_ARG'
              ? '账号格式不正确，请粘贴完整公钥'
              : (error.message.isEmpty ? error.code : error.message);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加好友'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('contact-add-account'),
            controller: _account,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '账号公钥',
              helperText: '对方在「好友资料」中可复制的账号',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: NexmemMetrics.space12),
          TextField(
            key: const ValueKey<String>('contact-add-alias'),
            controller: _alias,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              helperText: '仅本机可见',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: NexmemMetrics.space12),
              child: Text(
                _error!,
                key: const ValueKey<String>('contact-add-error'),
                style: const TextStyle(fontSize: 13, color: NexmemColors.danger),
              ),
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('contact-add-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '添加中…' : '添加'),
        ),
      ],
    );
  }
}
