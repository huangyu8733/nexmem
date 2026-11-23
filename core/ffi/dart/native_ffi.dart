// 桌面端 dart:ffi 绑定：加载 c-shared 产物（Windows .dll / macOS .dylib / Linux .so），
// 向上暴露与移动端 bridge.dart 相同的调用语义（Request/Response/Event 三种 JSON）。
//
// 约束：
// - 每次 nexmem_call 返回的缓冲必须经 nexmem_free 释放，否则逐请求泄漏；
// - 事件回调来自 Go 的任意线程，必须通过 NativeCallable.listener 回到 Dart isolate，
//   再由 EventBus 广播，禁止在回调内做耗时处理；
// - seq 去重与缺口判定属于上层（P1-10）；热重启后凭 replaySince 从原生
//   环形缓冲补齐，本文件只负责字节搬运。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _CallNative = Int32 Function(
  Pointer<Uint8> request,
  Int32 requestLen,
  Pointer<Pointer<Uint8>> out,
  Pointer<Int32> outLen,
);
typedef _CallDart = int Function(
  Pointer<Uint8> request,
  int requestLen,
  Pointer<Pointer<Uint8>> out,
  Pointer<Int32> outLen,
);

typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

typedef _EventCallbackNative = Void Function(
  Pointer<Utf8> eventType,
  Pointer<Uint8> payload,
  Int32 payloadLen,
);
typedef _SetEventCallbackNative = Void Function(
  Pointer<NativeFunction<_EventCallbackNative>>,
);

typedef _ReplayNative = Int32 Function(
  Uint64 since,
  Pointer<Pointer<Uint8>> out,
  Pointer<Int32> outLen,
);
typedef _ReplayDart = int Function(
  int since,
  Pointer<Pointer<Uint8>> out,
  Pointer<Int32> outLen,
);

typedef _LastSeqNative = Uint64 Function();
typedef _LastSeqDart = int Function();

/// 与 Go 侧固定错误码一一对应的异常。
class NexmemException implements Exception {
  NexmemException(this.code, this.message, {this.retryable = false});

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'NexmemException($code): $message';
}

/// 桌面端内核客户端：一个进程只创建一次，退出前调用 [close]。
class NativeNexmem {
  NativeNexmem._(this._lib)
    : _call = _lib.lookupFunction<_CallNative, _CallDart>('nexmem_call'),
      _free = _lib.lookupFunction<_FreeNative, _FreeDart>('nexmem_free'),
      _replay = _lib.lookupFunction<_ReplayNative, _ReplayDart>(
        'nexmem_replay_events',
      ),
      _lastSeq = _lib.lookupFunction<_LastSeqNative, _LastSeqDart>(
        'nexmem_last_event_seq',
      ),
      _setEventCallback = _lib
          .lookupFunction<_SetEventCallbackNative, _SetEventCallbackNative>(
            'nexmem_set_event_cb',
          );

  factory NativeNexmem.open({String? libraryPath}) {
    final lib = DynamicLibrary.open(libraryPath ?? _defaultLibraryName());
    return NativeNexmem._(lib);
  }

  static String _defaultLibraryName() {
    final override = Platform.environment['NEXMEM_LIB'];
    if (override != null && override.isNotEmpty) {
      return override;
    }
    if (Platform.isWindows) return 'nexmem.dll';
    if (Platform.isMacOS) return 'libnexmem.dylib';
    return 'libnexmem.so';
  }

  final DynamicLibrary _lib;
  final _CallDart _call;
  final _FreeDart _free;
  final _ReplayDart _replay;
  final _LastSeqDart _lastSeq;
  final _SetEventCallbackNative _setEventCallback;

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  NativeCallable<_EventCallbackNative>? _eventCallable;
  int _nextId = 1;

