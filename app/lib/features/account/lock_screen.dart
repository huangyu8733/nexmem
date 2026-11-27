import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import '../../app/theme.dart';
import '../settings/settings_pane.dart' show showPaneDialog;
import 'account_manager.dart';

/// 临时锁全屏界面：输入 PIN 解锁，错误时给出明确提示。
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.manager});

  final AccountManager manager;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final TextEditingController _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String pin = _pin.text.trim();
    if (pin.length < 4 || pin.length > 8) {
      setState(() => _error = context.t('请输入 4-8 位锁屏密码'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bool ok = await widget.manager.unlock(pin);
      if (!ok && mounted) {
        setState(() => _error = context.t('锁屏密码错误，请重试'));
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = context.t('解锁失败：{0}', ['$error']));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _pin.clear();
      }
    }
  }

  Future<void> _forgotPin() async {
    final bool? confirmed = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('忘记锁屏密码')),
        content: Text(
          context.t('清除锁屏密码会退出当前账号，但不会删除账号数据。确定继续？'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('lock-reset-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('确定')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.manager.resetPinAndLogout();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(NexmemMetrics.space24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(Icons.lock_outline, size: 56, color: scheme.primary),
                const SizedBox(height: NexmemMetrics.space16),
                Text(
                  context.t('临时锁'),
                  key: const ValueKey<String>('lock-title'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: NexmemMetrics.space8),
                Text(
                  context.t('应用已锁定，输入锁屏密码继续'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: NexmemMetrics.space24),
                TextField(
                  key: const ValueKey<String>('lock-pin-input'),
                  controller: _pin,
                  autofocus: true,
                  obscureText: true,
                  maxLength: 8,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: InputDecoration(
                    labelText: context.t('锁屏密码'),
                    border: const OutlineInputBorder(),
                    errorText: _error,
                  ),
                  onSubmitted: (_) => unawaited(_submit()),
                ),
                const SizedBox(height: NexmemMetrics.space12),
                FilledButton(
                  key: const ValueKey<String>('lock-unlock'),
                  onPressed: _busy ? null : () => unawaited(_submit()),
                  child: Text(_busy ? context.t('解锁中…') : context.t('解锁')),
                ),
                const SizedBox(height: NexmemMetrics.space8),
                TextButton(
                  onPressed: () => unawaited(_forgotPin()),
                  child: Text(context.t('忘记锁屏密码？')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
