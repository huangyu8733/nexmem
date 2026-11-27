import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/nexmem_logo.dart';
import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../settings/settings_pane.dart' show showPaneDialog;
import 'account_manager.dart';
import 'account_profile.dart';
import 'app_exit.dart';

/// 「我的 → 账号管理」：切换、添加、重命名、删除本地账号，以及临时锁设置。
class AccountManagerPage extends StatefulWidget {
  const AccountManagerPage({
    super.key,
    required this.manager,
    this.focusLock = false,
  });

  final AccountManager manager;

  /// 从「临时锁」入口进入时把锁设置放在最前面。
  final bool focusLock;

  @override
  State<AccountManagerPage> createState() => _AccountManagerPageState();
}

class _AccountManagerPageState extends State<AccountManagerPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        _showError(context.t('操作失败：{0}', ['$error']));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _addAccount() async {
    final String? name = await showPaneDialog<String>(
      context: context,
      builder: (BuildContext context) => const _NameDialog(
        keyValue: ValueKey<String>('account-add-dialog'),
        titleKey: '添加账号',
        labelKey: '账号名称',
        hintKey: '例如：工作账号',
      ),
    );
    if (name == null || name.trim().isEmpty) {
      return;
    }
    await _run(() async {
      final AccountProfile profile =
          await widget.manager.addAccount(label: name);
      await widget.manager.switchAccount(profile.id);
    });
  }

  Future<void> _rename(AccountProfile profile) async {
    final String? name = await showPaneDialog<String>(
      context: context,
      builder: (BuildContext context) => _NameDialog(
        keyValue: const ValueKey<String>('account-rename-dialog'),
        titleKey: '重命名账号',
        labelKey: '账号名称',
        hintKey: profile.label,
        initial: profile.label,
      ),
    );
    if (name == null || name.trim().isEmpty) {
      return;
    }
    await _run(() => widget.manager.renameAccount(profile.id, name));
  }

  Future<void> _switch(AccountProfile profile) async {
    await _run(() => widget.manager.switchAccount(profile.id));
  }

  Future<void> _delete(AccountProfile profile) async {
    // 弹窗返回 null=取消；false=仅移除档案；true=同时删除本机数据。
    final bool? deleteData = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext context) =>
          _DeleteAccountDialog(key: ValueKey<String>('account-delete-${profile.id}'), profile: profile),
    );
    if (deleteData == null) {
      return;
    }
    await _run(
      () => widget.manager.deleteAccount(
        profile.id,
        deleteData: deleteData,
      ),
    );
  }

  Future<void> _logout() async {
    final bool? confirmed = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('退出登录')),
        content: Text(context.t('退出后需要重新选择账号，本地数据不会删除。确定继续？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('account-logout-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('确定')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(widget.manager.logout);
    }
  }

  Future<void> _setPin({required bool change}) async {
    final String? pin = await showPaneDialog<String>(
      context: context,
      builder: (BuildContext context) => _PinDialog(
        key: ValueKey<String>(
          change ? 'account-pin-change-dialog' : 'account-pin-set-dialog',
        ),
        requireCurrent: change,
        currentHash: widget.manager.lockSettings.pinHash,
      ),
    );
    if (pin == null) {
      return;
    }
    await _run(() => widget.manager.setPin(pin));
  }

  Future<void> _clearPin() async {
    final bool? confirmed = await showPaneDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('关闭临时锁')),
        content: Text(context.t('关闭后将不再要求输入锁屏密码，确定继续？')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t('确定')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(widget.manager.clearPin);
    }
  }

  Widget _accountsSection(ColorScheme scheme) {
    final AccountProfile? active = widget.manager.active;
    final List<Widget> tiles = <Widget>[];
    for (final AccountProfile profile in widget.manager.profiles) {
      final bool isActive = profile.id == active?.id;
      tiles.add(
        ListTile(
          key: ValueKey<String>('account-item-${profile.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
          ),
          leading: Icon(
            isActive ? Icons.check_circle : Icons.account_circle_outlined,
            color: isActive ? scheme.primary : scheme.onSurface,
          ),
          title: Text(
            profile.label + (isActive ? context.t('（当前）') : ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            profile.accountId.isEmpty
                ? context.t('账号 ID 待同步')
                : _shortId(profile.accountId),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: isActive || _busy
              ? null
              : () => unawaited(_switch(profile)),
          trailing: PopupMenuButton<String>(
            key: ValueKey<String>('account-menu-${profile.id}'),
            onSelected: (String value) {
              switch (value) {
                case 'switch':
                  unawaited(_switch(profile));
                case 'rename':
                  unawaited(_rename(profile));
                case 'delete':
                  unawaited(_delete(profile));
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              if (!isActive)
                PopupMenuItem<String>(
                  value: 'switch',
                  child: Text(context.t('切换到此账号')),
                ),
              PopupMenuItem<String>(
                value: 'rename',
                child: Text(context.t('重命名')),
              ),
              if (!profile.isDefault && !isActive)
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Text(context.t('删除账号')),
                ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NexmemMetrics.space16,
            NexmemMetrics.space16,
            NexmemMetrics.space16,
            NexmemMetrics.space8,
          ),
          child: Text(
            context.t('本地账号'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        ...tiles,
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
            vertical: NexmemMetrics.space8,
          ),
          child: OutlinedButton.icon(
            key: const ValueKey<String>('account-add'),
            onPressed: _busy ? null : () => unawaited(_addAccount()),
            icon: const Icon(Icons.person_add_alt_outlined),
            label: Text(context.t('添加账号')),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NexmemMetrics.space16,
          ),
          child: TextButton.icon(
            key: const ValueKey<String>('account-logout'),
            onPressed: _busy ? null : () => unawaited(_logout()),
            icon: const Icon(Icons.logout),
            label: Text(context.t('退出登录')),
          ),
        ),
      ],
    );
  }

  Widget _lockSection(ColorScheme scheme) {
    final LockSettings lock = widget.manager.lockSettings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NexmemMetrics.space16,
            NexmemMetrics.space16,
            NexmemMetrics.space16,
            NexmemMetrics.space8,
          ),
          child: Text(
            context.t('临时锁'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        if (!lock.hasPin)
          ListTile(
            key: const ValueKey<String>('account-lock-setup'),
            leading: const Icon(Icons.lock_outline),
            title: Text(context.t('设置锁屏密码')),
            subtitle: Text(context.t('设置后可在「我的」页立即锁定应用')),
            onTap: _busy ? null : () => unawaited(_setPin(change: false)),
          )
        else ...<Widget>[
          SwitchListTile(
            key: const ValueKey<String>('account-lock-switch'),
            value: lock.enabled,
            onChanged: _busy
                ? null
                : (bool _) => unawaited(_clearPin()),
            title: Text(context.t('启用临时锁')),
            subtitle: Text(context.t('解锁需输入 4-8 位数字密码')),
          ),
          ListTile(
            key: const ValueKey<String>('account-lock-change-pin'),
            leading: const Icon(Icons.password_outlined),
            title: Text(context.t('修改锁屏密码')),
            onTap: _busy ? null : () => unawaited(_setPin(change: true)),
          ),
          ListTile(
            key: const ValueKey<String>('account-lock-now'),
            leading: const Icon(Icons.lock_outline),
            title: Text(context.t('立即锁定')),
            onTap: _busy
                ? null
                : () => unawaited(_run(widget.manager.lockNow)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NexmemMetrics.space16,
              vertical: NexmemMetrics.space8,
            ),
            child: Row(
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    context.t('自动锁定'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: NexmemMetrics.space8),
                Expanded(
                  child: DropdownButton<int>(
                    key: const ValueKey<String>('account-lock-auto'),
                    value: lock.autoLockMinutes,
                    isExpanded: true,
                    items: <int>[0, 1, 5, 15, 30]
                        .map(
                          (int minutes) => DropdownMenuItem<int>(
                            value: minutes,
                            child: Text(
                              minutes == 0
                                  ? context.t('关闭')
                                  : context.t('{0} 分钟', ['$minutes']),
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _busy
                        ? null
                        : (int? value) {
                            if (value != null) {
                              unawaited(
                                _run(
                                  () => widget.manager
                                      .setAutoLockMinutes(value),
                                ),
                              );
                            }
                          },
                  ),
                ),
              ],
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NexmemMetrics.space16,
            NexmemMetrics.space8,
            NexmemMetrics.space16,
            NexmemMetrics.space16,
          ),
          child: Text(
            context.t('锁定时会停止内核网络，解锁后自动恢复当前账号。'),
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Widget accounts = _accountsSection(scheme);
    final Widget lock = _lockSection(scheme);
    return ListView(
      children: <Widget>[
        const Divider(height: 1),
        if (widget.focusLock) ...<Widget>[lock, const Divider(height: 1), accounts]
        else ...<Widget>[accounts, const Divider(height: 1), lock],
      ],
    );
  }
}

String _shortId(String id) => id.length <= 16 ? id : '${id.substring(0, 12)}…';

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.keyValue,
    required this.titleKey,
    required this.labelKey,
    required this.hintKey,
    this.initial = '',
  });

  final ValueKey<String> keyValue;
  final String titleKey;
  final String labelKey;
  final String hintKey;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: widget.keyValue,
      title: Text(context.t(widget.titleKey)),
      content: responsiveDialogContent(
        maxWidth: 320,
        child: TextField(
          key: const ValueKey<String>('account-name-input'),
          controller: _controller,
          autofocus: true,
          maxLength: 24,
          decoration: InputDecoration(
            labelText: context.t(widget.labelKey),
            hintText: context.t(widget.hintKey),
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop<String>(null),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('account-name-confirm'),
          onPressed: () => Navigator.of(context).pop<String>(
            _controller.text.trim(),
          ),
          child: Text(context.t('确定')),
        ),
      ],
    );
  }
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({
    super.key,
    required this.requireCurrent,
    required this.currentHash,
  });

  final bool requireCurrent;
  final String currentHash;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final String pin = _pin.text.trim();
    if (pin.length < 4 || pin.length > 8) {
      setState(() => _error = context.t('密码需为 4-8 位数字'));
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = context.t('两次输入的密码不一致'));
      return;
    }
    if (widget.requireCurrent &&
        !verifyPin(_current.text.trim(), widget.currentHash)) {
      setState(() => _error = context.t('当前密码不正确'));
      return;
    }
    Navigator.of(context).pop<String>(pin);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.requireCurrent ? context.t('修改锁屏密码') : context.t('设置锁屏密码'),
      ),
      content: responsiveDialogContent(
        maxWidth: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.requireCurrent)
              TextField(
                key: const ValueKey<String>('account-pin-current'),
                controller: _current,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.t('当前密码'),
                  border: const OutlineInputBorder(),
                ),
              ),
            if (widget.requireCurrent) const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('account-pin-new'),
              controller: _pin,
              autofocus: !widget.requireCurrent,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: context.t('新密码（4-8 位数字）'),
                border: const OutlineInputBorder(),
              ),
            ),
            TextField(
              key: const ValueKey<String>('account-pin-confirm'),
              controller: _confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: context.t('确认新密码'),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop<String>(null),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('account-pin-submit'),
          onPressed: _submit,
          child: Text(context.t('确定')),
        ),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({super.key, required this.profile});

  final AccountProfile profile;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  bool _deleteData = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('删除账号')),
      content: responsiveDialogContent(
        maxWidth: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              context.t('将从列表移除「{0}」', [widget.profile.label]),
            ),
            if (widget.profile.dataDir.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  context.t('数据目录：{0}', [widget.profile.dataDir]),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              context.t('⚠️ 此操作非常危险，可能导致不可逆的数据丢失！'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.bold,
              ),
            ),
            CheckboxListTile(
              key: const ValueKey<String>('account-delete-data'),
              value: _deleteData,
              contentPadding: EdgeInsets.zero,
              onChanged: (bool? value) =>
                  setState(() => _deleteData = value == true),
              title: Text(context.t('同时删除本机数据（不可恢复）')),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop<bool>(null),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('account-delete-confirm'),
          onPressed: () => Navigator.of(context).pop<bool>(_deleteData),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(context.t('删除')),
        ),
      ],
    );
  }
}

