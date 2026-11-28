import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';

import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../contacts/contact.dart';
import '../contacts/contact_service.dart';
import '../../app/app_dialog.dart';

/// `+` 菜单动作（ui-spec.md §2：发起单聊 / 创建群聊 / 添加好友）。
enum StartChatAction { direct, group, addFriend }

/// 建群请求：群名 + 选中的联系人。
class NewGroupRequest {
  const NewGroupRequest({required this.title, required this.members});

  final String title;
  final List<Contact> members;
}

/// 底部动作面板：发起单聊 / 创建群聊 / 添加好友。
Future<StartChatAction?> showStartChatSheet(BuildContext context) {
  return showModalBottomSheet<StartChatAction>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const ValueKey<String>('start-chat-direct'),
              leading: const Icon(Icons.chat_bubble_outline),
              title: Text(context.t('发起单聊')),
              onTap: () =>
                  Navigator.of(sheetContext).pop(StartChatAction.direct),
            ),
            ListTile(
              key: const ValueKey<String>('start-chat-group'),
              leading: const Icon(Icons.group_add_outlined),
              title: Text(context.t('创建群聊')),
              onTap: () =>
                  Navigator.of(sheetContext).pop(StartChatAction.group),
            ),
            ListTile(
              key: const ValueKey<String>('start-chat-add-friend'),
              leading: const Icon(Icons.person_add_alt_1),
              title: Text(context.t('添加好友')),
              onTap: () =>
                  Navigator.of(sheetContext).pop(StartChatAction.addFriend),
            ),
          ],
        ),
      );
    },
  );
}

/// 单选联系人对话框；取消返回 null。
Future<Contact?> showContactPicker(
  BuildContext context,
  ContactService service,
) {
  return showAppDialog<Contact>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _ContactPickerDialog(service: service),
  );
}

/// 建群对话框；取消或校验失败返回 null。
Future<NewGroupRequest?> showCreateGroupDialog(
  BuildContext context,
  ContactService service,
) {
  return showAppDialog<NewGroupRequest>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _CreateGroupDialog(service: service),
  );
}

/// 轻量建群对话框：只需填写群名即可创建空群，不依赖通讯录。
///
/// 群聊页右上角入口使用；建好后可在群资料页邀请成员或分享群信息拉人。
/// 取消或空名返回 null。
Future<String?> showCreateGroupByNameDialog(BuildContext context) {
  return showAppDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => const _CreateGroupByNameDialog(),
  );
}

class _CreateGroupByNameDialog extends StatefulWidget {
  const _CreateGroupByNameDialog();

  @override
  State<_CreateGroupByNameDialog> createState() =>
      _CreateGroupByNameDialogState();
}

class _CreateGroupByNameDialogState extends State<_CreateGroupByNameDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _validation;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String title = _controller.text.trim();
    if (title.isEmpty) {
      setState(() => _validation = context.t('请输入群名称'));
      return;
    }
    Navigator.of(context).pop(title);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('create-group-by-name-dialog'),
      title: Text(context.t('创建群聊')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('create-group-by-name-title'),
            controller: _controller,
            autofocus: true,
            maxLength: 30,
            decoration: InputDecoration(
              labelText: context.t('群名称'),
              hintText: context.t('请输入群名称'),
              isDense: true,
            ),
            onChanged: (_) {
              if (_validation != null) {
                setState(() => _validation = null);
              }
            },
            onSubmitted: (_) => _submit(),
          ),
          if (_validation != null)
            Padding(
              padding: const EdgeInsets.only(top: NexmemMetrics.space4),
              child: Text(
                _validation!,
                key: const ValueKey<String>('create-group-by-name-error'),
                style: const TextStyle(
                  fontSize: 12,
                  color: NexmemColors.danger,
                ),
              ),
            ),
          const SizedBox(height: NexmemMetrics.space8),
          Text(
            context.t('创建后可邀请成员或分享群信息拉人入群'),
            key: const ValueKey<String>('create-group-by-name-hint'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('create-group-by-name-confirm'),
          onPressed: _submit,
          child: Text(context.t('创建')),
        ),
      ],
    );
  }
}

class _ContactPickerDialog extends StatefulWidget {
  const _ContactPickerDialog({required this.service});

  final ContactService service;

  @override
  State<_ContactPickerDialog> createState() => _ContactPickerDialogState();
}

