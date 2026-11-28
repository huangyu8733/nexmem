// 远程控制会话模型：角色、状态、权限、屏幕与网络统计。
//
// 这些类型只描述界面与状态机需要的快照，不依赖 flutter_webrtc 或平台插件，
// 便于用假实现做单元测试。真实媒体与输入层在 remote_media.dart / input 下。

/// 远控角色。
enum RemoteRole {
  controller('控制端'),
  host('被控端');

  const RemoteRole(this.label);
  final String label;
}

/// 远控会话状态。
enum RemoteState {
  idle('空闲'),
  outgoing('等待对方确认'),
  incoming('远控请求'),
  connecting('连接中'),
  active('远控中'),
  paused('已暂停'),
  reconnecting('重连中'),
  ended('已结束'),
  failed('失败');

  const RemoteState(this.label);
  final String label;
}

/// 可授权的远控能力。
enum RemotePermission {
  input('input', '控制键鼠'),
  clipboard('clipboard', '剪贴板'),
  file('file', '文件传输');

  const RemotePermission(this.wireValue, this.label);
  final String wireValue;
  final String label;

  static RemotePermission? fromWire(String value) {
    for (final RemotePermission p in RemotePermission.values) {
      if (p.wireValue == value) {
        return p;
      }
    }
    return null;
  }
}

/// 权限组合。
class RemotePermissions {
  const RemotePermissions({
    this.input = false,
    this.clipboard = false,
    this.file = false,
  });

  static const RemotePermissions none = RemotePermissions();
  static const RemotePermissions all =
      RemotePermissions(input: true, clipboard: true, file: true);

  final bool input;
  final bool clipboard;
  final bool file;

  bool allows(RemotePermission permission) => switch (permission) {
        RemotePermission.input => input,
        RemotePermission.clipboard => clipboard,
        RemotePermission.file => file,
      };

  Set<RemotePermission> get set => <RemotePermission>{
        if (input) RemotePermission.input,
        if (clipboard) RemotePermission.clipboard,
        if (file) RemotePermission.file,
      };

  factory RemotePermissions.fromSet(Iterable<RemotePermission> values) {
    final Set<RemotePermission> set = values.toSet();
    return RemotePermissions(
      input: set.contains(RemotePermission.input),
      clipboard: set.contains(RemotePermission.clipboard),
      file: set.contains(RemotePermission.file),
    );
  }

  factory RemotePermissions.fromJson(Object? json) {
    if (json is! Map) {
      return none;
    }
    final Object? raw = json['caps'];
    if (raw is! List) {
      return none;
    }
    return RemotePermissions.fromSet(raw
        .whereType<String>()
        .map(RemotePermission.fromWire)
        .whereType<RemotePermission>());
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'caps': <String>[
          for (final RemotePermission p in set) p.wireValue,
        ],
      };

  RemotePermissions copyWith({bool? input, bool? clipboard, bool? file}) =>
      RemotePermissions(
        input: input ?? this.input,
        clipboard: clipboard ?? this.clipboard,
        file: file ?? this.file,
      );

  @override
  String toString() =>
      'RemotePermissions(input: $input, clipboard: $clipboard, file: $file)';
}

/// 画质档位。
enum RemoteQuality {
  smooth('流畅', 900 * 1000, 15),
  balanced('均衡', 2 * 1000 * 1000, 24),
  sharp('清晰', 4 * 1000 * 1000, 30);

  const RemoteQuality(this.label, this.maxBitrate, this.maxFps);
  final String label;
  final int maxBitrate;
  final int maxFps;
}

/// 一帧被控端屏幕的几何信息。
class RemoteDisplay {
  const RemoteDisplay({
    required this.id,
    required this.name,
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
    this.scale = 1,
    this.primary = false,
  });

  /// flutter_webrtc 屏幕源 ID，切屏时原样回传。
  final String id;
  final String name;

  /// 与采集源顺序一致的索引，用于输入坐标定位。
  final int index;

  /// 全局桌面坐标（逻辑点）。
  final int x;
  final int y;
  final int width;
  final int height;

  /// 物理像素尺寸，用于展示与画质估算。
  final int pixelWidth;
  final int pixelHeight;

  /// 物理像素 / 逻辑点。
  final double scale;
  final bool primary;

  factory RemoteDisplay.fromJson(Map<String, dynamic> json) => RemoteDisplay(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        index: (json['index'] as num?)?.toInt() ?? 0,
        x: (json['x'] as num?)?.toInt() ?? 0,
        y: (json['y'] as num?)?.toInt() ?? 0,
        width: (json['w'] as num?)?.toInt() ?? 0,
        height: (json['h'] as num?)?.toInt() ?? 0,
        pixelWidth: (json['pw'] as num?)?.toInt() ?? 0,
        pixelHeight: (json['ph'] as num?)?.toInt() ?? 0,
        scale: (json['scale'] as num?)?.toDouble() ?? 1,
        primary: json['primary'] == true,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'index': index,
        'x': x,
        'y': y,
        'w': width,
        'h': height,
        'pw': pixelWidth,
        'ph': pixelHeight,
        'scale': scale,
        'primary': primary,
      };

