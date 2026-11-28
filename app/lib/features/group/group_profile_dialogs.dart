// 群成员本群称呼与等级系统管理弹窗。
//
// 数据读写只走 GroupService；本文件不持有任何内核状态，便于在 Widget 测试中
// 用假服务验证权限、长度限制与图标自动裁剪后的 base64 提交。

import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../../transport/transport.dart';
import '../settings/image_crop_page.dart';
import '../settings/profile_image.dart';
import 'group_service.dart';
import '../../app/app_dialog.dart';

const int _maxNicknameRunes = 24;
const int _maxLevelNameRunes = 16;
const int _maxLevelCount = 12;

/// 统一错误文案：业务错误 message 为空时回退到固定错误码，
/// 避免弹窗保留但看不到任何提示，看起来像“保存没反应”。
String _describeSaveError(Object error) {
  if (error is NexmemException) {
    final String message = error.message.trim();
    return message.isEmpty ? error.code : message;
  }
  return error.toString();
}

/// 管理员维护等级开关、名称与 64x64 PNG 图标。
Future<GroupLevels?> showGroupLevelDialog(
  BuildContext context, {
  required GroupService service,
  required String groupId,
  required GroupLevels initial,
}) {
  return showAppDialog<GroupLevels>(
    context: context,
    builder: (BuildContext context) => _GroupLevelDialog(
      service: service,
      groupId: groupId,
      initial: initial,
    ),
  );
}

class _GroupLevelDialog extends StatefulWidget {
  const _GroupLevelDialog({
    required this.service,
    required this.groupId,
    required this.initial,
  });

  final GroupService service;
  final String groupId;
  final GroupLevels initial;

  @override
  State<_GroupLevelDialog> createState() => _GroupLevelDialogState();
}

