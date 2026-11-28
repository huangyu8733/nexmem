/// 群分享信息解析：把「分享群信息」复制出的文本变成可执行的入群申请。
///
/// 新版分享文本会附带 `nexmem://group/join?g=...&o=...&n=...` 链接，解析与
/// 界面语言无关；旧版纯文本仍按群号/群主标签做兼容解析。
library;

class GroupShareInfo {
  const GroupShareInfo({
    required this.groupId,
    required this.owner,
    this.title = '',
  });

  /// 群 ID（契约中的 base64url 或 hex 字符串）。
  final String groupId;

  /// 群主账号（base64url 或 hex 字符串）。
  final String owner;

  /// 群名称，可为空。
  final String title;

  @override
  String toString() => 'GroupShareInfo($groupId, $owner, $title)';
}

final RegExp _shareLinkPattern = RegExp(
  r'nexmem://group/join\?[^\s，。；、)）\]】]+',
  caseSensitive: false,
);

/// 构造可粘贴到任意聊天/笔记里的入群链接。
String buildGroupShareLink({
  required String groupId,
  required String owner,
  String title = '',
}) {
  final Uri uri = Uri(
    scheme: 'nexmem',
    host: 'group',
    path: '/join',
    queryParameters: <String, String>{
      'g': groupId,
      'o': owner,
      if (title.isNotEmpty) 'n': title,
    },
  );
  return uri.toString();
}

/// 从分享文本中解析群信息；无法识别时返回 null。
GroupShareInfo? parseGroupShareText(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final RegExpMatch? link = _shareLinkPattern.firstMatch(trimmed);
  if (link != null) {
    final Uri? uri = Uri.tryParse(link.group(0) ?? '');
    if (uri != null) {
      final String groupId = uri.queryParameters['g']?.trim() ?? '';
      final String owner = uri.queryParameters['o']?.trim() ?? '';
      if (groupId.isNotEmpty && owner.isNotEmpty) {
        return GroupShareInfo(
          groupId: groupId,
          owner: owner,
          title: uri.queryParameters['n'] ?? '',
        );
      }
    }
  }

  // 兼容旧版「群聊「X」群号：Y，群主：Z」纯文本。
  final RegExpMatch? idMatch = RegExp(
    r'群号\s*[：:]\s*([A-Za-z0-9_-]+)',
  ).firstMatch(trimmed);
  final RegExpMatch? ownerMatch = RegExp(
    r'群主\s*[：:]\s*([A-Za-z0-9_-]+)',
  ).firstMatch(trimmed);
  if (idMatch == null || ownerMatch == null) {
    return null;
  }
  final RegExpMatch? titleMatch = RegExp(
    r'群聊\s*[「\[]\s*([^」\]]+)\s*[」\]]',
  ).firstMatch(trimmed);
  return GroupShareInfo(
    groupId: idMatch.group(1)!,
    owner: ownerMatch.group(1)!,
    title: titleMatch?.group(1)?.trim() ?? '',
  );
}
