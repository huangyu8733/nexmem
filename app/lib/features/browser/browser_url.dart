/// 内置浏览器共用的 URL 归一化与提取工具。
///
/// 只接受 http / https，避免把 `file://`、`nexmem://` 等交给网页视图。
library;

final RegExp _urlPattern = RegExp(
  r'(?:https?://)?[\w-]+(?:\.[\w-]+)+(?::\d+)?(?:[/?#][^\s<>，。；：！？、）)]*)?',
  caseSensitive: false,
);

/// 把用户输入的网址归一化为可加载的 http(s) URL；非法输入返回 null。
String? normalizeWebUrl(String raw) {
  final String value = raw.trim();
  if (value.isEmpty || value.contains(RegExp(r'\s'))) {
    return null;
  }
  String candidate = value;
  final Uri? direct = Uri.tryParse(candidate);
  if (direct != null &&
      direct.hasScheme &&
      (direct.scheme == 'http' || direct.scheme == 'https')) {
    if (direct.host.isEmpty) {
      return null;
    }
    return direct.toString();
  }
  if (direct != null && direct.hasScheme) {
    return null;
  }
  candidate = 'https://$candidate';
  final Uri? parsed = Uri.tryParse(candidate);
  if (parsed == null || parsed.host.isEmpty) {
    return null;
  }
  if (parsed.host.contains('.') == false &&
      parsed.host != 'localhost' &&
      parsed.host != '127.0.0.1') {
    return null;
  }
  return parsed.toString();
}

/// 文本中识别出的一个网址片段。
///
/// [text] 是原文中可直接高亮的部分（不含补全的 scheme），
/// [url] 是补全 scheme 后可直接加载的地址，[start]/[end] 是原文区间。
class WebUrlMatch {
  const WebUrlMatch({
    required this.text,
    required this.url,
    required this.start,
    required this.end,
  });

  final String text;
  final String url;
  final int start;
  final int end;
}

/// 从一段文本中提取全部 http(s) 网址，供消息气泡直接点击与「打开链接」共用。
List<WebUrlMatch> extractWebUrls(String text) {
  final List<WebUrlMatch> matches = <WebUrlMatch>[];
  for (final RegExpMatch match in _urlPattern.allMatches(text)) {
    String candidate = match.group(0) ?? '';
    // 去掉句子结尾常见的中文/英文标点。
    candidate = candidate.replaceFirst(RegExp(r'[.,;:!?，。；：！？、）)]+$'), '');
    if (candidate.isEmpty) {
      continue;
    }
    final String? url = normalizeWebUrl(candidate);
    if (url == null) {
      continue;
    }
    matches.add(
      WebUrlMatch(
        text: candidate,
        url: url,
        start: match.start,
        end: match.start + candidate.length,
      ),
    );
  }
  return matches;
}

/// 从一段文本中提取第一个 http(s) 网址，供消息气泡「打开链接」使用。
String? extractFirstWebUrl(String text) {
  final List<WebUrlMatch> matches = extractWebUrls(text);
  return matches.isEmpty ? null : matches.first.url;
}
