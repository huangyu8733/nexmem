// 远程控制信令（复用内核 rtc.sendSignal / rtc.signal 的透传通道）。
//
// 与通话信令共用同一条链路，但顶层带 `"app":"rc"`，壳层据此分流到
// RemoteControlService，不会进入 CallService。载荷上限与内核一致（64 KiB）。
//
// 线格式示例：
//   {"v":1,"app":"rc","type":"request","sid":"r-...","name":"张三",
//    "caps":["input","clipboard","file"]}
//   {"v":1,"app":"rc","type":"accept","sid":"r-...","token":"...",
//    "caps":["input"],"displays":[{...}],"display":"1"}
// offer / answer / candidate 承载 WebRTC 协商，与通话的 RtcSignal 相同。

import 'dart:convert';

import 'remote_session.dart';

/// 单条远控信令上限，与 `dm.MaxRTCSignalSize` 对齐。
const int kMaxRemoteSignalBytes = 64 * 1024;

const int _kRemoteSignalVersion = 1;

/// 远控信令类型。
enum RemoteSignalType {
  request('request'),
  accept('accept'),
  reject('reject'),
  offer('offer'),
  answer('answer'),
  candidate('candidate'),
  end('end'),
  pause('pause'),
  resume('resume'),
  display('display'),
  quality('quality'),
  clipboard('clipboard'),
  fileOffer('fileOffer'),
  fileAccept('fileAccept'),
  fileReject('fileReject'),
  fileDone('fileDone'),
  stats('stats');

  const RemoteSignalType(this.wireValue);
  final String wireValue;

  static RemoteSignalType? fromWire(String value) {
    for (final RemoteSignalType t in RemoteSignalType.values) {
      if (t.wireValue == value) {
        return t;
      }
    }
    return null;
  }
}

/// 一条结构化远控信令。
class RemoteSignal {
  const RemoteSignal({
    required this.type,
    required this.sid,
    this.token = '',
    this.credential = '',
    this.silent = false,
    this.sdp = '',
    this.mid,
    this.index = 0,
    this.name = '',
    this.permissions = RemotePermissions.none,
    this.displays = const <RemoteDisplay>[],
    this.displayId = '',
    this.quality = '',
    this.text = '',
    this.reason = '',
    this.fileName = '',
    this.fileSize = 0,
    this.fileId = '',
    this.fileMime = '',
    this.stats,
  });

  final RemoteSignalType type;

  /// 会话标识，以 `r-` 开头。
  final String sid;

  /// 被控端在 accept 时签发，后续信令必须携带。
  final String token;

  /// request 携带的远控密码校验值；不是明文密码。
  final String credential;

  /// 台账设备 + 密码的静默远控；聊天发起的请求不带此标记，必须对方确认。
  final bool silent;

  /// offer / answer 的 SDP，或 candidate 的候选值。
  final String sdp;
  final String? mid;
  final int index;

  /// 请求端展示名。
  final String name;

  /// 请求或授权的权限集合。
  final RemotePermissions permissions;

  /// 被控端可用屏幕列表（accept 时下发）。
  final List<RemoteDisplay> displays;

  /// 当前选中的屏幕源 ID。
  final String displayId;

  /// 画质档位（smooth / balanced / sharp）。
  final String quality;

  /// 剪贴板文本、提示或文件描述。
  final String text;

  /// 拒绝/结束原因。
  final String reason;

  final String fileName;
  final int fileSize;
  final String fileId;
  final String fileMime;
  final RemoteNetworkStats? stats;

