// 远程设备目录：本机保存的远控设备（账号、别名、设备类型、备注）。
//
// 这里只保存「设备台账」和连接所需的账号 ID，不缓存按键、剪贴板或媒体内容。
// 在线/离线状态由壳层会话实时提供，不做持久化，避免把过期状态展示成在线。

import 'package:material_ui/material_ui.dart';

import 'remote_session.dart';
import 'remote_storage.dart';

/// 设备类型：群控按类型约束，因为不同平台的键鼠/修饰键语义不同
/// （如 macOS 的 Cmd 与 Windows/Linux 的 Ctrl），混合群控会错乱。
enum RemoteDeviceType {
  all('全部', Icons.apps),
  macos('macOS', Icons.laptop_mac),
  windows('Windows', Icons.laptop_windows),
  linux('Linux', Icons.computer),
  android('Android', Icons.android),
  ios('iOS', Icons.smartphone),
  web('Web', Icons.language),
  other('其他', Icons.devices_other);

  const RemoteDeviceType(this.label, this.icon);
  final String label;
  final IconData icon;

  static RemoteDeviceType? fromWire(String value) {
    for (final RemoteDeviceType t in RemoteDeviceType.values) {
      if (t.name == value) {
        return t;
      }
    }
    // 兼容旧版台账：旧场景分类已废弃，统一归入「其他」。
    switch (value) {
      case 'favorite':
      case 'work':
      case 'home':
      case 'category':
        return RemoteDeviceType.other;
      default:
        return null;
    }
  }

  /// 可用于给设备标注类型的选项（不含「全部」筛选器）。
  static const List<RemoteDeviceType> assignable = <RemoteDeviceType>[
    macos,
    windows,
    linux,
    android,
    ios,
    web,
    other,
  ];

  /// 该类型是否支持作为被控端接收键鼠输入。
  bool get supportsInput => switch (this) {
        macos || windows || linux || android || other => true,
        ios || web || all => false,
      };
}

/// 一台已保存的远程设备。
class RemoteDevice {
  const RemoteDevice({
    required this.peer,
    required this.name,
    this.type = RemoteDeviceType.other,
    this.note = '',
    this.addedAtMs = 0,
    this.lastConnectedMs = 0,
    this.region = '',
    this.latitude,
    this.longitude,
    this.ip = '',
    this.credential = '',
  });

  final String peer;
  final String name;
  final RemoteDeviceType type;
  final String note;
  final int addedAtMs;
  final int lastConnectedMs;

  /// 用户手动标注的地区与 GCJ-02 坐标。内核不会自动上传或推断位置。
  final String region;
  final double? latitude;
  final double? longitude;

  /// 发现设备时记录的连接 IP；仅用于本机离线归属地推断，不会随消息发送。
  final String ip;

  /// 远控密码校验值；只存 SHA-256，不存明文，发起远控时随信令发送。
  final String credential;

  /// 是否具备地图标注所需的完整坐标。
  bool get hasLocation =>
      latitude != null &&
      longitude != null &&
      latitude! >= -90 &&
      latitude! <= 90 &&
      longitude! >= -180 &&
      longitude! <= 180;

  RemoteDevice copyWith({
    String? name,
    RemoteDeviceType? type,
    String? note,
    int? lastConnectedMs,
    String? region,
    double? latitude,
    double? longitude,
    String? ip,
    String? credential,
    bool clearLocation = false,
  }) =>
      RemoteDevice(
        peer: peer,
        name: name ?? this.name,
        type: type ?? this.type,
        note: note ?? this.note,
        addedAtMs: addedAtMs,
        lastConnectedMs: lastConnectedMs ?? this.lastConnectedMs,
        region: region ?? this.region,
        latitude: clearLocation ? null : (latitude ?? this.latitude),
        longitude: clearLocation ? null : (longitude ?? this.longitude),
        ip: ip ?? this.ip,
        credential: credential ?? this.credential,
      );

  factory RemoteDevice.fromJson(Map<String, dynamic> json) => RemoteDevice(
        peer: '${json['peer'] ?? ''}',
        name: '${json['name'] ?? ''}',
        // 新键 type；旧台账用 category 存场景分类，按 fromWire 兼容到 other。
        type: RemoteDeviceType.fromWire(
              '${json['type'] ?? json['category'] ?? ''}',
            ) ??
            RemoteDeviceType.other,
        note: '${json['note'] ?? ''}',
        addedAtMs: (json['added'] as num?)?.toInt() ?? 0,
        lastConnectedMs: (json['last'] as num?)?.toInt() ?? 0,
        region: '${json['region'] ?? ''}',
        latitude: (json['lat'] as num?)?.toDouble(),
        longitude: (json['lng'] as num?)?.toDouble(),
        ip: '${json['ip'] ?? ''}',
        credential: '${json['credential'] ?? ''}',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'peer': peer,
        'name': name,
        'type': type.name,
        'note': note,
        'added': addedAtMs,
        'last': lastConnectedMs,
        'region': region,
        'lat': latitude,
        'lng': longitude,
        'ip': ip,
        'credential': credential,
      };
}

