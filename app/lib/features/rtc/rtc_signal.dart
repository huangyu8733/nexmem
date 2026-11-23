// P6-28：RTC 信令载荷模型（工程方案 §3.6）。
//
// 内核 `rtc.sendSignal` / `rtc.signal` 只透传不透明字节（std base64），
// SDP / ICE 的结构由客户端约定。这里定义一份跨端一致的 JSON 线格式：
//
//   {"v":1,"type":"offer","sdp":"...","mid":"0","index":0}
//
// - `type` ∈ offer / answer / candidate，分别对应 SDP 提议、应答与 ICE 候选；
// - `sdp` 在 offer/answer 为完整 SDP 文本，在 candidate 为单条 candidate 值；
// - `mid` 为 candidate 所属的媒体标识，`index` 为候选序号（用于排序去重）；
// - `v` 为格式版本，收到未知版本时丢弃，避免新旧端误协商。
//
// 该模型不依赖任何平台插件，便于单元测试；载荷大小上限与内核 64 KiB 对齐。

import 'dart:convert';

/// 单条 RTC 信令载荷上限，与内核 `dm.MaxRTCSignalSize`（64 KiB）一致。
const int kMaxRtcSignalBytes = 64 * 1024;

/// 载荷格式版本；收到更高版本时按不兼容丢弃。
const int kRtcSignalVersion = 1;

/// 信令类型，与工程方案 §3.6 的 `{type: offer|answer|candidate}` 对应。
enum RtcSignalType {
  offer('offer'),
  answer('answer'),
  candidate('candidate');

  const RtcSignalType(this.wireValue);

  final String wireValue;

  static RtcSignalType? fromWire(String value) {
    for (final RtcSignalType t in RtcSignalType.values) {
      if (t.wireValue == value) {
        return t;
      }
    }
    return null;
  }
}

/// 一条结构化的 RTC 信令。
class RtcSignal {
  const RtcSignal({
    required this.type,
    required this.sdp,
    this.mid,
    this.index = 0,
  });

  final RtcSignalType type;
  final String sdp;
  final String? mid;
  final int index;

  /// 编码为内核透传的字节（std base64 由调用方处理）。
  ///
  /// 超过 [kMaxRtcSignalBytes] 抛出 [FormatException]，与内核拒绝超大载荷对齐。
  List<int> encode() {
    final Map<String, dynamic> json = <String, dynamic>{
      'v': kRtcSignalVersion,
      'type': type.wireValue,
      'sdp': sdp,
      if (mid != null) 'mid': mid,
      'index': index,
    };
    final List<int> bytes = utf8.encode(jsonEncode(json));
    if (bytes.isEmpty || bytes.length > kMaxRtcSignalBytes) {
      throw FormatException('RTC 信令载荷为空或超过 64 KiB');
    }
    return bytes;
  }

  /// 从内核透传的字节解码；格式非法、版本不兼容时抛出 [FormatException]。
  factory RtcSignal.decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > kMaxRtcSignalBytes) {
      throw const FormatException('RTC 信令载荷为空或超过 64 KiB');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('RTC 信令载荷不是合法 UTF-8 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('RTC 信令载荷不是 JSON 对象');
    }
    final Object? version = decoded['v'];
    if (version is! int || version < 1 || version > kRtcSignalVersion) {
      throw FormatException('RTC 信令版本不兼容: $version');
    }
    final Object? typeValue = decoded['type'];
    if (typeValue is! String) {
      throw const FormatException('RTC 信令缺少 type');
    }
    final RtcSignalType? type = RtcSignalType.fromWire(typeValue);
    if (type == null) {
      throw FormatException('未知 RTC 信令类型: $typeValue');
    }
    final Object? sdp = decoded['sdp'];
    if (sdp is! String || sdp.isEmpty) {
      throw const FormatException('RTC 信令缺少 sdp');
    }
    final Object? mid = decoded['mid'];
    final Object? index = decoded['index'];
    return RtcSignal(
      type: type,
      sdp: sdp,
      mid: mid is String ? mid : null,
      index: index is int ? index : 0,
    );
  }

  /// 编码为内核 `payload_b64` 参数（std base64）。
  String toPayloadB64() => base64.encode(encode());

  /// 从内核 `payload_b64` 字段解码。
  factory RtcSignal.fromPayloadB64(String payload) =>
      RtcSignal.decode(base64.decode(payload));

  @override
  String toString() =>
      'RtcSignal(type: ${type.wireValue}, mid: $mid, index: $index)';
}
