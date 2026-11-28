// 群「拉人进群」：好友多选 + 指定账号 / 批量导入。
//
// 批量文本一行一个账号，可选 `账号|备注`；备注写入本群称呼，复用
// group.invite + group.setMemberProfile 契约，不新增内核方法、不改动后端。

import 'package:material_ui/material_ui.dart';

import '../../app/theme.dart';
import '../../l10n/l10n.dart';
import '../contacts/contact.dart';
import '../contacts/contact_service.dart';
import '../../app/app_dialog.dart';

/// 单个待邀请条目；[nickname] 非空时邀请成功后写入本群称呼。
class GroupInviteEntry {
  const GroupInviteEntry({required this.account, this.nickname = ''});

  final String account;
  final String nickname;
}

/// 批量账号文本解析结果：有效条目、无效行与重复账号数。
class GroupInviteParseResult {
  const GroupInviteParseResult({
    required this.entries,
    required this.invalidLines,
    required this.duplicates,
  });

  final List<GroupInviteEntry> entries;
  final List<String> invalidLines;
  final int duplicates;
}

/// 本群称呼上限，与内核 `MaxNicknameRunes` 及成员资料弹窗一致。
const int groupInviteMaxNicknameRunes = 24;

bool _looksLikeAccount(String text) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizeAccountHex(text));

/// 解析批量账号文本。
///
/// 每行格式 `账号` 或 `账号|备注`；空行与 `#` 开头的注释行忽略。
/// 账号接受 64 位十六进制或 32 字节 base64url；非法行计入 [invalidLines]，
/// 同一账号重复出现时只保留首条并计入 [duplicates]。备注超长自动截断。
GroupInviteParseResult parseGroupInviteBatch(
  String text, {
  int maxNicknameRunes = groupInviteMaxNicknameRunes,
}) {
  final List<GroupInviteEntry> entries = <GroupInviteEntry>[];
  final List<String> invalidLines = <String>[];
  final Set<String> seen = <String>{};
  int duplicates = 0;

  for (final String raw in text.split(RegExp(r'\r?\n'))) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final int bar = line.indexOf('|');
    final String account =
        (bar >= 0 ? line.substring(0, bar) : line).trim();
    String nickname = (bar >= 0 ? line.substring(bar + 1) : '').trim();
    if (nickname.runes.length > maxNicknameRunes) {
      nickname = String.fromCharCodes(nickname.runes.take(maxNicknameRunes));
    }
    if (!_looksLikeAccount(account)) {
      invalidLines.add(line);
      continue;
    }
    final String key = normalizeAccountHex(account);
    if (seen.contains(key)) {
      duplicates++;
      continue;
    }
    seen.add(key);
    entries.add(GroupInviteEntry(account: account, nickname: nickname));
  }

  return GroupInviteParseResult(
    entries: entries,
    invalidLines: invalidLines,
    duplicates: duplicates,
  );
}

/// 打开拉人弹窗，返回待邀请条目；取消返回 null。
Future<List<GroupInviteEntry>?> showGroupInviteDialog(
  BuildContext context, {
  required List<Contact> friends,
  required Set<String> existingHex,
}) {
  return showAppDialog<List<GroupInviteEntry>>(
    context: context,
    builder: (BuildContext context) => _GroupInviteDialog(
      friends: friends,
      existingHex: existingHex,
    ),
  );
}

class _GroupInviteDialog extends StatefulWidget {
  const _GroupInviteDialog({
    required this.friends,
    required this.existingHex,
  });

  final List<Contact> friends;
  final Set<String> existingHex;

  @override
  State<_GroupInviteDialog> createState() => _GroupInviteDialogState();
}

class _GroupInviteDialogState extends State<_GroupInviteDialog> {
  int _tab = 0;
  final Set<String> _pickedFriends = <String>{};
  late final TextEditingController _batch = TextEditingController();
  GroupInviteParseResult _parsed = const GroupInviteParseResult(
    entries: <GroupInviteEntry>[],
    invalidLines: <String>[],
    duplicates: 0,
  );

