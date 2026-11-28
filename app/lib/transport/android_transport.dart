import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app/core_session.dart';
import '../features/chat/chat_message.dart';
import '../features/chat/voice_recorder.dart';
import 'event_buffer.dart';
import 'event_sequencer.dart';
import 'transport.dart';

/// Android 端传输实现（P1-07 / P1-10）。
///
/// 经 `io.nexmem/core` MethodChannel 调用 gomobile 内核，与桌面 `dart:ffi`、
/// Web WebSocket 共用同一套 Request/Response/Event 契约：
///
/// - `call` 只搬运请求/响应信封，业务语义全部在 Go 侧；
/// - 事件由 Kotlin 插件反向推到 `event` 方法，按 seq 去重并检测缺口；
/// - 原生 `EventRing` 保留最近事件，热重启后凭原生侧的已消费水位重放，
///   缺口无法补齐时下发 `resync_required`。
class AndroidTransport implements CoreTransport {
  AndroidTransport({
    MethodChannel? channel,
    this.requestTimeout = const Duration(seconds: 20),
    int eventBufferSize = 512,
    this.platformLabel = 'Android',
  }) : _channel = channel ?? const MethodChannel(channelName),
       _buffer = EventBuffer(capacity: eventBufferSize);

  /// 与 `NexmemPlugin.CHANNEL` 保持一致的通道名。
  static const String channelName = 'io.nexmem/core';

  /// 单次请求的默认超时。
  final Duration requestTimeout;

  /// 平台标签，仅用于日志与异常文案；iOS 复用同一通道实现（P1-08）。
  final String platformLabel;

  final MethodChannel _channel;
  final EventBuffer _buffer;
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast();

  int _nextId = 0;
  bool _ready = false;
  bool _closed = false;

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  int get lastSeq => _buffer.lastSeq;

