import '../../transport/transport.dart';

/// 内核诊断快照，对应 gateway 的 `diag.snapshot`。
///
/// 全部字段均为元数据：DHT 耗时、打洞结果与 S3 状态码，不含消息正文与凭证。
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.uptimeMs,
    required this.dhtLookups,
    required this.dhtErrors,
    required this.dhtP50Ms,
    required this.dhtP95Ms,
    this.holePunch = const <String, int>{},
    this.s3Status = const <String, int>{},
    this.logRecords = 0,
    this.logDropped = 0,
  });

  factory DiagnosticsSnapshot.fromJson(Map<String, dynamic> json) {
    return DiagnosticsSnapshot(
      uptimeMs: _toInt(json['uptime_ms']),
      dhtLookups: _toInt(json['dht_lookups']),
      dhtErrors: _toInt(json['dht_errors']),
      dhtP50Ms: _toDouble(json['dht_p50_ms']),
      dhtP95Ms: _toDouble(json['dht_p95_ms']),
      holePunch: _toCounts(json['holepunch']),
      s3Status: _toCounts(json['s3_status']),
      logRecords: _toInt(json['log_records']),
      logDropped: _toInt(json['log_dropped']),
    );
  }

  final int uptimeMs;
  final int dhtLookups;
  final int dhtErrors;
  final double dhtP50Ms;
  final double dhtP95Ms;

  /// `network/result` → 次数，例如 `quic/direct`。
  final Map<String, int> holePunch;

  /// `METHOD/status` → 次数，传输失败记为 `METHOD/io`。
  final Map<String, int> s3Status;

  final int logRecords;
  final int logDropped;

  /// 按打洞结果归并（direct / relayed / failed）。
  int holePunchCount(String result) {
    int total = 0;
    for (final MapEntry<String, int> entry in holePunch.entries) {
      if (entry.key.endsWith('/$result')) {
        total += entry.value;
      }
    }
    return total;
  }

  int get directCount => holePunchCount('direct');

  int get relayedCount => holePunchCount('relayed');

  int get failedCount => holePunchCount('failed');

  /// DHT 寻址摘要：无样本时给出明确提示，避免显示 0ms 误导。
  String get dhtLatencyText {
    if (dhtLookups == 0) {
      return '暂无样本';
    }
    return 'p50 ${dhtP50Ms.toStringAsFixed(1)}ms · p95 ${dhtP95Ms.toStringAsFixed(1)}ms';
  }

  /// 在线时长，按 `Xh Ym` / `Ym Zs` 展示。
  String get uptimeText {
    final Duration d = Duration(milliseconds: uptimeMs);
    final int hours = d.inHours;
    final int minutes = d.inMinutes % 60;
    final int seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}s';
  }

  /// 打洞结果摘要，例如 `直连 2 · 中继 1 · 失败 0`。
  String get holePunchText => '直连 $directCount · 中继 $relayedCount · 失败 $failedCount';

  /// S3 状态码摘要；无请求时明确提示。
  String get s3Text {
    if (s3Status.isEmpty) {
      return '暂无请求';
    }
    final List<String> parts = <String>[
      for (final MapEntry<String, int> entry in s3Status.entries) '${entry.key}×${entry.value}',
    ];
    parts.sort();
    return parts.join(' · ');
  }
}

/// 诊断服务：`core.start` 接入内核后由平台层注入。
abstract class DiagnosticsService {
  /// 拉取运行指标快照。
  Future<DiagnosticsSnapshot> snapshot();

  /// 导出脱敏诊断包，返回落盘绝对路径。
  ///
  /// 诊断包与备份包一样只传路径（方案 §6.8），内容由 Go 侧按字段名脱敏。
  Future<String> exportBundle();
}

/// 通过统一传输层调用 `diag.snapshot` / `diag.export`。
class TransportDiagnosticsService implements DiagnosticsService {
  TransportDiagnosticsService(this._transport, {required this.exportPath});

  final CoreTransport _transport;

  /// 平台层提供的诊断包绝对路径（Web 由网关落盘）。
  final String Function() exportPath;

  @override
  Future<DiagnosticsSnapshot> snapshot() async {
    return DiagnosticsSnapshot.fromJson(await _transport.call('diag.snapshot'));
  }

  @override
  Future<String> exportBundle() async {
    final Map<String, dynamic> data = await _transport.call(
      'diag.export',
      params: <String, dynamic>{'path': exportPath()},
    );
    final Object? path = data['path'];
    if (path is! String || path.isEmpty) {
      throw const NexmemException('INVALID_ARG', 'diag.export 未返回诊断包路径');
    }
    return path;
  }
}

/// 未接入内核时的占位实现：明确抛 `NOT_STARTED`，UI 不做静默失败。
class UnavailableDiagnosticsService implements DiagnosticsService {
  const UnavailableDiagnosticsService();

  @override
  Future<DiagnosticsSnapshot> snapshot() async {
    throw const NexmemException('NOT_STARTED', '诊断能力尚未接入内核');
  }

  @override
  Future<String> exportBundle() async {
    throw const NexmemException('NOT_STARTED', '诊断能力尚未接入内核');
  }
}

int _toInt(Object? value) => value is num ? value.toInt() : 0;

double _toDouble(Object? value) => value is num ? value.toDouble() : 0;

Map<String, int> _toCounts(Object? value) {
  if (value is! Map) {
    return const <String, int>{};
  }
  final Map<String, int> out = <String, int>{};
  value.forEach((Object? key, Object? v) {
    if (key is String && v is num) {
      out[key] = v.toInt();
    }
  });
  return out;
}

/// 一次 `core.ping` 连接自检的结果（P6-34）。
///
/// [pong] 表示内核确实应答；[serverTs] 是内核回包的 Unix 毫秒时间戳；
/// [roundTripMs] 是客户端测得的往返耗时（单调计时，不依赖两端时钟同步）。
class PingResult {
  const PingResult({
    required this.pong,
    required this.serverTs,
    required this.roundTripMs,
  });

  factory PingResult.fromJson(Map<String, dynamic> json, {int roundTripMs = 0}) {
    return PingResult(
      pong: json['pong'] == true,
      serverTs: _toInt(json['server_ts']),
      roundTripMs: roundTripMs,
    );
  }

  final bool pong;
  final int serverTs;
  final int roundTripMs;

  /// 面向用户的自检结论文案。
  String get summary {
    if (!pong) {
      return '内核未应答';
    }
    return '内核正常 · 往返 $roundTripMs ms';
  }
}

/// 内核连接自检服务，封装契约 `core.ping`（P6-34）。
///
/// `core.ping` 契约早有内核实现，但此前仅在网关测试中使用，UI 从未调用；
/// 本服务把它接成网络诊断页的「连接自检」，是只读探活、无副作用。
abstract class PingService {
  Future<PingResult> ping();
}

/// 经统一传输层调用 `core.ping`，用 [Stopwatch] 测往返耗时。
class TransportPingService implements PingService {
  const TransportPingService(this._transport);

  final CoreTransport _transport;

  @override
  Future<PingResult> ping() async {
    final Stopwatch watch = Stopwatch()..start();
    final Map<String, dynamic> data = await _transport.call('core.ping');
    watch.stop();
    return PingResult.fromJson(data, roundTripMs: watch.elapsedMilliseconds);
  }
}

/// 未接入内核时的占位实现：明确抛 `NOT_STARTED`。
class UnavailablePingService implements PingService {
  const UnavailablePingService();

  @override
  Future<PingResult> ping() async {
    throw const NexmemException('NOT_STARTED', '内核尚未接入，无法自检');
  }
}
