import 'dart:async';

/// 内核业务错误，错误码与 `docs/Nexmem-engineering-plan.md` §6.4 的固定枚举一致。
///
/// 业务页面只处理 [code]，不解析 Go 侧的错误字符串。
class NexmemException implements Exception {
  const NexmemException(this.code, this.message, {this.retryable = false});

  /// 固定错误码，例如 `NOT_ONLINE`、`INVALID_ARG`。
  final String code;

  /// 便于排查的说明文本，不保证跨版本稳定。
  final String message;

  /// 是否可安全重试（网络类错误为 true）。
  final bool retryable;

  @override
  String toString() => 'NexmemException($code): $message';
}

/// 内核单向事件信封，[seq] 由 Go 侧全局递增，用于去重、缺口检测与重放。
class CoreEvent {
  const CoreEvent({
    required this.seq,
    required this.type,
    required this.ts,
    this.data = const <String, dynamic>{},
  });

  /// 从事件 JSON 解析；缺少必需字段时抛出 [FormatException]。
  factory CoreEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String || type.isEmpty) {
      throw const FormatException('事件缺少 type');
    }
    final rawSeq = json['seq'];
    final rawTs = json['ts'];
    final rawData = json['data'];
    return CoreEvent(
      seq: rawSeq is num ? rawSeq.toInt() : 0,
      type: type,
      ts: rawTs is num ? rawTs.toInt() : 0,
      data: rawData is Map<String, dynamic>
          ? rawData
          : const <String, dynamic>{},
    );
  }

  /// 全局递增序号；`resync_required` 固定为 0，不参与去重。
  final int seq;

  /// 事件类型，例如 `message.new`、`state.changed`。
  final String type;

  /// 事件产生的毫秒时间戳。
  final int ts;

  /// 事件载荷；大对象只放指针（会话 ID、消息 UUID、路径）。
  final Map<String, dynamic> data;

  /// 缺口或缓冲溢出时需要应用重新同步。
  bool get isResync => type == 'resync_required';

  @override
  String toString() => 'CoreEvent(seq: $seq, type: $type)';
}

/// 编码请求信封，字段与 Go 侧 `gateway.Request` 一致；`params` 为空时省略，
/// 由内核按空对象处理。
Map<String, dynamic> encodeRequestEnvelope({
  required int id,
  required String method,
  Map<String, dynamic>? params,
  int? timeoutMs,
}) {
  return <String, dynamic>{
    'id': id,
    'method': method,
    'params': ?params,
    'timeout_ms': ?timeoutMs,
  };
}

/// 解码响应信封：成功返回 `data`（非对象时返回空 Map），失败抛出
/// [NexmemException]，错误码与 Go 侧固定枚举一一对应。
Map<String, dynamic> decodeResponseEnvelope(Map<String, dynamic> json) {
  if (json['ok'] == true) {
    final data = json['data'];
    return data is Map<String, dynamic>
        ? data
        : const <String, dynamic>{};
  }
  final error = json['error'];
  final code = error is Map<String, dynamic> ? '${error['code']}' : '';
  final message = error is Map<String, dynamic> ? '${error['message']}' : '';
  final retryable =
      error is Map<String, dynamic> && error['retryable'] == true;
  throw NexmemException(
    code.isEmpty ? 'INVALID_ARG' : code,
    message.isEmpty ? '内核返回失败响应' : message,
    retryable: retryable,
  );
}

/// 跨端统一的内核传输接口：桌面走 `dart:ffi`、移动端走 MethodChannel、
/// Web 走 WebSocket，但三者共用同一 Request/Response/Event 语义。
abstract class CoreTransport {
  /// 发起一次请求并等待对应响应；失败抛 [NexmemException]。
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  });

  /// 事件流；断线重连后按 seq 重放，缺口以 `resync_required` 事件暴露。
  Stream<CoreEvent> get events;

  /// 已消费到的最大事件序号，重连时作为 `since` 上报。
  int get lastSeq;

  /// 关闭连接并释放资源。
  Future<void> close();
}
