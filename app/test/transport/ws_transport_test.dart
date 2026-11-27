import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/event_buffer.dart';
import 'package:nexmem_app/transport/transport.dart';
import 'package:nexmem_app/transport/ws_transport.dart';

/// 与 `core/server/webd` 行为一致的最小网关：令牌门禁、请求应答、
/// 事件广播、`?since=` 重放与缺口 `resync_required`。
class FakeCoreServer {
  FakeCoreServer({this.token = 'test-token', this.bufferLimit = 512});

  final String token;
  int bufferLimit;

  final List<Map<String, dynamic>> _buffer = <Map<String, dynamic>>[];
  final List<WebSocket> _clients = <WebSocket>[];
  HttpServer? _server;
  int _seq = 0;

  /// 最近一次握手携带的 since；未携带为 null。
  int? lastSince;
  int connectCount = 0;

  Uri get wsEndpoint => Uri.parse('ws://127.0.0.1:${_server!.port}/ws');

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((HttpRequest request) => unawaited(_handleRequest(request)));
  }

  Future<void> stop() async {
    await dropClients();
    await _server?.close(force: true);
    _server = null;
  }

  /// 广播一条事件，返回分配的序号。
  int broadcast(String type, Map<String, dynamic> data) {
    final seq = ++_seq;
    final frame = <String, dynamic>{
      'seq': seq,
      'type': type,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    };
    _buffer.add(frame);
    while (_buffer.length > bufferLimit) {
      _buffer.removeAt(0);
    }
    final payload = jsonEncode(frame);
    for (final client in List<WebSocket>.of(_clients)) {
      client.add(payload);
    }
    return seq;
  }

  /// 模拟网关进程重启：seq 重新从 0 计数、事件缓冲清空。
  void resetSeq() {
    _seq = 0;
    _buffer.clear();
  }

  /// 模拟断网：服务端主动断开全部连接。
  Future<void> dropClients() async {
    final clients = List<WebSocket>.of(_clients);
    _clients.clear();
    for (final client in clients) {
      await client.close(WebSocketStatus.normalClosure);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/auth') {
      final bool ok = request.uri.queryParameters['token'] == token ||
          request.headers.value('x-nexmem-token') == token;
      request.response.statusCode = ok ? HttpStatus.ok : HttpStatus.unauthorized;
      request.response.headers.contentType = ContentType.json;
      request.response.write(ok ? '{"authorized":true}' : 'unauthorized');
      await request.response.close();
      return;
    }
    if (request.uri.path != '/ws') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.uri.queryParameters['token'] != token) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    final rawSince = request.uri.queryParameters['since'];
    final since = rawSince == null ? null : int.tryParse(rawSince);
    final socket = await WebSocketTransformer.upgrade(request);
    connectCount++;
    lastSince = since;
    _clients.add(socket);
    socket.listen(
      (dynamic raw) => _handleMessage(socket, raw),
      onDone: () => _clients.remove(socket),
      onError: (Object _) => _clients.remove(socket),
    );
    if (since != null && since > 0) {
      _resume(socket, since);
    }
  }

  void _resume(WebSocket socket, int since) {
    // 与真实网关 replay 对齐：latest 取 max(缓冲最新, 全局 seq)。
    final int latest = _buffer.isEmpty ? 0 : _buffer.last['seq'] as int;
    final int effectiveLatest = latest > _seq ? latest : _seq;
    if (_buffer.isEmpty) {
      // 网关重启后 seq 归零且缓冲清空：客户端水位超前即触发 resync。
      if (since > effectiveLatest) {
        _sendResync(socket, since);
      }
      return;
    }
    final oldest = _buffer.first['seq'] as int;
    if (since == effectiveLatest) {
      return;
    }
    if (since + 1 < oldest || since > effectiveLatest) {
      _sendResync(socket, since);
      return;
    }
    for (final frame in _buffer) {
      if ((frame['seq'] as int) > since) {
        socket.add(jsonEncode(frame));
      }
    }
  }

  void _sendResync(WebSocket socket, int since) {
    socket.add(
      jsonEncode(<String, dynamic>{
        'seq': 0,
        'type': 'resync_required',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'data': <String, dynamic>{
          'reason': 'gap',
          'since': since,
          'oldest_seq': _buffer.isEmpty ? 0 : _buffer.first['seq'],
          'latest_seq': _seq,
        },
      }),
    );
  }

  void _handleMessage(WebSocket socket, dynamic raw) {
    if (raw is! String) {
      return;
    }
    final request = jsonDecode(raw) as Map<String, dynamic>;
    final id = request['id'];
    final params = request['params'] is Map<String, dynamic>
        ? request['params'] as Map<String, dynamic>
        : const <String, dynamic>{};
    switch (request['method']) {
      case 'core.ping':
        socket.add(
          jsonEncode({
            'id': id,
            'ok': true,
            'data': {'pong': true},
          }),
        );
      case 'dm.sendText':
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': true,
            'data': {'msg_uuid': 'uuid-${params['peer']}-${params['text']}'},
          }),
        );
      case 'dm.sendFile':
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': false,
            'error': {
              'code': 'NOT_STARTED',
              'message': '未接入',
              'retryable': false,
            },
          }),
        );
      default:
        socket.add(
          jsonEncode(<String, dynamic>{
            'id': id,
            'ok': false,
            'error': {
              'code': 'INVALID_ARG',
              'message': '未知方法',
              'retryable': false,
            },
          }),
        );
    }
  }
}

Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String reason = '',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待条件超时: $reason', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<FakeCoreServer> startServer({int bufferLimit = 512}) async {
  final server = FakeCoreServer(bufferLimit: bufferLimit);
  await server.start();
  addTearDown(server.stop);
  return server;
}

