import 'package:material_ui/material_ui.dart';

import '../../app/core_session.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import 'contact_service.dart';
import '../../app/app_dialog.dart';

/// 打开「添加好友」弹窗（ui-spec.md §2 / §4）。
///
/// 供通讯录顶部按钮与会话列表 `+` 菜单共用；添加成功返回 `true`，
/// 取消返回 `false`，用户直接关闭返回 `null`。
Future<bool?> showAddFriendDialog(
  BuildContext context,
  ContactService service,
) {
  return showAppDialog<bool>(
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
  CoreSession? session,
}) {
  return showAppDialog<bool>(
    context: context,
    builder: (BuildContext context) => AddFriendDialog(
      service: service,
      initialAccount: account,
      initialAlias: alias,
      session: session,
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
    this.session,
  });

  final ContactService service;

  /// 二维码名片解析后的预填账号与备注（P6-39）。
  final String initialAccount;
  final String initialAlias;

  /// 传入时用「好友申请」流程（发送验证消息），否则直接添加（P2-06）。
  final CoreSession? session;

  bool get _useRequest => session != null;

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
  late final TextEditingController _message = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _account.dispose();
    _alias.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String invalidAccount = context.t('账号格式不正确，请粘贴完整公钥');
    final String account = _account.text.trim();
    if (account.isEmpty) {
      setState(() => _error = context.t('请输入对方账号公钥'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget._useRequest) {
        await widget.session!.social.sendFriendRequest(
          account,
          message: _message.text.trim(),
        );
      } else {
        await widget.service.add(account, alias: _alias.text.trim());
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on NexmemException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.code == 'INVALID_ARG'
              ? invalidAccount
              : (error.message.isEmpty ? error.code : error.message);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('添加好友')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('contact-add-account'),
            controller: _account,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.t('账号公钥'),
              helperText: context.t('对方在「好友资料」中可复制的账号'),
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget._useRequest)
            Padding(
              padding: const EdgeInsets.only(top: NexmemMetrics.space12),
              child: TextField(
                key: const ValueKey<String>('contact-add-message'),
                controller: _message,
                decoration: InputDecoration(
                  labelText: context.t('验证消息（可选）'),
                  helperText: context.t('对方同意申请时会看到'),
                  border: const OutlineInputBorder(),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: NexmemMetrics.space12),
              child: TextField(
                key: const ValueKey<String>('contact-add-alias'),
                controller: _alias,
                decoration: InputDecoration(
                  labelText: context.t('备注（可选）'),
                  helperText: context.t('仅本机可见'),
                  border: const OutlineInputBorder(),
                ),
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
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('contact-add-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy
              ? context.t('发送中…')
              : widget._useRequest
                  ? context.t('发送申请')
                  : context.t('添加')),
        ),
      ],
    );
  }
}
