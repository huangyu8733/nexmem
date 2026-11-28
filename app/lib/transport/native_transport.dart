import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../app/core_session.dart';
import '../features/chat/voice_recorder.dart';
import '../features/files/directory_picker.dart';
import '../features/files/system_file_picker.dart';
import 'event_buffer.dart';
import 'event_sequencer.dart';
import 'transport.dart';

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
typedef _SetEventCallbackDart = void Function(
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

/// 桌面端传输实现（P1-09 / P1-10 / P1-20）：经 `dart:ffi` 直接调用 c-shared
/// 内核产物，与 Web 端共用同一套 Request/Response/Event 契约。
///
/// - 请求在独立 isolate 中执行，网络类调用不会阻塞 UI 线程；
/// - 事件由 Go 侧任意 goroutine 触发，经 `NativeCallable.listener` 回到主
///   isolate，再按 seq 去重/缺口判定后广播；
/// - 启动时把持久化水位作为 `since`，从内核环形缓冲重放热重启期间缺失的事件，
///   缺口无法补齐时下发 `resync_required`。
class NativeTransport implements CoreTransport {
  NativeTransport({
    String? libraryPath,
    this.requestTimeout = const Duration(seconds: 20),
    this.seqStore,
    int eventBufferSize = 512,
  }) : _libraryPath = libraryPath ?? defaultLibraryPath(),
       _buffer = EventBuffer(capacity: eventBufferSize) {
    _lib = DynamicLibrary.open(_libraryPath);
    _setEventCallback = _lib
        .lookupFunction<_SetEventCallbackNative, _SetEventCallbackDart>(
          'nexmem_set_event_cb',
        );
    _replayNative = _lib.lookupFunction<_ReplayNative, _ReplayDart>(
      'nexmem_replay_events',
    );
    _lastSeqNative = _lib.lookupFunction<_LastSeqNative, _LastSeqDart>(
      'nexmem_last_event_seq',
    );
    _freeNative = _lib.lookupFunction<_FreeNative, _FreeDart>('nexmem_free');
  }

  /// 单次请求的默认超时。
  final Duration requestTimeout;

  /// 事件水位持久化；桌面端用文件保存，热重启后作为 `since` 重放。
  final EventSeqStore? seqStore;

  final String _libraryPath;
  final EventBuffer _buffer;
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast();

  late final DynamicLibrary _lib;
  late final _SetEventCallbackDart _setEventCallback;
  late final _ReplayDart _replayNative;
  late final _LastSeqDart _lastSeqNative;
  late final _FreeDart _freeNative;

  NativeCallable<_EventCallbackNative>? _eventCallable;
  int _nextId = 0;
  bool _ready = false;
  bool _closed = false;

  /// 内核动态库路径；便于诊断日志输出。
  String get libraryPath => _libraryPath;

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  int get lastSeq => _buffer.lastSeq;

  /// 建立事件通道并从内核环形缓冲补齐缺失事件；重复调用幂等。
  Future<void> connect() async {
    if (_closed) {
      throw const NexmemException('NOT_STARTED', '传输已关闭，无法连接');
    }
    if (_ready) {
      return;
    }
    // 只有内核仍持有该 seq 空间（hot restart）时才沿用持久化水位；
    // 进程重启后内核 seq 从 1 重新计数，沿用旧水位只会得到一次无意义的 resync。
    final int? persisted = seqStore?.load();
    if (persisted != null &&
        persisted > _buffer.lastSeq &&
        _lastSeqNative() >= persisted) {
      _buffer.reset(lastSeq: persisted);
    }
    final callable = NativeCallable<_EventCallbackNative>.listener(_onEvent);
    _eventCallable = callable;
    _setEventCallback(callable.nativeFunction);
    _ready = true;
    for (final Map<String, dynamic> frame in _replayFrame(_buffer.lastSeq)) {
      _deliver(frame);
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    if (_closed) {
      throw const NexmemException('NOT_STARTED', '传输已关闭');
    }
    if (!_ready) {
      throw const NexmemException(
        'NOT_ONLINE',
        '本地内核事件通道尚未就绪',
        retryable: true,
      );
    }
    final Duration limit = timeout ?? requestTimeout;
    final int id = ++_nextId;
    final String request = jsonEncode(
      encodeRequestEnvelope(
        id: id,
        method: method,
        params: params,
        timeoutMs: limit.inMilliseconds,
      ),
    );
    // 只捕获可跨 isolate 传递的字符串，避免把本对象发送到工作 isolate。
    final String libraryPath = _libraryPath;
    final Map<String, dynamic> envelope;
    try {
      envelope = await Isolate.run(() => _invokeNative(libraryPath, request))
          .timeout(
            limit,
            onTimeout: () => _errorEnvelope(
              'NOT_ONLINE',
              '请求 $method 超时（${limit.inMilliseconds}ms）',
              retryable: true,
            ),
          );
    } on Object catch (error) {
      throw NexmemException(
        'NOT_ONLINE',
        '调用 $method 失败: $error',
        retryable: true,
      );
    }
    return decodeResponseEnvelope(envelope);
  }

  /// 从内核环形缓冲读取 seq 严格大于 [since] 的事件；返回 null 表示缺口无法
  /// 补齐，调用方应做全量重新同步。`since == 0` 视为全新客户端，不重放历史。
  List<CoreEvent>? replaySince(int since) {
    final List<Map<String, dynamic>> frames = _replayFrame(since);
    final List<CoreEvent> out = <CoreEvent>[];
    for (final Map<String, dynamic> frame in frames) {
      try {
        final CoreEvent event = CoreEvent.fromJson(frame);
        if (event.isResync) {
          return null;
        }
        out.add(event);
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _ready = false;
    final NativeCallable<_EventCallbackNative>? callable = _eventCallable;
    _eventCallable = null;
    if (callable != null) {
      try {
        _setEventCallback(nullptr);
      } on Object {
        // 内核可能已退出，注销失败不影响进程收尾。
      }
      callable.close();
    }
    await _events.close();
  }

  /// 事件回调运行在主 isolate（NativeCallable.listener 语义）。
  ///
  /// Go 侧缓冲所有权已随回调移交，解析完成后必须经 `nexmem_free` 释放，
  /// 否则每条事件都会泄漏。
  void _onEvent(
    Pointer<Utf8> eventType,
    Pointer<Uint8> payload,
    int payloadLen,
  ) {
    try {
      if (payload == nullptr || payloadLen <= 0) {
        return;
      }
      final Object? decoded = jsonDecode(
        utf8.decode(payload.asTypedList(payloadLen)),
      );
      if (decoded is Map<String, dynamic>) {
        _deliver(decoded);
      }
    } on Object {
      // 解析失败不应影响内核线程，直接丢弃该帧。
    } finally {
      if (payload != nullptr) {
        _freeNative(payload);
      }
      if (eventType != nullptr) {
        _freeNative(eventType.cast<Uint8>());
      }
    }
  }

  void _deliver(Map<String, dynamic> json) {
    final CoreEvent event;
    try {
      event = CoreEvent.fromJson(json);
    } on FormatException {
      return;
    }
    if (event.isResync) {
      _events.add(event);
      return;
    }
    final int previous = _buffer.lastSeq;
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

  /// 读取 `nexmem_replay_events` 返回的事件帧数组。
  List<Map<String, dynamic>> _replayFrame(int since) {
    final Pointer<Pointer<Uint8>> out = malloc.allocate<Pointer<Uint8>>(1);
    final Pointer<Int32> outLen = malloc.allocate<Int32>(1);
    try {
      final int ret = _replayNative(since, out, outLen);
      if (ret != 0) {
        return const <Map<String, dynamic>>[];
      }
      final Pointer<Uint8> buf = out.value;
      final int length = outLen.value;
      if (buf == nullptr || length <= 0) {
        return const <Map<String, dynamic>>[];
      }
      try {
        final Object? decoded = jsonDecode(
          utf8.decode(buf.asTypedList(length)),
        );
        if (decoded is! List) {
          return const <Map<String, dynamic>>[];
        }
        return decoded
            .whereType<Map<dynamic, dynamic>>()
            .map((Map<dynamic, dynamic> e) => e.cast<String, dynamic>())
            .toList(growable: false);
      } on Object {
        return const <Map<String, dynamic>>[];
      } finally {
        _freeNative(buf);
      }
    } finally {
      malloc.free(out);
      malloc.free(outLen);
    }
  }
}

/// 桌面端文件水位存储：热重启后凭 `seq` 从内核环形缓冲重放事件。
class FileEventSeqStore implements EventSeqStore {
  FileEventSeqStore(this.path);

  /// 水位文件绝对路径。
  final String path;

  @override
  int? load() {
    try {
      final File file = File(path);
      if (!file.existsSync()) {
        return null;
      }
      return int.tryParse(file.readAsStringSync().trim());
    } on Object {
      return null;
    }
  }

  @override
  void save(int seq) {
    try {
      final File file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$seq', flush: true);
    } on Object {
      // 水位只用于重放优化，写入失败不影响正常收发。
    }
  }

  @override
  void clear() {
    try {
      final File file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on Object {
      // 忽略清理失败。
    }
  }
}

/// 解析桌面端动态库路径：`NEXMEM_LIB` 优先，其次可执行文件目录，
/// 最后回退到开发期仓库 `bin/` 产物。
String defaultLibraryPath() {
  final String? override = Platform.environment['NEXMEM_LIB'];
  if (override != null && override.isNotEmpty) {
    return override;
  }
  final String name = Platform.isWindows
      ? 'nexmem.dll'
      : Platform.isMacOS
      ? 'libnexmem.dylib'
      : 'libnexmem.so';
  final String sep = Platform.pathSeparator;
  final String exeDir = File(Platform.resolvedExecutable).parent.path;
  final List<String> candidates = <String>[
    if (exeDir.isNotEmpty) '$exeDir$sep$name',
    'bin$sep$name',
    <String>['..', '..', 'bin', name].join(sep),
    <String>['..', 'bin', name].join(sep),
  ];
  for (final String candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return name;
}

/// 默认数据目录：Windows `%APPDATA%\Nexmem`、macOS `~/Library/Application
/// Support/Nexmem`、Linux `$XDG_DATA_HOME/nexmem`。
String defaultDataDir() {
  final Map<String, String> env = Platform.environment;
  final String sep = Platform.pathSeparator;
  if (Platform.isWindows) {
    final String? base = env['APPDATA'] ?? env['USERPROFILE'];
    if (base != null && base.isNotEmpty) {
      return '$base${sep}Nexmem';
    }
  } else if (Platform.isMacOS) {
    final String? home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home/Library/Application Support/Nexmem';
    }
  } else {
    final String? xdg = env['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return '$xdg${sep}nexmem';
    }
    final String? home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home/.local/share/nexmem';
    }
  }
  return '${Directory.current.path}${sep}nexmem-data';
}

/// 构造桌面端 `core.start` 配置：数据目录、引导节点、索引服务与中继地址
/// 来自 `--dart-define=NEXMEM_*` 或同名环境变量。
Map<String, dynamic> nativeStartConfig() {
  const String dataDirDefine = String.fromEnvironment('NEXMEM_DATA_DIR');
  const String displayDefine = String.fromEnvironment('NEXMEM_DISPLAY_NAME');
  const String bootstrapsDefine = String.fromEnvironment('NEXMEM_BOOTSTRAPS');
  const String directoryDefine = String.fromEnvironment('NEXMEM_DIRECTORY_URL');
  const String relayAddrsDefine = String.fromEnvironment('NEXMEM_RELAY_ADDRS');
  const String mdnsDefine = String.fromEnvironment('NEXMEM_MDNS');
  const String publicDhtDefine = String.fromEnvironment('NEXMEM_PUBLIC_DHT');
  const String manualAddrsDefine = String.fromEnvironment(
    'NEXMEM_MANUAL_ADDRS',
  );
  final Map<String, String> env = Platform.environment;
  final String dataDir = _firstNotEmpty(<String?>[
    dataDirDefine,
    env['NEXMEM_DATA_DIR'],
    defaultDataDir(),
  ]);
  final String displayName = _firstNotEmpty(<String?>[
    displayDefine,
    env['NEXMEM_DISPLAY_NAME'],
  ]);
  final String bootstraps = _firstNotEmpty(<String?>[
    bootstrapsDefine,
    env['NEXMEM_BOOTSTRAPS'],
  ]);
  final String directoryUrl = _firstNotEmpty(<String?>[
    directoryDefine,
    env['NEXMEM_DIRECTORY_URL'],
  ]);
  final String relayAddrs = _firstNotEmpty(<String?>[
    relayAddrsDefine,
    env['NEXMEM_RELAY_ADDRS'],
  ]);
  final String mdns = _firstNotEmpty(<String?>[mdnsDefine, env['NEXMEM_MDNS']]);
  final String publicDht = _firstNotEmpty(<String?>[
    publicDhtDefine,
    env['NEXMEM_PUBLIC_DHT'],
  ]);
  final String manualAddrs = _firstNotEmpty(<String?>[
    manualAddrsDefine,
    env['NEXMEM_MANUAL_ADDRS'],
  ]);
  final List<String> bootstrapsList = _splitList(bootstraps);
  final List<String> relayList = _splitList(relayAddrs);
  final List<String> manualList = _splitList(manualAddrs);
  return <String, dynamic>{
    'data_dir': dataDir,
    if (displayName.isNotEmpty) 'display_name': displayName,
    if (bootstrapsList.isNotEmpty) 'bootstraps': bootstrapsList,
    if (directoryUrl.isNotEmpty) 'directory_url': directoryUrl,
    if (relayList.isNotEmpty) 'relay_addrs': relayList,
    if (mdns.isNotEmpty) 'enable_mdns': mdns == 'true',
    if (publicDht.isNotEmpty) 'public_dht': publicDht == 'true',
    if (manualList.isNotEmpty) 'manual_addrs': manualList,
  };
}

/// 桌面端启动入口：动态库缺失时返回 null，应用以离线空态启动。
CoreSession? openNativeSession() {
  final Map<String, dynamic> config = nativeStartConfig();
  final String dataDir = config['data_dir'] as String;
  final NativeTransport transport;
  try {
    transport = NativeTransport(
      seqStore: FileEventSeqStore('$dataDir${Platform.pathSeparator}event_seq'),
    );
  } on Object catch (error) {
    debugPrint('Nexmem 本地内核不可用（$error）');
    return null;
  }
  unawaited(
    transport.connect().catchError((Object error) {
      debugPrint('Nexmem 内核事件通道连接失败：$error');
    }),
  );
  return CoreSession(
    transport,
    startConfig: config,
    pickFile: pickLocalFile,
    pickImage: pickLocalImage,
    pickMedia: pickLocalMedia,
    voiceRecorder: makeVoiceRecorder(),
    pickDirectory: pickShareDirectory,
  );
}

String _firstNotEmpty(List<String?> values) {
  for (final String? value in values) {
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

List<String> _splitList(String raw) {
  return raw
      .split(',')
      .map((String item) => item.trim())
      .where((String item) => item.isNotEmpty)
      .toList(growable: false);
}

/// 在工作 isolate 中执行一次 `nexmem_call`，返回原始响应信封。
///
/// 每次调用独立打开动态库（同一进程内仅增加引用计数），请求缓冲与响应缓冲
/// 都在本函数内释放，避免逐请求泄漏。
Map<String, dynamic> _invokeNative(String libraryPath, String request) {
  final DynamicLibrary lib = DynamicLibrary.open(libraryPath);
  final _CallDart call = lib.lookupFunction<_CallNative, _CallDart>(
    'nexmem_call',
  );
  final _FreeDart free = lib.lookupFunction<_FreeNative, _FreeDart>(
    'nexmem_free',
  );
  final List<int> body = utf8.encode(request);
  final Pointer<Uint8> buffer = malloc.allocate<Uint8>(
    body.isEmpty ? 1 : body.length,
  );
  final Pointer<Pointer<Uint8>> out = malloc.allocate<Pointer<Uint8>>(1);
  final Pointer<Int32> outLen = malloc.allocate<Int32>(1);
  try {
    if (body.isNotEmpty) {
      buffer.asTypedList(body.length).setAll(0, body);
    }
    final int ret = call(buffer, body.length, out, outLen);
    if (ret != 0) {
      return _errorEnvelope('INVALID_ARG', 'nexmem_call 返回 $ret');
    }
    final Pointer<Uint8> resp = out.value;
    final int length = outLen.value;
    if (resp == nullptr || length <= 0) {
      return _errorEnvelope('INVALID_ARG', '内核未返回响应缓冲');
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(resp.asTypedList(length)));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return _errorEnvelope('INVALID_ARG', '内核响应不是对象');
    } finally {
      free(resp);
    }
  } finally {
    malloc.free(buffer);
    malloc.free(out);
    malloc.free(outLen);
  }
}

Map<String, dynamic> _errorEnvelope(
  String code,
  String message, {
  bool retryable = false,
}) {
  return <String, dynamic>{
    'ok': false,
    'error': <String, dynamic>{
      'code': code,
      'message': message,
      'retryable': retryable,
    },
  };
}