WsTransport newTransport(
  FakeCoreServer server, {
  String token = 'test-token',
  EventSeqStore? seqStore,
  int eventBufferSize = 512,
  AuthProber? authProber,
  WsConnector? connector,
}) {
  final transport = WsTransport(
    endpoint: server.wsEndpoint,
    token: token,
    requestTimeout: const Duration(seconds: 3),
    reconnectMin: const Duration(milliseconds: 50),
    reconnectMax: const Duration(milliseconds: 200),
    seqStore: seqStore,
    eventBufferSize: eventBufferSize,
    authProber: authProber,
    connector: connector,
  );
  addTearDown(transport.close);
  return transport;
}

void main() {
  test('文本收发往返与事件回传', () async {
    final server = await startServer();
    final transport = newTransport(server);
    await transport.connect();
    await waitFor(
      () => server.connectCount >= 1,
      reason: 'server registered client',
    );

    final response = await transport.call(
      'dm.sendText',
      params: <String, dynamic>{'peer': 'alice', 'text': 'hi'},
    );
    expect(response['msg_uuid'], 'uuid-alice-hi');

    final received = <CoreEvent>[];
    final subscription = transport.events.listen(received.add);
    addTearDown(subscription.cancel);

    server.broadcast('message.new', <String, dynamic>{'msg_uuid': 'u-1'});
    await waitFor(() => received.length == 1, reason: 'first event');
    expect(received.single.type, 'message.new');
    expect(received.single.seq, 1);
    expect(received.single.data['msg_uuid'], 'u-1');
    expect(transport.lastSeq, 1);
  });

  test('请求失败返回结构化错误码', () async {
    final server = await startServer();
    final transport = newTransport(server);
    await transport.connect();
    await waitFor(
      () => server.connectCount >= 1,
      reason: 'server registered client',
    );

    await expectLater(
      transport.call('dm.sendFile', params: <String, dynamic>{'peer': 'a'}),
      throwsA(
        isA<NexmemException>()
            .having((e) => e.code, 'code', 'NOT_STARTED')
            .having((e) => e.retryable, 'retryable', false),
      ),
    );
  });

  test('断线后自动重连并按 seq 重放缺失事件', () async {
    final server = await startServer();
    final transport = newTransport(server);
    final received = <CoreEvent>[];
    final subscription = transport.events.listen(received.add);
    addTearDown(subscription.cancel);

    await transport.connect();
    await waitFor(
      () => server.connectCount >= 1,
      reason: 'server registered client',
    );
    server.broadcast('message.new', <String, dynamic>{'i': 1});
    await waitFor(() => received.length == 1, reason: 'first event');

    // 断网期间产生两条事件，重连后应补齐为 1/2/3 且不重复。
    await server.dropClients();
    await waitFor(() => !transport.isConnected, reason: 'disconnected');
    server.broadcast('message.new', <String, dynamic>{'i': 2});
    server.broadcast('message.new', <String, dynamic>{'i': 3});

    await waitFor(() => received.length == 3, reason: 'replay 3 events');
    expect(received.map((e) => e.seq).toList(), <int>[1, 2, 3]);
    expect(transport.lastSeq, 3);
    expect(server.lastSince, 1);
    expect(server.connectCount, greaterThanOrEqualTo(2));
  });

  test('缓冲无法覆盖缺口时收到 resync_required', () async {
    final server = await startServer(bufferLimit: 2);
    final transport = newTransport(server);
    final received = <CoreEvent>[];
    final subscription = transport.events.listen(received.add);
    addTearDown(subscription.cancel);

    await transport.connect();
    await waitFor(
      () => server.connectCount >= 1,
      reason: 'server registered client',
    );
    server.broadcast('message.new', <String, dynamic>{'i': 1});
    await waitFor(() => received.length == 1, reason: 'first event');

    await server.dropClients();
    await waitFor(() => !transport.isConnected, reason: 'disconnected');
    for (var i = 2; i <= 5; i++) {
      server.broadcast('message.new', <String, dynamic>{'i': i});
    }

    await waitFor(
      () => received.any((e) => e.type == 'resync_required'),
      timeout: const Duration(seconds: 5),
    );
    final resync = received.firstWhere((e) => e.type == 'resync_required');
    expect(resync.data['reason'], 'gap');
    // 收到服务端 resync 后水位对齐到 latest_seq(5)，避免后续事件被误判重复；
    // 应用层会据 resync 事件做全量重新同步。
    expect(transport.lastSeq, resync.data['latest_seq']);
  });

  test('错误令牌抛出 UNAUTHORIZED 且停止自动重连', () async {
    final server = await startServer();
    final transport = newTransport(server, token: 'wrong-token');
    await expectLater(
      transport.connect(),
      throwsA(
        isA<NexmemException>()
            .having((e) => e.code, 'code', 'UNAUTHORIZED')
            .having((e) => e.retryable, 'retryable', false)
            .having((e) => e.message, 'message', contains('令牌')),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.connectCount, 0, reason: '令牌错误不能进入无限重连');
    await expectLater(
      transport.call('core.ping'),
      throwsA(isA<NexmemException>().having((e) => e.code, 'code', 'UNAUTHORIZED')),
    );
  });

  test('旧网关探测不可用时仍从握手 401 识别令牌错误', () async {
    final server = await startServer();
    final transport = newTransport(
      server,
      token: 'wrong-token',
      authProber: (Uri uri, String token) async => true,
      connector: (Uri uri) async =>
          throw StateError('Unexpected response code: 401 Unauthorized'),
    );
    await expectLater(
      transport.connect(),
      throwsA(
        isA<NexmemException>().having((e) => e.code, 'code', 'UNAUTHORIZED'),
      ),
    );
    expect(server.connectCount, 0);
  });

  test('403 forbidden 不当作令牌失效，仍按可重试的连接错误处理', () async {
    final server = await startServer();
    final transport = WsTransport(
      endpoint: server.wsEndpoint,
      token: 'test-token',
      autoReconnect: false,
      authProber: (Uri uri, String token) async => true,
      connector: (Uri uri) async =>
          throw StateError('Unexpected response code: 403 Forbidden'),
    );
    addTearDown(transport.close);

    await expectLater(
      transport.connect(),
      throwsA(
        isA<NexmemException>()
            .having((e) => e.code, 'code', 'NOT_ONLINE')
            .having((e) => e.retryable, 'retryable', true)
            .having((e) => e.message, 'message', contains('403')),
      ),
    );
    // 仍允许再次连接，策略/Origin 恢复后客户端可自行重试。
    await expectLater(
      transport.connect(),
      throwsA(isA<NexmemException>().having((e) => e.code, 'code', 'NOT_ONLINE')),
    );
  });

  test('未连接时调用会先建立连接再发送请求', () async {
    final server = await startServer();
    final transport = newTransport(server);
    final response = await transport.call('core.ping');
    expect(response['pong'], isTrue);
    expect(server.connectCount, 1, reason: '首个请求应触发一次握手');
  });

  test('连接失败时调用返回 NOT_ONLINE', () async {
    final server = await startServer();
    final transport = newTransport(server);
    await server.stop();
    await expectLater(
      transport.call('core.ping'),
      throwsA(
        isA<NexmemException>().having((e) => e.code, 'code', 'NOT_ONLINE'),
      ),
    );
  });

  test('持久化水位作为 since 上报并补齐刷新期间事件', () async {
    final server = await startServer();
    // 模拟页面刷新前已消费 seq 1/2，刷新后重连应只补发之后的事件。
    server.broadcast('message.new', <String, dynamic>{'i': 1});
    server.broadcast('message.new', <String, dynamic>{'i': 2});
    final store = MemoryEventSeqStore()..save(2);
    final transport = newTransport(server, seqStore: store);
    final received = <CoreEvent>[];
    final subscription = transport.events.listen(received.add);
    addTearDown(subscription.cancel);

    await transport.connect();
    await waitFor(
      () => server.connectCount >= 1,
      reason: 'server registered client',
    );
    expect(server.lastSince, 2, reason: '重连必须携带持久化水位');

    server.broadcast('message.new', <String, dynamic>{'i': 3});
    await waitFor(
      () => received.length == 1,
      reason: 'new event after refresh',
    );
    expect(received.single.seq, 3);
    expect(store.load(), 3, reason: '消费后水位应落盘');
  });

  test('网关重启 seq 回退后收到 resync 并对齐水位，新事件不再被误判重复', () async {
    final server = await startServer();
    // 页面刷新前客户端已消费到 seq 5。
    for (var i = 1; i <= 5; i++) {
      server.broadcast('message.new', <String, dynamic>{'i': i});
    }
    // 模拟网关进程重启：seq 归零、缓冲清空。
    server.resetSeq();
    final store = MemoryEventSeqStore()..save(5);
    final transport = newTransport(server, seqStore: store);
    final received = <CoreEvent>[];
    final subscription = transport.events.listen(received.add);
    addTearDown(subscription.cancel);

    await transport.connect();
    await waitFor(
      () => received.any((e) => e.type == 'resync_required'),
      reason: '服务端应下发 resync 纠正超前水位',
    );
    expect(transport.lastSeq, 0, reason: '水位对齐到回退后的 latest_seq');
    expect(store.load(), 0, reason: '纠正后的水位应落盘，避免刷新后再次超前');

    // 网关重启后的第一条新事件 seq=1 必须能被接受，而不是当重复丢弃。
    server.broadcast('message.new', <String, dynamic>{'i': 'after-restart'});
    await waitFor(
      () => received.any((e) => e.data['i'] == 'after-restart'),
      reason: '重启后的新事件应被交付',
    );
  });

  test('进程内热重启可经 replaySince 重放缺失事件', () async {
    final server = await startServer();
    final transport = newTransport(server, eventBufferSize: 4);
    final received = <CoreEvent>[];
    final subscription = transport.events.listen(received.add);
    addTearDown(subscription.cancel);

    await transport.connect();
    await waitFor(
      () => server.connectCount >= 1,
      reason: 'server registered client',
    );
    server.broadcast('message.new', <String, dynamic>{'i': 1});
    server.broadcast('message.new', <String, dynamic>{'i': 2});
    await waitFor(() => received.length == 2, reason: 'two events');

    expect(transport.lastSeq, 2);
    expect(transport.replaySince(1)?.map((e) => e.seq).toList(), <int>[
      2,
    ], reason: '热重启后按水位重放未消费事件');
    expect(transport.replaySince(2), isEmpty);
  });

  test('事件缓冲淘汰后 replaySince 返回 null 要求重新同步', () async {
    final server = await startServer();
    final transport = newTransport(server, eventBufferSize: 2);
    final received = <CoreEvent>[];
    final subscription = transport.events.listen(received.add);
    addTearDown(subscription.cancel);

    await transport.connect();
    await waitFor(
      () => server.connectCount >= 1,
      reason: 'server registered client',
    );
    server.broadcast('message.new', <String, dynamic>{'i': 1});
    await waitFor(() => received.length == 1, reason: 'first event');

    // 服务端继续广播但客户端断线，重放回填时最早事件已被缓冲淘汰。
    await server.dropClients();
    await waitFor(() => !transport.isConnected, reason: 'disconnected');
    for (var i = 2; i <= 5; i++) {
      server.broadcast('message.new', <String, dynamic>{'i': i});
    }
    await waitFor(() => received.length == 5, reason: 'replay all events');

    expect(transport.replaySince(1), isNull, reason: 'Seq 2 已被淘汰');
    expect(transport.replaySince(3)?.map((e) => e.seq).toList(), <int>[4, 5]);
  });
}