  @override
  String toString() => 'RemoteDisplay($index: $name ${width}x$height)';
}

/// 传输质量快照。
class RemoteNetworkStats {
  const RemoteNetworkStats({
    this.fps = 0,
    this.bitrateKbps = 0,
    this.rttMs = 0,
    this.packetLoss = 0,
    this.width = 0,
    this.height = 0,
  });

  static const RemoteNetworkStats zero = RemoteNetworkStats();

  final double fps;
  final int bitrateKbps;
  final int rttMs;

  /// 0..1 的丢包比例。
  final double packetLoss;
  final int width;
  final int height;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fps': fps,
        'kbps': bitrateKbps,
        'rtt': rttMs,
        'loss': packetLoss,
        'w': width,
        'h': height,
      };

  factory RemoteNetworkStats.fromJson(Map<String, dynamic> json) =>
      RemoteNetworkStats(
        fps: (json['fps'] as num?)?.toDouble() ?? 0,
        bitrateKbps: (json['kbps'] as num?)?.toInt() ?? 0,
        rttMs: (json['rtt'] as num?)?.toInt() ?? 0,
        packetLoss: (json['loss'] as num?)?.toDouble() ?? 0,
        width: (json['w'] as num?)?.toInt() ?? 0,
        height: (json['h'] as num?)?.toInt() ?? 0,
      );
}

/// 当前远控会话快照，供界面渲染。
class RemoteInfo {
  const RemoteInfo({
    required this.sid,
    required this.peer,
    required this.role,
    required this.state,
    this.peerName = '',
    this.requested = RemotePermissions.all,
    this.permissions = RemotePermissions.none,
    this.displays = const <RemoteDisplay>[],
    this.display,
    this.quality = RemoteQuality.balanced,
    this.stats = RemoteNetworkStats.zero,
    this.error = '',
    this.startedAtMs = 0,
    this.fileProgress = 0,
    this.fileTotal = 0,
    this.fileName = '',
    this.silent = false,
  });

  final String sid;
  final String peer;
  final String peerName;
  final RemoteRole role;
  final RemoteState state;

  /// 控制端请求的权限集合（被控端弹窗据此展示勾选项）。
  final RemotePermissions requested;

  /// 已授权的权限集合。
  final RemotePermissions permissions;

  final List<RemoteDisplay> displays;
  final RemoteDisplay? display;
  final RemoteQuality quality;
  final RemoteNetworkStats stats;
  final String error;
  final int startedAtMs;

  /// 文件传输进度（字节）；无传输时为 0。
  final int fileProgress;
  final int fileTotal;
  final String fileName;

  /// 是否为台账密码的静默远控（区别于聊天框发起、需对方同意的远控）。
  /// 关闭「允许被远程控制」只终止静默会话，不影响聊天框远控。
  final bool silent;

  bool get isHost => role == RemoteRole.host;
  bool get isController => role == RemoteRole.controller;
  bool get isIncoming => state == RemoteState.incoming;
  bool get isActive =>
      state == RemoteState.active ||
      state == RemoteState.paused ||
      state == RemoteState.reconnecting;
  bool get isTerminal =>
      state == RemoteState.ended || state == RemoteState.failed;

  RemoteInfo copyWith({
    String? peerName,
    RemoteState? state,
    RemotePermissions? requested,
    RemotePermissions? permissions,
    List<RemoteDisplay>? displays,
    RemoteDisplay? display,
    RemoteQuality? quality,
    RemoteNetworkStats? stats,
    String? error,
    int? startedAtMs,
    int? fileProgress,
    int? fileTotal,
    String? fileName,
    bool? silent,
  }) =>
      RemoteInfo(
        sid: sid,
        peer: peer,
        peerName: peerName ?? this.peerName,
        role: role,
        state: state ?? this.state,
        requested: requested ?? this.requested,
        permissions: permissions ?? this.permissions,
        displays: displays ?? this.displays,
        display: display ?? this.display,
        quality: quality ?? this.quality,
        stats: stats ?? this.stats,
        error: error ?? this.error,
        startedAtMs: startedAtMs ?? this.startedAtMs,
        fileProgress: fileProgress ?? this.fileProgress,
        fileTotal: fileTotal ?? this.fileTotal,
        fileName: fileName ?? this.fileName,
        silent: silent ?? this.silent,
      );

  @override
  String toString() =>
      'RemoteInfo($sid, $role, $state, peer: $peer, silent: $silent, caps: $permissions)';
}
