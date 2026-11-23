// P6-07 验收：消息搜索（检索、高亮、空态、错误重试）、已读推进与跳转。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chats/chats_page.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/chats/conversation_store.dart';
import 'package:nexmem_app/features/chats/read_marker.dart';
import 'package:nexmem_app/features/search/message_search.dart';
import 'package:nexmem_app/features/search/search_page.dart';
import 'package:nexmem_app/transport/transport.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: child,
  );
}

class _FakeSearch implements MessageSearchService {
  _FakeSearch({this.hits = const <SearchHit>[], this.error});

  List<SearchHit> hits;
  NexmemException? error;
  final List<String> queries = <String>[];
  final List<String> conversationIds = <String>[];

  @override
  Future<List<SearchHit>> search(
    String query, {
    int limit = 20,
    String conversationId = '',
  }) async {
    queries.add(query);
    conversationIds.add(conversationId);
    if (error != null) {
      throw error!;
    }
    return hits;
  }
}

class _RecordingTransport implements CoreTransport {
  final List<String> methods = <String>[];
  Map<String, dynamic>? lastParams;
  Map<String, dynamic> response = <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    methods.add(method);
    lastParams = params;
    return response;
  }

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

SearchHit _hit({
  String msgUuid = 'm1',
  String conversationId = 'dm:alice',
  String snippet = '明天讨论 [检索] 方案',
  int sentAt = 1700000000000,
  String direction = 'in',
}) {
  return SearchHit(
    msgUuid: msgUuid,
    conversationId: conversationId,
    sentAt: sentAt,
    snippet: snippet,
    direction: direction,
  );
}

void main() {
  group('parseSnippet', () {
    test('识别多段高亮', () {
      final List<SnippetSegment> segments =
          parseSnippet('前缀[检索]中间[方案]后缀');
      expect(segments, <SnippetSegment>[
        const SnippetSegment('前缀'),
        const SnippetSegment('检索', highlight: true),
        const SnippetSegment('中间'),
        const SnippetSegment('方案', highlight: true),
        const SnippetSegment('后缀'),
      ]);
    });

    test('未闭合括号按普通文本处理', () {
      expect(parseSnippet('异常[检索'), <SnippetSegment>[
        const SnippetSegment('异常[检索'),
      ]);
      expect(parseSnippet(''), isEmpty);
    });
  });

  test('TransportMessageSearchService 调用 msg.search 并解析命中', () async {
    final _RecordingTransport transport = _RecordingTransport();
    transport.response = <String, dynamic>{
      'items': <Map<String, dynamic>>[
        <String, dynamic>{
          'msg_uuid': 'm9',
          'conversation_id': 'dm:alice',
          'sent_at': 42,
          'direction': 'out',
          'snippet': '关于[检索]的实现',
        },
      ],
    };
    final MessageSearchService service = TransportMessageSearchService(transport);

    final List<SearchHit> hits = await service.search('检索', limit: 30);

    expect(transport.methods, <String>['msg.search']);
    expect(transport.lastParams, <String, dynamic>{'q': '检索', 'limit': 30});
    expect(hits, hasLength(1));
    expect(hits.single.msgUuid, 'm9');
    expect(hits.single.isMine, isTrue);
    expect(hits.single.sentAt, 42);
    expect(
      hits.single.snippetSegments.where((SnippetSegment s) => s.highlight),
      <SnippetSegment>[const SnippetSegment('检索', highlight: true)],
    );
  });

  test('TransportMessageSearchService 透传 conversation_id（P6-33）', () async {
    final _RecordingTransport transport = _RecordingTransport();
    transport.response = <String, dynamic>{'items': <dynamic>[]};
    final MessageSearchService service = TransportMessageSearchService(transport);

    await service.search('检索', limit: 10, conversationId: 'dm:bob');

    expect(transport.lastParams, <String, dynamic>{
      'q': '检索',
      'limit': 10,
      'conversation_id': 'dm:bob',
    });
  });

  test('conversation_id 为空时不下发该字段', () async {
    final _RecordingTransport transport = _RecordingTransport();
    transport.response = <String, dynamic>{'items': <dynamic>[]};
    final MessageSearchService service = TransportMessageSearchService(transport);

    await service.search('检索');

    expect(transport.lastParams, <String, dynamic>{'q': '检索', 'limit': 20});
  });

  test('TransportReadMarker 调用 msg.markRead 上报已读位置', () async {
    final _RecordingTransport transport = _RecordingTransport();
    await TransportReadMarker(transport).markRead(
      conversationId: 'dm:alice',
      upToId: 'm9',
    );
    expect(transport.methods, <String>['msg.markRead']);
    expect(transport.lastParams, <String, dynamic>{
      'conversation_id': 'dm:alice',
      'up_to_id': 'm9',
    });
  });

  testWidgets('输入关键词后展示命中并高亮，点击回调命中', (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch(hits: <SearchHit>[_hit()]);
    SearchHit? opened;
    await tester.pumpWidget(_wrap(SearchPage(
      service: search,
      titleOf: (String id) => id == 'dm:alice' ? 'Alice' : id,
      onOpen: (SearchHit hit) => opened = hit,
    )));

    expect(find.text('输入关键词搜索聊天记录'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('search-field')), '检索');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(search.queries, <String>['检索']);
    expect(find.byKey(const ValueKey<String>('search-hit-m1')), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('search-hit-m1')));
    expect(opened?.msgUuid, 'm1');
  });

  testWidgets('会话筛选条选中后按会话重新检索并透传 conversation_id（P6-33）',
      (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch(hits: <SearchHit>[_hit()]);
    await tester.pumpWidget(_wrap(SearchPage(
      service: search,
      titleOf: (String id) => id == 'dm:alice' ? 'Alice' : id,
      conversationIds: <String>['dm:alice'],
    )));

    // 输入关键词触发全会话检索。
    await tester.enterText(find.byKey(const Key('search-field')), '检索');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(search.conversationIds.last, '');

    // 选中 Alice 后重新检索，conversation_id 下发。
    await tester.tap(find.byKey(const ValueKey<String>('search-filter-dm:alice')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(search.conversationIds.last, 'dm:alice');
    expect(search.queries, <String>['检索', '检索']);
  });

  testWidgets('无结果时展示空态', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(SearchPage(service: _FakeSearch())));
    await tester.enterText(find.byKey(const Key('search-field')), '不存在');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('没有找到相关消息'), findsOneWidget);
  });

  testWidgets('检索失败时展示错误并可重试', (WidgetTester tester) async {
    final _FakeSearch search = _FakeSearch(
      error: const NexmemException('NOT_STARTED', '搜索服务尚未接入内核'),
    );
    await tester.pumpWidget(_wrap(SearchPage(service: search)));
    await tester.enterText(find.byKey(const Key('search-field')), '检索');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('搜索服务尚未接入内核'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(search.queries, <String>['检索', '检索']);
  });

  testWidgets('会话列表点击搜索框进入搜索页，命中后回调上层并返回', (WidgetTester tester) async {
    final ConversationStore store = ConversationStore(
      initial: <ConversationItem>[
        ConversationItem(id: 'dm:alice', title: 'Alice'),
      ],
    );
    final _FakeSearch search = _FakeSearch(hits: <SearchHit>[_hit()]);
    SearchHit? opened;

    await tester.pumpWidget(_wrap(Scaffold(
      body: ChatsPage(
        store: store,
        search: search,
        onOpenHit: (SearchHit hit) => opened = hit,
      ),
    )));

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-field')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-field')), '检索');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('search-hit-m1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-field')), findsNothing);
    expect(opened?.conversationId, 'dm:alice');
  });
}