  /// 是否为本模块信令：仅解析顶层 app 字段，失败一律返回 false。
  static bool peekIsRemote(String payloadB64) {
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(base64.decode(payloadB64)),
      );
      return decoded is Map && decoded['app'] == 'rc';
    } on Object {
      return false;
    }
  }

  /// 编码为内核透传的字节。
  List<int> encode() {
    final Map<String, dynamic> json = <String, dynamic>{
      'v': _kRemoteSignalVersion,
      'app': 'rc',
      'type': type.wireValue,
      'sid': sid,
      if (token.isNotEmpty) 'token': token,
      if (credential.isNotEmpty) 'credential': credential,
      if (silent) 'silent': true,
      if (sdp.isNotEmpty) 'sdp': sdp,
      if (mid != null) 'mid': mid,
      if (index != 0) 'index': index,
      if (name.isNotEmpty) 'name': name,
      if (permissions.set.isNotEmpty) ...permissions.toJson(),
      if (displays.isNotEmpty)
        'displays': displays
            .map((RemoteDisplay d) => d.toJson())
            .toList(growable: false),
      if (displayId.isNotEmpty) 'display': displayId,
      if (quality.isNotEmpty) 'quality': quality,
      if (text.isNotEmpty) 'text': text,
      if (reason.isNotEmpty) 'reason': reason,
      if (fileName.isNotEmpty) 'file_name': fileName,
      if (fileSize != 0) 'file_size': fileSize,
      if (fileId.isNotEmpty) 'file_id': fileId,
      if (fileMime.isNotEmpty) 'file_mime': fileMime,
      if (stats != null) 'stats': stats!.toJson(),
    };
    final List<int> bytes = utf8.encode(jsonEncode(json));
    if (bytes.isEmpty || bytes.length > kMaxRemoteSignalBytes) {
      throw const FormatException('远控信令为空或超过 64 KiB');
    }
    return bytes;
  }

  String toPayloadB64() => base64.encode(encode());

  /// 从内核透传的 base64 载荷解码；非法或版本不兼容时抛 [FormatException]。
  factory RemoteSignal.fromPayloadB64(String payloadB64) {
    final List<int> bytes;
    try {
      bytes = base64.decode(payloadB64);
    } on FormatException {
      throw const FormatException('远控信令不是合法 base64');
    }
    if (bytes.isEmpty || bytes.length > kMaxRemoteSignalBytes) {
      throw const FormatException('远控信令为空或超过 64 KiB');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('远控信令不是合法 UTF-8 JSON');
    }
    if (decoded is! Map<String, dynamic> || decoded['app'] != 'rc') {
      throw const FormatException('不是远控信令');
    }
    final Object? version = decoded['v'];
    if (version is! int || version < 1 || version > _kRemoteSignalVersion) {
      throw FormatException('远控信令版本不兼容: $version');
    }
    final Object? rawType = decoded['type'];
    if (rawType is! String) {
      throw const FormatException('远控信令缺少 type');
    }
    final RemoteSignalType? type = RemoteSignalType.fromWire(rawType);
    if (type == null) {
      throw FormatException('未知远控信令类型: $rawType');
    }
    final Object? sid = decoded['sid'];
    if (sid is! String || sid.isEmpty || !sid.startsWith('r-')) {
      throw const FormatException('远控信令缺少合法 sid');
    }
    final Object? rawDisplays = decoded['displays'];
    final List<RemoteDisplay> displays = rawDisplays is List
        ? rawDisplays
            .whereType<Map<String, dynamic>>()
            .map(RemoteDisplay.fromJson)
            .toList(growable: false)
        : const <RemoteDisplay>[];
    final Object? rawStats = decoded['stats'];
    return RemoteSignal(
      type: type,
      sid: sid,
      token: _string(decoded['token']),
      credential: _string(decoded['credential']),
      silent: decoded['silent'] == true,
      sdp: _string(decoded['sdp']),
      mid: decoded['mid'] is String ? decoded['mid'] as String : null,
      index: (decoded['index'] as num?)?.toInt() ?? 0,
      name: _string(decoded['name']),
      permissions: RemotePermissions.fromJson(decoded),
      displays: displays,
      displayId: _string(decoded['display']),
      quality: _string(decoded['quality']),
      text: _string(decoded['text']),
      reason: _string(decoded['reason']),
      fileName: _string(decoded['file_name']),
      fileSize: (decoded['file_size'] as num?)?.toInt() ?? 0,
      fileId: _string(decoded['file_id']),
      fileMime: _string(decoded['file_mime']),
      stats: rawStats is Map<String, dynamic>
          ? RemoteNetworkStats.fromJson(rawStats)
          : null,
    );
  }

  static String _string(Object? value) => value is String ? value : '';

  @override
  String toString() => 'RemoteSignal(${type.wireValue}, sid: $sid)';
}
