import '../../transport/transport.dart';

/// 一条消息检索命中，字段对齐内核 `msg.search` 的返回项（P6-07）。
class SearchHit {
  const SearchHit({
    required this.msgUuid,
    required this.conversationId,
    required this.sentAt,
    this.snippet = '',
    this.direction = 'in',
  });

  /// 从 `msg.search` 的单个 item 解析；缺少必需字段时抛出 [FormatException]。
  factory SearchHit.fromJson(Map<String, dynamic> json) {
    final Object? msgUuid = json['msg_uuid'];
    final Object? conversationId = json['conversation_id'];
    if (msgUuid is! String || msgUuid.isEmpty) {
      throw const FormatException('检索结果缺少 msg_uuid');
    }
    if (conversationId is! String || conversationId.isEmpty) {
      throw const FormatException('检索结果缺少 conversation_id');
    }
    final Object? sentAt = json['sent_at'];
    final Object? snippet = json['snippet'];
    final Object? direction = json['direction'];
    return SearchHit(
      msgUuid: msgUuid,
      conversationId: conversationId,
      sentAt: sentAt is num ? sentAt.toInt() : 0,
      snippet: snippet is String ? snippet : '',
      direction: direction is String ? direction : 'in',
    );
  }

  final String msgUuid;
  final String conversationId;

  /// 消息发送时间（Unix 毫秒）。
  final int sentAt;

  /// 命中片段，关键词以 `[关键词]` 标记，见 [snippetSegments]。
  final String snippet;

  /// `in` 表示对端发来，`out` 表示本机发出。
  final String direction;

  DateTime get sentAtTime => DateTime.fromMillisecondsSinceEpoch(sentAt);

  bool get isMine => direction == 'out';

  /// 把片段拆成普通文本与高亮文本，交给 UI 用不同样式渲染。
  List<SnippetSegment> get snippetSegments => parseSnippet(snippet);
}

/// 片段中的一段文本；[highlight] 为 true 时表示命中的关键词。
class SnippetSegment {
  const SnippetSegment(this.text, {this.highlight = false});

  final String text;
  final bool highlight;

  @override
  bool operator ==(Object other) {
    return other is SnippetSegment &&
        other.text == text &&
        other.highlight == highlight;
  }

  @override
  int get hashCode => Object.hash(text, highlight);

  @override
  String toString() => highlight ? '[$text]' : text;
}

/// 解析内核生成的片段：`…前文[关键词]后文…`。
///
/// 未闭合的 `[` 按普通字符处理；连续多段命中都能识别。
List<SnippetSegment> parseSnippet(String snippet) {
  if (snippet.isEmpty) {
    return const <SnippetSegment>[];
  }
  final List<SnippetSegment> out = <SnippetSegment>[];
  int cursor = 0;
  while (cursor < snippet.length) {
    final int open = snippet.indexOf('[', cursor);
    if (open < 0) {
      out.add(SnippetSegment(snippet.substring(cursor)));
      break;
    }
    final int close = snippet.indexOf(']', open + 1);
    if (close < 0) {
      out.add(SnippetSegment(snippet.substring(cursor)));
      break;
    }
    if (open > cursor) {
      out.add(SnippetSegment(snippet.substring(cursor, open)));
    }
    if (close > open + 1) {
      out.add(SnippetSegment(snippet.substring(open + 1, close), highlight: true));
    }
    cursor = close + 1;
  }
  return out;
}

/// 本地消息全文检索通道；由 `core.start` 接通后注入实现。
abstract class MessageSearchService {
  /// 按关键词检索，失败抛 [NexmemException]。
  ///
  /// [conversationId] 非空时只在该会话内检索（对应内核 `msg.search` 的
  /// `conversation_id`，P6-33）；为空表示检索全部会话。
  Future<List<SearchHit>> search(
    String query, {
    int limit = 20,
    String conversationId = '',
  });
}

/// 经统一的 [CoreTransport] 调用内核 `msg.search`。
class TransportMessageSearchService implements MessageSearchService {
  const TransportMessageSearchService(this.transport);

  final CoreTransport transport;

  @override
  Future<List<SearchHit>> search(
    String query, {
    int limit = 20,
    String conversationId = '',
  }) async {
    final Map<String, dynamic> params = <String, dynamic>{
      'q': query,
      'limit': limit,
    };
    if (conversationId.isNotEmpty) {
      params['conversation_id'] = conversationId;
    }
    final Map<String, dynamic> data = await transport.call(
      'msg.search',
      params: params,
    );
    final Object? items = data['items'];
    if (items is! List) {
      return const <SearchHit>[];
    }
    final List<SearchHit> hits = <SearchHit>[];
    for (final Object? item in items) {
      if (item is Map<String, dynamic>) {
        hits.add(SearchHit.fromJson(item));
      }
    }
    return hits;
  }
}

/// 内核尚未启动时的占位实现：明确返回 NOT_STARTED，避免 UI 静默无结果。
class UnavailableMessageSearchService implements MessageSearchService {
  const UnavailableMessageSearchService();

  @override
  Future<List<SearchHit>> search(
    String query, {
    int limit = 20,
    String conversationId = '',
  }) {
    throw const NexmemException('NOT_STARTED', '搜索服务尚未接入内核');
  }
}
