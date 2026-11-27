/// 联系人模型与 A–Z 分组（ui-spec.md §4）。
library;

class Contact {
  const Contact({
    required this.id,
    required this.name,
    this.note = '',
    this.groupName = '',
    this.blocked = false,
    this.peer = '',
  });

  /// 账号公钥（十六进制），与内核 `contact.list` 的 `account_pub` 一致。
  final String id;
  final String name;

  /// 本地备注名，仅本机可见（P2-06）。
  final String note;

  /// 本地好友分组名，仅本机可见（P6-30）。
  final String groupName;

  /// 是否已拉黑；拉黑后双方均不可发送消息。
  final bool blocked;

  /// 账号公钥的 base64url 形式，可直接作为 `dm.sendText` 的 `peer`。
  final String peer;

  Contact copyWith({
    String? name,
    String? note,
    String? groupName,
    bool? blocked,
    String? peer,
  }) {
    return Contact(
      id: id,
      name: name ?? this.name,
      note: note ?? this.note,
      groupName: groupName ?? this.groupName,
      blocked: blocked ?? this.blocked,
      peer: peer ?? this.peer,
    );
  }
}

/// 未设置分组的好友在界面上归入的默认分组（可按当前语言替换展示名）。
const String defaultFriendGroupLabel = '我的好友';

/// 按本地好友分组（[Contact.groupName]）归类。
///
/// 未分组好友归入 [defaultGroup] 并排在最前；其余分组按名称排序。
/// 组内按显示名、账号排序，保证顺序稳定。
List<(String, List<Contact>)> groupFriends(
  Iterable<Contact> contacts, {
  String defaultGroup = defaultFriendGroupLabel,
}) {
  final Map<String, List<Contact>> buckets = <String, List<Contact>>{};
  for (final Contact contact in contacts) {
    final String name = contact.groupName.trim();
    final String group = name.isEmpty ? defaultGroup : name;
    buckets.putIfAbsent(group, () => <Contact>[]).add(contact);
  }
  final List<String> names = buckets.keys.toList()
    ..sort((String a, String b) {
      if (a == defaultGroup) {
        return -1;
      }
      if (b == defaultGroup) {
        return 1;
      }
      return a.compareTo(b);
    });
  return <(String, List<Contact>)>[
    for (final String name in names)
      (
        name,
        buckets[name]!
          ..sort((Contact a, Contact b) {
            final int byName = a.name.compareTo(b.name);
            return byName != 0 ? byName : a.id.compareTo(b.id);
          }),
      ),
  ];
}

/// 非拉丁字母或数字统一归入 `#`。
String contactGroupLetter(String name) {
  if (name.isEmpty) {
    return '#';
  }
  final String first = name.substring(0, 1).toUpperCase();
  final int code = first.codeUnitAt(0);
  if (code >= 65 && code <= 90) {
    return first;
  }
  return '#';
}

/// 按首字母分组，返回 `(字母, 联系人)` 列表，`#` 排在最后。
List<(String, List<Contact>)> groupContacts(Iterable<Contact> contacts) {
  final Map<String, List<Contact>> buckets = <String, List<Contact>>{};
  for (final Contact contact in contacts) {
    buckets.putIfAbsent(contactGroupLetter(contact.name), () => <Contact>[]).add(contact);
  }
  final List<String> letters = buckets.keys.toList()
    ..sort((String a, String b) {
      if (a == '#') {
        return 1;
      }
      if (b == '#') {
        return -1;
      }
      return a.compareTo(b);
    });
  return <(String, List<Contact>)>[
    for (final String letter in letters)
      (
        letter,
        buckets[letter]!
          ..sort((Contact a, Contact b) {
            final int byName = a.name.compareTo(b.name);
            return byName != 0 ? byName : a.id.compareTo(b.id);
          }),
      ),
  ];
}