  /// 内核事件流；元素为 `{seq, type, ts, data}`。
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// 发送一条请求并等待响应；业务失败抛 [NexmemException]。
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
    int timeoutMs = 15000,
  ]) async {
    final id = _nextId++;
    final body = utf8.encode(
      jsonEncode({
        'id': id,
        'method': method,
        if (params != null) 'params': params,
        if (timeoutMs > 0) 'timeout_ms': timeoutMs,
      }),
    );

    final request = body.isEmpty ? _allocate(1) : _allocate(body.length);
    final outPtr = _allocatePointer();
    final outLenPtr = _allocateInt32();
    try {
      if (body.isNotEmpty) {
        request.asTypedList(body.length).setAll(0, body);
      }
      final ret = _call(request, body.length, outPtr, outLenPtr);
      if (ret != 0) {
        throw NexmemException('INVALID_ARG', 'nexmem_call 返回 $ret');
      }
      final out = outPtr.value;
      final outLen = outLenPtr.value;
      if (out == nullptr || outLen < 0) {
        throw NexmemException('INVALID_ARG', '内核未返回响应缓冲');
      }
      try {
        final bytes = Uint8List.fromList(out.asTypedList(outLen));
        final response = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response['ok'] == true) {
          return (response['data'] as Map?)?.cast<String, dynamic>() ??
              const {};
        }
        final error =
            (response['error'] as Map?)?.cast<String, dynamic>() ?? const {};
        throw NexmemException(
          (error['code'] as String?) ?? 'INVALID_ARG',
          (error['message'] as String?) ?? '内核返回未知错误',
          retryable: error['retryable'] == true,
        );
      } finally {
        _free(out);
      }
    } finally {
      malloc.free(request);
      malloc.free(outPtr);
      malloc.free(outLenPtr);
    }
  }

  /// 注册事件回调；重复调用会替换上一份回调。
  void listenEvents() {
    if (_eventCallable != null) return;
    final callable = NativeCallable<_EventCallbackNative>.listener(_onEvent);
    _eventCallable = callable;
    _setEventCallback(callable.nativeFunction);
  }

  void _onEvent(
    Pointer<Utf8> eventType,
    Pointer<Uint8> payload,
    int payloadLen,
  ) {
    if (payload == nullptr || payloadLen <= 0) return;
    try {
      final bytes = Uint8List.fromList(payload.asTypedList(payloadLen));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) {
        _events.add(decoded);
      }
    } on Object catch (err) {
      _events.add({
        'seq': 0,
        'type': 'error',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'data': {
          'code': 'INVALID_ARG',
          'message': '事件解析失败: $err',
          'retryable': false,
        },
      });
    }
  }

  /// 已分配的最大事件序号，便于应用持久化水位。
  int get lastEventSeq => _lastSeq();

  /// 热重启后重放 seq 严格大于 [since] 的事件；缺口无法补齐时
  /// 首条为 `resync_required`（seq=0），应用应先做全量重新同步。
  List<Map<String, dynamic>> replaySince(int since) {
    final outPtr = _allocatePointer();
    final outLenPtr = _allocateInt32();
    try {
      final ret = _replay(since, outPtr, outLenPtr);
      if (ret != 0) {
        throw NexmemException('INVALID_ARG', 'nexmem_replay_events 返回 $ret');
      }
      final out = outPtr.value;
      final outLen = outLenPtr.value;
      if (out == nullptr || outLen <= 0) {
        return const <Map<String, dynamic>>[];
      }
      try {
        final bytes = Uint8List.fromList(out.asTypedList(outLen));
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! List) {
          return const <Map<String, dynamic>>[];
        }
        return decoded
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> e) => e.cast<String, dynamic>())
            .toList(growable: false);
      } finally {
        _free(out);
      }
    } finally {
      malloc.free(outPtr);
      malloc.free(outLenPtr);
    }
  }

  /// 取消事件订阅并关闭流；内核本身由 core.stop 负责停止。
  void close() {
    if (_eventCallable != null) {
      _setEventCallback(nullptr);
      _eventCallable!.close();
      _eventCallable = null;
    }
    _events.close();
  }
}

Pointer<Uint8> _allocate(int size) => malloc.allocate<Uint8>(size);

Pointer<Pointer<Uint8>> _allocatePointer() =>
    malloc.allocate<Pointer<Uint8>>(1);

Pointer<Int32> _allocateInt32() => malloc.allocate<Int32>(1);