/// 设备台账的存储与增删改；写操作后立即落盘。
class RemoteDeviceDirectory {
  RemoteDeviceDirectory(this._storage);

  static const String _fileName = 'devices.json';

  final RemoteStorage _storage;
  final List<RemoteDevice> _devices = <RemoteDevice>[];

  List<RemoteDevice> get devices => List<RemoteDevice>.unmodifiable(_devices);

  Future<void> load() async {
    final Map<String, dynamic>? json = await _storage.readJson(_fileName);
    final Object? raw = json?['devices'];
    final List<RemoteDevice> loaded = <RemoteDevice>[];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map<String, dynamic>) {
          final RemoteDevice device = RemoteDevice.fromJson(item);
          if (device.peer.isNotEmpty) {
            loaded.add(device);
          }
        }
      }
    }
    _devices
      ..clear()
      ..addAll(loaded);
  }

  Future<void> _persist() => _storage.writeJson(
        _fileName,
        <String, dynamic>{
          'devices': <Map<String, dynamic>>[
            for (final RemoteDevice device in _devices) device.toJson(),
          ],
        },
      );

  bool contains(String peer) =>
      _devices.any((RemoteDevice device) => device.peer == peer);

  RemoteDevice? find(String peer) {
    for (final RemoteDevice device in _devices) {
      if (device.peer == peer) {
        return device;
      }
    }
    return null;
  }

  Future<RemoteDevice> add({
    required String peer,
    required String name,
    RemoteDeviceType type = RemoteDeviceType.other,
    String note = '',
    String region = '',
    double? latitude,
    double? longitude,
    String ip = '',
    String credential = '',
    int nowMs = 0,
  }) async {
    final String id = peer.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(peer, 'peer', '设备账号不能为空');
    }
    final RemoteDevice? existing = find(id);
    if (existing != null) {
      final RemoteDevice updated = existing.copyWith(
        name: name.trim().isEmpty ? existing.name : name.trim(),
        type: type,
        note: note.trim(),
        region: region.trim(),
        latitude: latitude,
        longitude: longitude,
        ip: ip,
        credential: credential.trim().isEmpty
            ? existing.credential
            : credential.trim(),
        clearLocation: latitude == null || longitude == null,
      );
      final int index = _devices.indexOf(existing);
      _devices[index] = updated;
      await _persist();
      return updated;
    }
    final RemoteDevice device = RemoteDevice(
      peer: id,
      name: name.trim().isEmpty ? id : name.trim(),
      type: type,
      note: note.trim(),
      addedAtMs: nowMs == 0 ? DateTime.now().millisecondsSinceEpoch : nowMs,
      region: region.trim(),
      latitude: latitude,
      longitude: longitude,
      ip: ip,
      credential: credential.trim(),
    );
    _devices.add(device);
    await _persist();
    return device;
  }

  Future<void> update(
    String peer, {
    String? name,
    RemoteDeviceType? type,
    String? note,
    int? lastConnectedMs,
    String? region,
    double? latitude,
    double? longitude,
    String? ip,
    String? credential,
    bool clearLocation = false,
  }) async {
    final int index = _devices.indexWhere(
      (RemoteDevice device) => device.peer == peer,
    );
    if (index < 0) {
      return;
    }
    _devices[index] = _devices[index].copyWith(
      name: name?.trim().isEmpty ?? false ? null : name,
      type: type,
      note: note,
      lastConnectedMs: lastConnectedMs,
      region: region,
      latitude: latitude,
      longitude: longitude,
      ip: ip,
      credential: credential?.trim().isEmpty ?? false ? null : credential,
      clearLocation: clearLocation,
    );
    await _persist();
  }

  Future<void> remove(String peer) async {
    _devices.removeWhere((RemoteDevice device) => device.peer == peer);
    await _persist();
  }

  /// 远控会话结束时由调用方回写「最近连接」时间；失败不影响台账。
  Future<void> markConnected(String peer, {int? nowMs}) async {
    await update(
      peer,
      lastConnectedMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// 设备目录项 + 实时会话状态，供 UI 直接渲染。
class RemoteDeviceView {
  const RemoteDeviceView({
    required this.device,
    this.info,
  });

  final RemoteDevice device;
  final RemoteInfo? info;

  bool get connected => info != null && info!.isActive;

  String get statusLabel {
    final RemoteInfo? session = info;
    if (session == null) {
      return '未连接';
    }
    if (session.isActive) {
      return session.state.label;
    }
    return session.state.label;
  }
}