  /// 建立事件通道并从原生环形缓冲补齐缺失事件；重复调用幂等。
  Future<void> connect() async {
    if (_closed) {
      throw const NexmemException('NOT_STARTED', '传输已关闭，无法连接');
    }
    if (_ready) {
      return;
    }
    _channel.setMethodCallHandler(_onMethodCall);
    int since = 0;
    try {
      since = await _channel.invokeMethod<int>('ackedSeq') ?? 0;
    } on PlatformException catch (error) {
      debugPrint('Nexmem 读取事件水位失败（${error.message}）');
    } on MissingPluginException {
      debugPrint('Nexmem $platformLabel 内核插件未注册，事件通道不可用');
    }
    // 原生侧水位来自上一次 Dart isolate 的消费进度；进程重启后内核 seq 同样
    // 从头计数，原生水位也会重置，因此这里不会出现无意义的缺口。
    if (since > 0) {
      _buffer.reset(lastSeq: since);
    }
    _ready = true;
    for (final Map<String, dynamic> frame in await _replay(since)) {
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
    final String request = jsonEncode(
      encodeRequestEnvelope(
        id: ++_nextId,
        method: method,
        params: params,
        timeoutMs: limit.inMilliseconds,
      ),
    );
    final String? raw;
    try {
      raw = await _channel
          .invokeMethod<String>('call', <String, dynamic>{'request': request})
          .timeout(limit);
    } on TimeoutException {
      throw NexmemException(
        'NOT_ONLINE',
        '请求 $method 超时（${limit.inMilliseconds}ms）',
        retryable: true,
      );
    } on PlatformException catch (error) {
      throw NexmemException(
        'NOT_ONLINE',
        '调用 $method 失败: ${error.message ?? error.code}',
        retryable: true,
      );
    } on MissingPluginException {
      throw NexmemException(
        'NOT_ONLINE',
        '$platformLabel 内核插件未注册',
        retryable: true,
      );
    }
    if (raw == null || raw.isEmpty) {
      throw NexmemException('NOT_ONLINE', '内核未返回 $method 响应', retryable: true);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const NexmemException('INVALID_ARG', '内核响应无法解析');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const NexmemException('INVALID_ARG', '内核响应不是对象');
    }
    return decodeResponseEnvelope(decoded);
  }

  /// 应用私有目录（`Context.filesDir`），作为 `core.start` 的 `data_dir`。
  Future<String?> appDataDir() async {
    try {
      return await _channel.invokeMethod<String>('dataDir');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 当前 Wi-Fi 局域网 IP，用于注入内核补全 mDNS 广播地址。
  /// Android 上 Go 的 net.Interfaces() 常被 SELinux 拦截，需原生层提供。
  Future<String?> localIp() async {
    try {
      return await _channel.invokeMethod<String>('localIp');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 局域网子网定向广播地址（如 192.168.10.255）。iOS 专用：系统禁止向
  /// 255.255.255.255 受限广播发送，必须由原生层提供定向广播地址。
  /// Android/桌面插件未实现该 channel 时返回 null，内核回退到受限广播。
  Future<String?> lanBroadcastAddr() async {
    try {
      return await _channel.invokeMethod<String>('lanBroadcastAddr');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 拉起系统文件选择器并返回本机副本（P2-08）。
  ///
  /// 原生侧把 `content://` 复制到应用缓存目录后回传绝对路径；用户取消返回 null。
  Future<ChatAttachment?> pickFile() => _pickViaPlatform('pickFile', '选择文件失败');

  /// 拉起系统相册/图片库（Android ACTION_PICK / iOS PHPicker）。
  /// 原生侧同样把结果复制到缓存目录后回传绝对路径。
  Future<ChatAttachment?> pickImage() =>
      _pickViaPlatform('pickImage', '选择图片失败');

  /// 拉起系统媒体选择器，可发送视频或音频文件。
  Future<ChatAttachment?> pickMedia() =>
      _pickViaPlatform('pickMedia', '选择音视频失败');

  Future<ChatAttachment?> _pickViaPlatform(
    String method,
    String errorLabel,
  ) async {
    try {
      final Map<String, dynamic>? picked = await _channel
          .invokeMapMethod<String, dynamic>(method);
      if (picked == null) {
        return null;
      }
      final Object? name = picked['name'];
      final Object? path = picked['path'];
      if (name is! String || path is! String || path.isEmpty) {
        return null;
      }
      final Object? mime = picked['mime'];
      return ChatAttachment(
        name: name,
        size: (picked['size'] as num?)?.toInt() ?? 0,
        mime: mime is String ? mime : '',
        path: path,
      );
    } on PlatformException catch (error) {
      throw NexmemException(
        'NOT_ONLINE',
        '$errorLabel: ${error.message ?? error.code}',
        retryable: true,
      );
    } on MissingPluginException {
      throw NexmemException(
        'NOT_ONLINE',
        '$platformLabel 图片/文件选择器未注册',
        retryable: true,
      );
    }
  }

  /// 拉起系统目录选择器并把 SAF 目录树复制到应用缓存，回传可读绝对路径。
  /// 用户取消或插件缺失时返回 null。
  Future<String?> pickDirectory() async {
    try {
      return await _channel.invokeMethod<String>('pickDirectory');
    } on PlatformException catch (error) {
      throw NexmemException(
        'NOT_ONLINE',
        '选择目录失败: ${error.message ?? error.code}',
        retryable: true,
      );
    } on MissingPluginException {
      return null;
    }
  }

  /// 拉起 Android 前台服务以尽量提升进程存活率（P6-01）。
  ///
  /// 这是尽力而为的降级设计：原生侧 startService 成功返回 true；插件缺失、权限
  /// 受限或 OEM 省电策略拦截时返回 false，内核调用不受影响。系统级保活（自启动、
  /// 电池优化白名单、厂商推送保活）依赖设备与用户设置，不作为本方法承诺。
  Future<bool> startForegroundService() async {
    try {
      await _channel.invokeMethod<Object?>('startService');
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 停止前台服务。
  Future<void> stopForegroundService() async {
    try {
      await _channel.invokeMethod<Object?>('stopService');
    } on Object {
      // 服务未启动或插件已卸载时忽略。
    }
  }

  /// 释放内核句柄；再次调用 [connect] 前需要重建传输。
  Future<void> shutdown() async {
    try {
      await _channel.invokeMethod<Object?>('shutdown');
    } on Object {
      // 内核可能已退出，忽略收尾失败。
    }
    _buffer.reset();
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _ready = false;
    _channel.setMethodCallHandler(null);
    await _events.close();
  }

  /// 原生侧事件回调（Kotlin 已切到主线程）。
  Future<Object?> _onMethodCall(MethodCall call) async {
    if (call.method != 'event') {
      return null;
    }
    final Object? payload = call.arguments;
    if (payload is! String || payload.isEmpty) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    if (decoded is Map<String, dynamic>) {
      _deliver(decoded);
    }
    return null;
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
        _persistAck();
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
        _persistAck();
    }
  }

  /// 把已消费水位回写原生侧，供下一次 Dart isolate（热重启）重放使用。
  void _persistAck() {
    final int seq = _buffer.lastSeq;
    unawaited(
      _channel
          .invokeMethod<Object?>('ack', <String, dynamic>{'seq': seq})
          .catchError((Object _) => null),
    );
  }

  /// 读取原生环形缓冲中 seq 大于 [since] 的事件帧。
  Future<List<Map<String, dynamic>>> _replay(int since) async {
    try {
      final String raw =
          await _channel.invokeMethod<String>('replaySince', <String, dynamic>{
            'since': since,
          }) ??
          '[]';
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <Map<String, dynamic>>[];
      }
      return decoded
          .whereType<Map<dynamic, dynamic>>()
          .map((Map<dynamic, dynamic> e) => e.cast<String, dynamic>())
          .toList(growable: false);
    } on Object catch (error) {
      debugPrint('Nexmem 事件重放失败（$error）');
      return const <Map<String, dynamic>>[];
    }
  }
}

/// Android 启动入口（P1-07）：建立 MethodChannel 会话并注入 `core.start` 配置。
///
/// 数据目录取 `Context.filesDir`，与桌面 `APPDATA` 等价的私有目录；
/// 插件缺失或目录不可用时返回 null，应用以离线空态启动。
Future<CoreSession?> openAndroidSession({
  Map<String, String>? environment,
}) async {
  final AndroidTransport transport = AndroidTransport();
  try {
    await transport.connect();
  } on Object catch (error) {
    debugPrint('Nexmem Android 内核事件通道连接失败（$error）');
    return null;
  }
  final String? dataDir = await transport.appDataDir();
  if (dataDir == null || dataDir.isEmpty) {
    debugPrint('Nexmem Android 内核数据目录不可用');
    await transport.close();
    return null;
  }
  // 读取原生局域网 IP 注入内核：Android 上 Go 的 net.Interfaces() 常被
  // SELinux 拦截，libp2p 无法展开 /ip4/0.0.0.0，mDNS 无从广播。
  final String? localIp = await transport.localIp();
  final Map<String, dynamic> config = androidStartConfig(
    dataDir,
    environment: environment,
  );
  if (localIp != null && localIp.isNotEmpty) {
    config['lan_addrs'] = <String>[localIp];
  }
  unawaited(transport.startForegroundService());
  return CoreSession(
    transport,
    startConfig: config,
    // 重装后 filesDir 可能变化，需重定位失效的账号数据目录。
    rebaseStaleDataDir: true,
    pickFile: transport.pickFile,
    pickImage: transport.pickImage,
    pickMedia: transport.pickMedia,
    voiceRecorder: makeVoiceRecorder(),
    pickDirectory: transport.pickDirectory,
  );
}

/// 构造 Android 端 `core.start` 配置。
///
/// 数据目录由原生侧提供；引导节点、索引服务与中继地址来自 `--dart-define`
/// 注入（也可用同名环境变量），便于本机/局域网联调或统一公网部署时把移动端
/// 指向自建的基础设施。未注入时保持空配置，行为与发布版一致（离线空态）。
Map<String, dynamic> androidStartConfig(
  String dataDir, {
  Map<String, String>? environment,
}) {
  const String bootstrapsDefine = String.fromEnvironment('NEXMEM_BOOTSTRAPS');
  const String directoryDefine = String.fromEnvironment('NEXMEM_DIRECTORY_URL');
  const String relayAddrsDefine = String.fromEnvironment('NEXMEM_RELAY_ADDRS');
  const String mdnsDefine = String.fromEnvironment('NEXMEM_MDNS');
  const String publicDhtDefine = String.fromEnvironment('NEXMEM_PUBLIC_DHT');
  const String manualAddrsDefine = String.fromEnvironment(
    'NEXMEM_MANUAL_ADDRS',
  );
  final Map<String, String> env = environment ?? Platform.environment;
  return androidCoreStartConfig(
    dataDir: dataDir,
    bootstraps: bootstrapsDefine.isNotEmpty
        ? bootstrapsDefine
        : (env['NEXMEM_BOOTSTRAPS'] ?? ''),
    directoryUrl: directoryDefine.isNotEmpty
        ? directoryDefine
        : (env['NEXMEM_DIRECTORY_URL'] ?? ''),
    relayAddrs: relayAddrsDefine.isNotEmpty
        ? relayAddrsDefine
        : (env['NEXMEM_RELAY_ADDRS'] ?? ''),
    mdns: mdnsDefine.isNotEmpty ? mdnsDefine : (env['NEXMEM_MDNS'] ?? ''),
    publicDht: publicDhtDefine.isNotEmpty
        ? publicDhtDefine
        : (env['NEXMEM_PUBLIC_DHT'] ?? ''),
    manualAddrs: manualAddrsDefine.isNotEmpty
        ? manualAddrsDefine
        : (env['NEXMEM_MANUAL_ADDRS'] ?? ''),
  );
}

/// 把注入的原始字符串规范化为 `core.start` 配置；抽成纯函数便于单测。
Map<String, dynamic> androidCoreStartConfig({
  required String dataDir,
  required String bootstraps,
  required String directoryUrl,
  required String relayAddrs,
  String mdns = '',
  String publicDht = '',
  String manualAddrs = '',
}) {
  final List<String> bootstrapsList = _splitCommaList(bootstraps);
  final List<String> relayList = _splitCommaList(relayAddrs);
  final List<String> manualList = _splitCommaList(manualAddrs);
  final String directory = directoryUrl.trim();
  return <String, dynamic>{
    'data_dir': dataDir,
    if (bootstrapsList.isNotEmpty) 'bootstraps': bootstrapsList,
    if (directory.isNotEmpty) 'directory_url': directory,
    if (relayList.isNotEmpty) 'relay_addrs': relayList,
    if (mdns.trim().isNotEmpty) 'enable_mdns': mdns.trim() == 'true',
    if (publicDht.trim().isNotEmpty) 'public_dht': publicDht.trim() == 'true',
    if (manualList.isNotEmpty) 'manual_addrs': manualList,
  };
}

List<String> _splitCommaList(String raw) {
  return raw
      .split(',')
      .map((String item) => item.trim())
      .where((String item) => item.isNotEmpty)
      .toList(growable: false);
}
