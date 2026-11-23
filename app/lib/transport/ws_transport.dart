import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'event_buffer.dart';
import 'event_sequencer.dart';
import 'transport.dart';

/// 建立 WebSocket 连接的注入点，便于测试替换。
typedef WsConnector = Future<WebSocketChannel> Function(Uri uri);

/// Web 端传输实现（P1-16）：浏览器经 WebSocket 复用内核的
/// Request/Response/Event 契约，令牌随握手查询参数携带。
///
/// 断线后按指数退避自动重连，并把已消费的 [lastSeq] 作为 `since` 上报，
/// 由网关从事件缓冲重放缺口；缓冲无法覆盖时收到 `resync_required`。
class WsTransport implements CoreTransport {
  WsTransport({
    required this.endpoint,
    required this.token,
    this.requestTimeout = const Duration(seconds: 15),
    this.reconnectMin = const Duration(milliseconds: 500),
    this.reconnectMax = const Duration(seconds: 8),
    this.autoReconnect = true,
    this.seqStore,
    int eventBufferSize = 512,
    WsConnector? connector,
  }) : _connector = connector ?? _defaultConnector,
       _backoff = reconnectMin {
    _buffer = EventBuffer(capacity: eventBufferSize);
  }

  /// Web 网关地址，例如 `ws://127.0.0.1:8082/ws`（必须包含 `/ws` 路径）。
  final Uri endpoint;

  /// 访问令牌，经查询参数 `?token=` 传给网关。
  final String token;

  /// 单次请求的默认超时。
  final Duration requestTimeout;

  /// 重连退避的下限。
  final Duration reconnectMin;

  /// 重连退避的上限。
  final Duration reconnectMax;

  /// 是否在断线后自动重连；测试可关闭以观察单次失败。
  final bool autoReconnect;

  /// 事件水位持久化（Web 端页面刷新后恢复 `since`）；null 表示不持久化。
  final EventSeqStore? seqStore;

  final WsConnector _connector;
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast();
  late final EventBuffer _buffer;
  final Map<int, _PendingCall> _pending = <int, _PendingCall>{};

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _connecting;
  Timer? _reconnectTimer;
  Duration _backoff;
  int _nextId = 0;
  bool _closed = false;
  bool _restored = false;

  /// 当前是否处于已连接状态。
  bool get isConnected => _channel != null;

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  int get lastSeq => _buffer.lastSeq;

  /// 进程内热重启后重放缓冲中的缺失事件；返回 null 表示缺口无法补齐，
  /// 调用方应做全量重新同步（例如重新拉取会话与消息首页）。
  List<CoreEvent>? replaySince(int since) => _buffer.replaySince(since);

  /// 建立连接；失败时抛 [NexmemException]，已连接时直接返回。
  Future<void> connect() {
    if (_closed) {
      return Future<void>.error(
        const NexmemException('NOT_STARTED', '传输已关闭，无法连接'),
      );
    }
    if (_channel != null) {
      return Future<void>.value();
    }
    return _connecting ??= _open().whenComplete(() {
      _connecting = null;
    }).catchError((Object error) {
      // 首次握手失败（如网关尚未就绪）也要进入重连，否则会永久离线。
      _scheduleReconnect();
      throw error;
    });
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    final limit = timeout ?? requestTimeout;
    WebSocketChannel? channel = _channel;
    if (channel == null) {
      // 首屏可能在握手完成前就发起请求：先等待本次连接建立，避免竞态失败。
      try {
        await connect().timeout(limit);
      } catch (_) {
        // 连接失败时保持 NOT_ONLINE 语义，由调用方按可重试处理。
      }
      channel = _channel;
    }
    if (channel == null) {
      throw const NexmemException('NOT_ONLINE', 'WebSocket 尚未连接', retryable: true);
    }
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    final timer = Timer(limit, () {
      final pending = _pending.remove(id);
      if (pending == null) {
        return;
      }
      pending.completer.completeError(
        NexmemException(
          'NOT_ONLINE',
          '请求 $method 超时（${limit.inMilliseconds}ms）',
          retryable: true,
        ),
      );
    });
    _pending[id] = _PendingCall(completer, timer);
    try {
      channel.sink.add(
        jsonEncode(
          encodeRequestEnvelope(
            id: id,
            method: method,
            params: params,
            timeoutMs: limit.inMilliseconds,
          ),
        ),
      );
    } catch (e) {
      _pending.remove(id)?.timer.cancel();
      return Future<Map<String, dynamic>>.error(
        NexmemException('NOT_ONLINE', '发送 $method 失败: $e', retryable: true),
      );
    }
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _subscription;
    _subscription = null;
    final channel = _channel;
    _channel = null;
    _failPending();
    await subscription?.cancel();
    await channel?.sink.close();
    await _events.close();
  }