class _GroupLevelDialogState extends State<_GroupLevelDialog> {
  late bool _enabled = widget.initial.enabled;
  late final List<GroupLevel> _levels =
      List<GroupLevel>.from(widget.initial.items);
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final GroupLevels saved = await widget.service.setLevelConfig(
        widget.groupId,
        enabled: _enabled,
        levels: _levels,
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop<GroupLevels>(saved);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _describeSaveError(error);
        });
      }
    }
  }

  Future<void> _pickIcon(int index) async {
    final PickedProfileImage? picked = await pickProfileImageFile();
    if (picked == null || !mounted) {
      return;
    }
    try {
      final Uint8List bytes = prepareSquarePng(picked.bytes);
      setState(() {
        final GroupLevel current = _levels[index];
        _levels[index] = GroupLevel(
          id: current.id,
          name: current.name,
          iconB64: base64.encode(bytes),
        );
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = context.t('图标仅支持可解码的图片，已自动裁剪为 64x64 PNG：{0}', ['$error']);
        });
      }
    }
  }

  Future<void> _editName(int index) async {
    final GroupLevel current = _levels[index];
    final TextEditingController controller =
        TextEditingController(text: current.name);
    final String? saved = await showAppDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(context.t('等级名称')),
        content: TextField(
          key: const ValueKey<String>('group-level-name-field'),
          controller: controller,
          maxLength: _maxLevelNameRunes,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.t('等级名称'),
            hintText: context.t('例如：钻石会员'),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.t('取消')),
          ),
          FilledButton(
            key: const ValueKey<String>('group-level-name-save'),
            onPressed: () {
              final String text = controller.text.trim();
              if (text.isEmpty) {
                return;
              }
              Navigator.pop(context, text);
            },
            child: Text(context.t('保存')),
          ),
        ],
      ),
    );
    if (saved == null || !mounted) {
      return;
    }
    setState(() {
      _levels[index] = GroupLevel(
        id: current.id,
        name: saved,
        iconB64: current.iconB64,
      );
    });
  }

  void _addLevel() {
    if (_levels.length >= _maxLevelCount) {
      return;
    }
    setState(() {
      _levels.add(
        GroupLevel(
          id: 'lv-${DateTime.now().microsecondsSinceEpoch}',
          name: context.t('新等级'),
        ),
      );
    });
  }

  Widget _icon(GroupLevel level) {
    final Uint8List? bytes = level.iconBytes;
    if (bytes == null) {
      return const Icon(Icons.shield_outlined, size: 24);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.memory(
        bytes,
        width: 24,
        height: 24,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
            const Icon(Icons.shield_outlined, size: 24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t('群等级设置')),
      content: responsiveDialogContent(
        maxWidth: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SwitchListTile(
              key: const ValueKey<String>('group-level-enabled'),
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: _busy
                  ? null
                  : (bool value) => setState(() => _enabled = value),
              title: Text(context.t('启用等级系统')),
              subtitle: Text(
                context.t('管理员可设置等级名称与 64x64 图标'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _levels.length,
                itemBuilder: (BuildContext context, int index) {
                  final GroupLevel level = _levels[index];
                  return ListTile(
                    key: ValueKey<String>('group-level-${level.id}'),
                    leading: _icon(level),
                    title: Text(
                      level.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            key: ValueKey<String>('group-level-icon-${level.id}'),
                            tooltip: context.t('选择图标'),
                            icon: const Icon(Icons.image_outlined, size: 18),
                            onPressed: _busy ? null : () => _pickIcon(index),
                          ),
                          IconButton(
                            key: ValueKey<String>('group-level-name-edit-${level.id}'),
                            tooltip: context.t('编辑'),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: _busy ? null : () => _editName(index),
                          ),
                          IconButton(
                            key: ValueKey<String>('group-level-remove-${level.id}'),
                            tooltip: context.t('删除'),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: _busy
                                ? null
                                : () => setState(() => _levels.removeAt(index)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey<String>('group-level-add'),
                onPressed: _busy || _levels.length >= _maxLevelCount
                    ? null
                    : _addLevel,
                icon: const Icon(Icons.add),
                label: Text(context.t('添加等级（最多 {0} 个）', [_maxLevelCount])),
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
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('group-level-save'),
          onPressed: _busy ? null : _save,
          child: Text(context.t('保存')),
        ),
      ],
    );
  }
}

/// 设置成员本群称呼；管理员额外可设置等级。
Future<GroupMemberProfile?> showMemberProfileDialog(
  BuildContext context, {
  required GroupService service,
  required String groupId,
  required GroupMember member,
  required bool isSelf,
  required bool isAdmin,
  required GroupLevels levels,
}) {
  return showAppDialog<GroupMemberProfile>(
    context: context,
    builder: (BuildContext context) => _MemberProfileDialog(
      service: service,
      groupId: groupId,
      member: member,
      isSelf: isSelf,
      isAdmin: isAdmin,
      levels: levels,
    ),
  );
}

class _MemberProfileDialog extends StatefulWidget {
  const _MemberProfileDialog({
    required this.service,
    required this.groupId,
    required this.member,
    required this.isSelf,
    required this.isAdmin,
    required this.levels,
  });

  final GroupService service;
  final String groupId;
  final GroupMember member;
  final bool isSelf;
  final bool isAdmin;
  final GroupLevels levels;

  @override
  State<_MemberProfileDialog> createState() => _MemberProfileDialogState();
}

class _MemberProfileDialogState extends State<_MemberProfileDialog> {
  late final TextEditingController _nickname =
      TextEditingController(text: widget.member.nickname);
  late String _levelId = widget.member.levelId;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) {
      return;
    }
    final String nickname = _nickname.text.trim();
    if (nickname.runes.length > _maxNicknameRunes) {
      setState(() => _error = context.t('本群称呼最多 {0} 字', [_maxNicknameRunes]));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final GroupMemberProfile saved = await widget.service.setMemberProfile(
        widget.groupId,
        widget.member.account,
        nickname: nickname,
        levelId: widget.isAdmin && widget.levels.enabled ? _levelId : null,
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true)
            .pop<GroupMemberProfile>(saved);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _describeSaveError(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canSetLevel = widget.isAdmin && widget.levels.enabled;
    return AlertDialog(
      title: Text(context.t('设置成员资料')),
      content: responsiveDialogContent(
        maxWidth: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('group-member-nickname-field'),
              controller: _nickname,
              maxLength: _maxNicknameRunes,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.t('本群称呼'),
                hintText: context.t('留空则显示账号短串'),
              ),
            ),
            if (canSetLevel)
              DropdownButtonFormField<String>(
                key: const ValueKey<String>('group-member-level-field'),
                initialValue: _levelId,
                decoration: InputDecoration(labelText: context.t('成员等级')),
                items: <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                    value: '',
                    child: Text(context.t('未设置等级')),
                  ),
                  for (final GroupLevel level in widget.levels.items)
                    DropdownMenuItem<String>(
                      value: level.id,
                      child: Row(
                        children: <Widget>[
                          if (level.iconBytes != null)
                            Image.memory(
                              level.iconBytes!,
                              width: 18,
                              height: 18,
                            ),
                          const SizedBox(width: 6),
                          Text(level.name),
                        ],
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (String? value) => setState(() => _levelId = value ?? ''),
              ),
            if (!widget.isSelf && !widget.isAdmin)
              Text(
                context.t('只有本人或管理员可以修改称呼'),
                style: const TextStyle(fontSize: 12),
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
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(context.t('取消')),
        ),
        FilledButton(
          key: const ValueKey<String>('group-member-profile-save'),
          onPressed: _busy ||
                  (!widget.isSelf && !widget.isAdmin)
              ? null
              : _save,
          child: Text(context.t('保存')),
        ),
      ],
    );
  }
}
