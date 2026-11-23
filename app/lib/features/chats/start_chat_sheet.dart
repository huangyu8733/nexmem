import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../transport/transport.dart';
import '../contacts/contact.dart';
import '../contacts/contact_service.dart';

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
              title: const Text('发起单聊'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(StartChatAction.direct),
            ),
            ListTile(
              key: const ValueKey<String>('start-chat-group'),
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('创建群聊'),
              onTap: () =>
                  Navigator.of(sheetContext).pop(StartChatAction.group),
            ),
            ListTile(
              key: const ValueKey<String>('start-chat-add-friend'),
              leading: const Icon(Icons.person_add_alt_1),
              title: const Text('添加好友'),
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
  return showDialog<Contact>(
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
  return showDialog<NewGroupRequest>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _CreateGroupDialog(service: service),
  );
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
      title: const Text('发起单聊'),
      content: SizedBox(width: 360, height: 380, child: _buildContent()),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
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
              child: const Text('重试'),
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
          decoration: const InputDecoration(
            hintText: '搜索联系人',
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true,
          ),
          onChanged: (String value) => setState(() => _query = value),
        ),
        const SizedBox(height: NexmemMetrics.space8),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('暂无可选联系人，请先添加好友'))
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
      setState(() => _validation = '请输入群名称');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _validation = '请至少选择一名成员');
      return;
    }
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
      title: const Text('创建群聊'),
      content: SizedBox(width: 380, height: 420, child: _buildContent()),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('create-group-confirm'),
          onPressed: _loading ? null : _submit,
          child: const Text('创建'),
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
              child: const Text('重试'),
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
          decoration: const InputDecoration(labelText: '群名称', isDense: true),
          maxLength: 30,
          onChanged: (_) {
            if (_validation != null) {
              setState(() => _validation = null);
            }
          },
        ),
        TextField(
          key: const ValueKey<String>('create-group-search'),
          decoration: const InputDecoration(
            hintText: '搜索联系人',
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true,
          ),
          onChanged: (String value) => setState(() => _query = value),
        ),
        if (_validation != null)
          Padding(
            padding: const EdgeInsets.only(top: NexmemMetrics.space4),
            child: Align(
              alignment: Alignment.centerLeft,
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
              ? const Center(child: Text('暂无可选联系人，请先添加好友'))
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
