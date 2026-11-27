// 远控密码输入弹窗：新增 / 修改密码，或验证已有密码。
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 'remote_password.dart';

/// 返回用户输入的明文密码；调用方应立刻转成 credential，不要持久化明文。
///
/// [expectedCredential] 非空时进入「验证已有密码」模式，只显示一个输入框。
Future<String?> showRemotePasswordDialog({
  required BuildContext context,
  required String title,
  required String confirmLabel,
  String? expectedCredential,
  String? message,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) => _RemotePasswordDialog(
      title: title,
      confirmLabel: confirmLabel,
      expectedCredential: expectedCredential,
      message: message,
    ),
  );
}

class _RemotePasswordDialog extends StatefulWidget {
  const _RemotePasswordDialog({
    required this.title,
    required this.confirmLabel,
    required this.expectedCredential,
    required this.message,
  });

  final String title;
  final String confirmLabel;
  final String? expectedCredential;
  final String? message;

  @override
  State<_RemotePasswordDialog> createState() => _RemotePasswordDialogState();
}

class _RemotePasswordDialogState extends State<_RemotePasswordDialog> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String value = _password.text;
    String? problem = validateRemotePassword(value);
    if (problem == null &&
        widget.expectedCredential == null &&
        value != _confirmation.text) {
      problem = '两次密码不一致';
    }
    if (problem == null &&
        widget.expectedCredential != null &&
        !remotePasswordMatches(
          password: value,
          credential: widget.expectedCredential!,
        )) {
      problem = '远程控制密码错误';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final bool verifying = widget.expectedCredential != null;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.message != null && widget.message!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  widget.message!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            TextField(
              key: const ValueKey<String>('remote-password-input'),
              controller: _password,
              obscureText: _obscure,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.t(verifying ? '当前远程控制密码' : '远程控制密码'),
                suffixIcon: IconButton(
                  tooltip: context.t(_obscure ? '显示密码' : '隐藏密码'),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => unawaited(_submit()),
            ),
            if (!verifying) ...<Widget>[
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey<String>('remote-password-confirm'),
                controller: _confirmation,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: context.t('确认远程控制密码'),
                ),
                onSubmitted: (_) => unawaited(_submit()),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  context.t(_error!),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('remote-password-submit'),
          onPressed: () => unawaited(_submit()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