  @override
  void initState() {
    super.initState();
    _batch.addListener(_onBatchChanged);
  }

  @override
  void dispose() {
    _batch.removeListener(_onBatchChanged);
    _batch.dispose();
    super.dispose();
  }

  void _onBatchChanged() {
    if (!mounted) {
      return;
    }
    setState(() => _parsed = parseGroupInviteBatch(_batch.text));
  }

  /// 汇总好友与批量输入，按规范化账号去重并排除已在群成员。
  List<GroupInviteEntry> _collect() {
    final List<GroupInviteEntry> result = <GroupInviteEntry>[];
    final Set<String> seen = <String>{...widget.existingHex};

    void add(GroupInviteEntry entry) {
      final String key = normalizeAccountHex(entry.account);
      if (seen.contains(key)) {
        return;
      }
      seen.add(key);
      result.add(entry);
    }

    for (final Contact contact in widget.friends) {
      if (!_pickedFriends.contains(contact.id)) {
        continue;
      }
      final String account =
          contact.peer.isNotEmpty ? contact.peer : contact.id;
      final String raw = contact.name.trim();
      final String nickname = raw.runes.length > groupInviteMaxNicknameRunes
          ? String.fromCharCodes(raw.runes.take(groupInviteMaxNicknameRunes))
          : raw;
      add(GroupInviteEntry(account: account, nickname: nickname));
    }
    for (final GroupInviteEntry entry in _parsed.entries) {
      add(entry);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final int total = _collect().length;
    return AlertDialog(
      key: const ValueKey<String>('group-invite-dialog'),
      title: Text(context.t('拉人进群')),
      content: responsiveDialogContent(
        maxWidth: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextButton(
                    key: const ValueKey<String>('group-invite-tab-friends'),
                    onPressed: () => setState(() => _tab = 0),
                    child: Text(context.t('好友')),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    key: const ValueKey<String>('group-invite-tab-batch'),
                    onPressed: () => setState(() => _tab = 1),
                    child: Text(context.t('指定账号 / 批量导入')),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 260,
              child: _tab == 0 ? _friendPane() : _batchPane(),
            ),
            const SizedBox(height: 8),
            Text(
              context.t('待邀请 {0} 人', [total]),
              key: const ValueKey<String>('group-invite-total'),
              style: const TextStyle(fontSize: 12),
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
          key: const ValueKey<String>('group-invite-confirm'),
          onPressed: total == 0 ? null : () => Navigator.pop(context, _collect()),
          child: Text(context.t('拉人进群')),
        ),
      ],
    );
  }

  Widget _friendPane() {
    if (widget.friends.isEmpty) {
      return Center(
        child: Text(context.t('通讯录里没有可邀请的联系人')),
      );
    }
    return ListView.builder(
      itemCount: widget.friends.length,
      itemBuilder: (BuildContext context, int index) {
        final Contact contact = widget.friends[index];
        final String account =
            contact.peer.isNotEmpty ? contact.peer : contact.id;
        return CheckboxListTile(
          key: ValueKey<String>('group-invite-contact-${contact.id}'),
          value: _pickedFriends.contains(contact.id),
          onChanged: (bool? value) => setState(() {
            if (value == true) {
              _pickedFriends.add(contact.id);
            } else {
              _pickedFriends.remove(contact.id);
            }
          }),
          title: Text(
            contact.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            normalizeAccountHex(account),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Widget _batchPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: TextField(
            key: const ValueKey<String>('group-invite-batch-field'),
            controller: _batch,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: context.t('每行一个账号，可用「账号|备注」指定本群称呼'),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          context.t(
            '有效 {0} 个，无效 {1} 行，重复 {2} 个',
            [
              _parsed.entries.length,
              _parsed.invalidLines.length,
              _parsed.duplicates,
            ],
          ),
          key: const ValueKey<String>('group-invite-batch-summary'),
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}