/// 退出登录后展示的账号选择页。
class AccountGate extends StatefulWidget {
  const AccountGate({
    super.key,
    required this.manager,
    this.message = '',
  });

  final AccountManager manager;
  final String message;

  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  String? _error;

  Future<void> _enter(AccountProfile profile) async {
    setState(() => _error = null);
    try {
      await widget.manager.switchAccount(profile.id);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = context.t('进入账号失败：{0}', ['$error']));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.manager,
      builder: (BuildContext context, Widget? _) {
        return Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(NexmemMetrics.space24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Center(child: NexmemMark(size: 96)),
                      const SizedBox(height: NexmemMetrics.space16),
                      Text(
                        context.t('选择账号'),
                        key: const ValueKey<String>('account-gate-title'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (widget.message.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: NexmemMetrics.space8,
                          ),
                          child: Text(
                            widget.message,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: NexmemMetrics.space8,
                          ),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                      const SizedBox(height: NexmemMetrics.space24),
                      for (final AccountProfile profile
                          in widget.manager.profiles)
                        Card(
                          key: ValueKey<String>('gate-${profile.id}'),
                          child: ListTile(
                            leading: Icon(
                              Icons.account_circle_outlined,
                              color: scheme.primary,
                            ),
                            title: Text(
                              profile.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              profile.accountId.isEmpty
                                  ? context.t('账号 ID 待同步')
                                  : _shortId(profile.accountId),
                            ),
                            trailing: const Icon(Icons.arrow_forward),
                            onTap: () => unawaited(_enter(profile)),
                          ),
                        ),
                      const SizedBox(height: NexmemMetrics.space8),
                      OutlinedButton.icon(
                        key: const ValueKey<String>('gate-add'),
                        onPressed: () => unawaited(_addAccount()),
                        icon: const Icon(Icons.person_add_alt_outlined),
                        label: Text(context.t('添加账号')),
                      ),
                      const SizedBox(height: NexmemMetrics.space8),
                      TextButton.icon(
                        onPressed: () => unawaited(exitProcess()),
                        icon: const Icon(Icons.exit_to_app),
                        label: Text(context.t('退出应用')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addAccount() async {
    final String? name = await showPaneDialog<String>(
      context: context,
      builder: (BuildContext context) => const _NameDialog(
        keyValue: ValueKey<String>('gate-add-dialog'),
        titleKey: '添加账号',
        labelKey: '账号名称',
        hintKey: '例如：工作账号',
      ),
    );
    if (name == null || name.trim().isEmpty) {
      return;
    }
    try {
      final AccountProfile profile =
          await widget.manager.addAccount(label: name);
      await _enter(profile);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = context.t('添加账号失败：{0}', ['$error']));
      }
    }
  }
}

/// Web 端退出后的提示页：浏览器不允许脚本可靠关闭标签页。
class ExitedScreen extends StatelessWidget {
  const ExitedScreen({super.key, required this.onReenter});

  final VoidCallback onReenter;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.logout, size: 56),
              const SizedBox(height: 16),
              Text(
                context.t('已退出奈讯联'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                context.t('可关闭此标签页，或点击下方重新进入'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const ValueKey<String>('exited-reenter'),
                onPressed: onReenter,
                child: Text(context.t('重新进入')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