class _ContactPickerDialogState extends State<_ContactPickerDialog> {
  List<Contact> _contacts = const <Contact>[];
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Contact> contacts = await widget.service.list();
      if (!mounted) {
        return;
      }
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.isEmpty ? error.code : error.message;
      });
    }
  }

  List<Contact> get _visible {
    final String query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return _contacts;
    }
    return <Contact>[
      for (final Contact contact in _contacts)
        if (contact.name.toLowerCase().contains(query) ||
            contact.note.toLowerCase().contains(query))
          contact,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('contact-picker-dialog'),
      title: Text(context.t('发起单聊')),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: 380,
        ),
        child: SizedBox(
          width: double.maxFinite,
          // 矮屏（横屏/分屏）下收缩，避免底部按钮被裁切。
          height: math.min(380, MediaQuery.sizeOf(context).height - 160)
              .clamp(120, 380)
              .toDouble(),
          child: _buildContent(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: NexmemMetrics.space12),
            TextButton(
              key: const ValueKey<String>('contact-picker-retry'),
              onPressed: _load,
              child: Text(context.t('重试')),
            ),
          ],
        ),
      );
    }
    final List<Contact> visible = _visible;
    return Column(
      children: <Widget>[
        TextField(
          key: const ValueKey<String>('contact-picker-search'),
          decoration: InputDecoration(
            hintText: context.t('搜索联系人'),
            prefixIcon: const Icon(Icons.search, size: 18),
            isDense: true,
          ),
          onChanged: (String value) => setState(() => _query = value),
        ),
        const SizedBox(height: NexmemMetrics.space8),
        Expanded(
          child: visible.isEmpty
              ? Center(child: Text(context.t('暂无可选联系人，请先添加好友')))
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Contact contact = visible[index];
                    return ListTile(
                      key: ValueKey<String>(
                        'contact-picker-item-${contact.id}',
                      ),
                      dense: true,
                      leading: const Icon(Icons.person_outline, size: 20),
                      title: Text(
                        contact.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: contact.note.isEmpty
                          ? null
                          : Text(
                              contact.note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: () => Navigator.of(context).pop(contact),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog({required this.service});

  final ContactService service;

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final TextEditingController _titleController = TextEditingController();
  final Set<String> _selected = <String>{};
  List<Contact> _contacts = const <Contact>[];
  bool _loading = true;
  String? _error;
  String? _validation;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Contact> contacts = await widget.service.list();
      if (!mounted) {
        return;
      }
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    } on NexmemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message.isEmpty ? error.code : error.message;
      });
    }
  }

  List<Contact> get _visible {
    final String query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return _contacts;
    }
    return <Contact>[
      for (final Contact contact in _contacts)
        if (contact.name.toLowerCase().contains(query) ||
            contact.note.toLowerCase().contains(query))
          contact,
    ];
  }

  void _submit() {
    final String title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _validation = context.t('请输入群名称'));
      return;
    }
    // 允许先建空群再邀请成员（与 QQ 习惯一致）；群主始终自动入群。
    final List<Contact> members = <Contact>[
      for (final Contact contact in _contacts)
        if (_selected.contains(contact.id)) contact,
    ];
    Navigator.of(context).pop(NewGroupRequest(title: title, members: members));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('create-group-dialog'),
      title: Text(context.t('创建群聊')),
      content: responsiveDialogContent(
        height: 420,
        child: _buildContent(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('create-group-confirm'),
          onPressed: _loading ? null : _submit,
          child: Text(context.t('创建')),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: NexmemMetrics.space12),
            TextButton(
              key: const ValueKey<String>('create-group-retry'),
              onPressed: _load,
              child: Text(context.t('重试')),
            ),
          ],
        ),
      );
    }
    final List<Contact> visible = _visible;
    return Column(
      children: <Widget>[
        TextField(
          key: const ValueKey<String>('create-group-title'),
          controller: _titleController,
          decoration: InputDecoration(
            labelText: context.t('群名称'),
            isDense: true,
          ),
          maxLength: 30,
          onChanged: (_) {
            if (_validation != null) {
              setState(() => _validation = null);
            }
          },
        ),
        TextField(
          key: const ValueKey<String>('create-group-search'),
          decoration: InputDecoration(
            hintText: context.t('搜索联系人'),
            prefixIcon: const Icon(Icons.search, size: 18),
            isDense: true,
          ),
          onChanged: (String value) => setState(() => _query = value),
        ),
        if (_validation != null)
          Padding(
            padding: const EdgeInsets.only(top: NexmemMetrics.space4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                _validation!,
                key: const ValueKey<String>('create-group-error'),
                style: const TextStyle(
                  fontSize: 12,
                  color: NexmemColors.danger,
                ),
              ),
            ),
          ),
        const SizedBox(height: NexmemMetrics.space8),
        Expanded(
          child: visible.isEmpty
              ? Center(child: Text(context.t('暂无可选联系人，请先添加好友')))
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Contact contact = visible[index];
                    return CheckboxListTile(
                      key: ValueKey<String>(
                        'create-group-member-${contact.id}',
                      ),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _selected.contains(contact.id),
                      title: Text(
                        contact.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onChanged: (bool? checked) {
                        setState(() {
                          if (checked == true) {
                            _selected.add(contact.id);
                          } else {
                            _selected.remove(contact.id);
                          }
                          if (_selected.isNotEmpty) {
                            _validation = null;
                          }
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