  Future<void> _open() async {
    _restoreSeq();
    final since = _buffer.lastSeq;
    final base = _websocketUri(endpoint);
    final query = <String, String>{
      ...base.queryParameters,
      'token': token,
      if (since > 0) 'since': '$since',
    };
    final uri = base.replace(queryParameters: query);
    WebSocketChannel channel;
    try {
      channel = await _connector(uri);
      await channel.ready;
    } catch (e) {
      throw NexmemException(
        'NOT_ONLINE',
        'WebSocket 连接失败: $e',
        retryable: true,
      );
    }
    if (_closed) {
      await channel.sink.close();
      throw const NexmemException('NOT_STARTED', '传输已关闭，无法连接');
    }
    _channel = channel;
    _backoff = reconnectMin;
    _subscription = channel.stream.listen(
      _handleFrame,
      onError: (Object error) => _onDisconnected(error),
      onDone: () => _onDisconnected(null),
      cancelOnError: false,
    );
  }

  void _handleFrame(dynamic raw) {
    if (raw is! String) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    if (decoded.containsKey('ok')) {
      _handleResponse(decoded);
      return;
    }
    if (decoded['type'] is String) {
      _handleEvent(decoded);
    }
  }

  void _handleResponse(Map<String, dynamic> json) {
    final rawId = json['id'];
    if (rawId is! num) {
      return;
    }
    final pending = _pending.remove(rawId.toInt());
    if (pending == null) {
      // 超时后才到达的响应，直接丢弃。
      return;
    }
    pending.timer.cancel();
    try {
      pending.completer.complete(decodeResponseEnvelope(json));
    } on NexmemException catch (e) {
      pending.completer.completeError(e);
    }
  }

  void _handleEvent(Map<String, dynamic> json) {
    CoreEvent event;
    try {
      event = CoreEvent.fromJson(json);
    } on FormatException {
      return;
    }
    if (event.isResync) {
      // 服务端缓冲无法补齐缺口，交由应用做全量重新同步。
      _events.add(event);
      return;
    }
    final previous = _buffer.lastSeq;
    switch (_buffer.accept(event)) {
      case EventOrder.duplicate:
        return;
      case EventOrder.accept:
        _events.add(event);
        seqStore?.save(_buffer.lastSeq);
      case EventOrder.gap:
        _events.add(
          CoreEvent(
            seq: 0,
            type: 'resync_required',
            ts: event.ts,
            data: <String, dynamic>{
              'reason': 'gap',
              'expected': previous + 1,
              'got': event.seq,
            },
          ),
        );
        _events.add(event);
        seqStore?.save(_buffer.lastSeq);
    }
  }

  /// 首次连接前恢复持久化水位，供页面刷新后的 `since` 使用。
  void _restoreSeq() {
    if (_restored) {
      return;
    }
    _restored = true;
    final persisted = seqStore?.load();
    if (persisted != null && persisted > _buffer.lastSeq) {
      _buffer.reset(lastSeq: persisted);
    }
  }

  void _onDisconnected(Object? cause) {
    if (_closed || (_channel == null && _subscription == null)) {
      return;
    }
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    final channel = _channel;
    _channel = null;
    unawaited(channel?.sink.close());
    _failPending();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || !autoReconnect || _reconnectTimer != null) {
      return;
    }
    final delay = _backoff;
    _backoff = Duration(
      milliseconds: math.min(
        delay.inMilliseconds * 2,
        reconnectMax.inMilliseconds,
      ),
    );
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      if (_closed || _channel != null) {
        return;
      }
      try {
        await _open();
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  void _failPending() {
    if (_pending.isEmpty) {
      return;
    }
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final call in pending) {
      call.timer.cancel();
      if (!call.completer.isCompleted) {
        call.completer.completeError(
          const NexmemException('NOT_ONLINE', '连接已断开', retryable: true),
        );
      }
    }
  }

  static Future<WebSocketChannel> _defaultConnector(Uri uri) async =>
      WebSocketChannel.connect(uri);

  /// 允许用 http(s) 书写网关地址，内部统一换算为 ws(s)。
  static Uri _websocketUri(Uri uri) {
    return switch (uri.scheme) {
      'http' => uri.replace(scheme: 'ws'),
      'https' => uri.replace(scheme: 'wss'),
      _ => uri,
    };
  }
}

class _PendingCall {
  _PendingCall(this.completer, this.timer);

  final Completer<Map<String, dynamic>> completer;
  final Timer timer;
}
