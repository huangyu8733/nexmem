import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 一个本地账号档案：对应内核的一个 `data_dir`。
///
/// Nexmem 的密钥与消息随数据目录隔离，因此「多账号」在本机表现为多个档案；
/// 切换账号即 `core.stop` 后用该档案的 `data_dir` 重新 `core.start`。
@immutable
class AccountProfile {
  const AccountProfile({
    required this.id,
    required this.label,
    this.dataDir = '',
    this.accountId = '',
    this.managed = false,
    this.createdAt = 0,
    this.lastUsedAt = 0,
  });

  factory AccountProfile.fromJson(Map<String, dynamic> json) {
    return AccountProfile(
      id: _string(json['id']),
      label: _string(json['label'], fallback: '账号'),
      dataDir: _string(json['data_dir']),
      accountId: _string(json['account_id']),
      managed: json['managed'] == true,
      createdAt: _int(json['created_at']),
      lastUsedAt: _int(json['last_used_at']),
    );
  }

  /// 档案 ID；默认档案固定为 `default`，其余由管理器生成。
  final String id;

  /// 用户可修改的展示名。
  final String label;

  /// 内核数据目录。为空表示沿用服务端/启动参数里的当前目录。
  final String dataDir;

  /// 内核 `account.me` 返回的账号 ID，内核就绪后回填。
  final String accountId;

  /// 是否由「添加账号」创建：只有这类档案允许被删除。
  final bool managed;

  final int createdAt;
  final int lastUsedAt;

  bool get isDefault => id == 'default';

  /// 列表标题：账号 ID 就绪时优先显示，否则回落档案名。
  String get displayName => accountId.isNotEmpty ? label : label;

  AccountProfile copyWith({
    String? label,
    String? dataDir,
    String? accountId,
    bool? managed,
    int? lastUsedAt,
  }) {
    return AccountProfile(
      id: id,
      label: label ?? this.label,
      dataDir: dataDir ?? this.dataDir,
      accountId: accountId ?? this.accountId,
      managed: managed ?? this.managed,
      createdAt: createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'data_dir': dataDir,
        'account_id': accountId,
        'managed': managed,
        'created_at': createdAt,
        'last_used_at': lastUsedAt,
      };
}

/// 临时锁设置：PIN 以 `salt$sha256(salt:pin)` 保存，不明文落盘。
@immutable
class LockSettings {
  const LockSettings({
    this.enabled = false,
    this.salt = '',
    this.pinHash = '',
    this.autoLockMinutes = 0,
  });

  factory LockSettings.fromJson(Map<String, dynamic> json) {
    return LockSettings(
      enabled: json['enabled'] == true,
      salt: _string(json['salt']),
      pinHash: _string(json['pin_hash']),
      autoLockMinutes: _int(json['auto_lock_minutes']),
    );
  }

  final bool enabled;
  final String salt;
  final String pinHash;

  /// 空闲多少分钟后自动锁定；0 表示关闭自动锁。
  final int autoLockMinutes;

  bool get hasPin => salt.isNotEmpty && pinHash.isNotEmpty;

  LockSettings copyWith({
    bool? enabled,
    String? salt,
    String? pinHash,
    int? autoLockMinutes,
  }) {
    return LockSettings(
      enabled: enabled ?? this.enabled,
      salt: salt ?? this.salt,
      pinHash: pinHash ?? this.pinHash,
      autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'salt': salt,
        'pin_hash': pinHash,
        'auto_lock_minutes': autoLockMinutes,
      };
}

/// 账号档案 + 临时锁设置的持久化快照。
@immutable
class AccountSessionState {
  const AccountSessionState({
    this.activeId = '',
    this.profiles = const <AccountProfile>[],
    this.lock = const LockSettings(),
  });

  factory AccountSessionState.fromJson(Map<String, dynamic> json) {
    final Object? rawProfiles = json['profiles'];
    final List<AccountProfile> profiles = rawProfiles is List
        ? rawProfiles
            .whereType<Map<String, dynamic>>()
            .map(AccountProfile.fromJson)
            .where((AccountProfile profile) => profile.id.isNotEmpty)
            .toList(growable: false)
        : const <AccountProfile>[];
    final Object? rawLock = json['lock'];
    return AccountSessionState(
      activeId: _string(json['active_id']),
      profiles: profiles,
      lock: rawLock is Map<String, dynamic>
          ? LockSettings.fromJson(rawLock)
          : const LockSettings(),
    );
  }

  final String activeId;
  final List<AccountProfile> profiles;
  final LockSettings lock;

  AccountProfile? profile(String id) {
    for (final AccountProfile profile in profiles) {
      if (profile.id == id) {
        return profile;
      }
    }
    return null;
  }

  AccountSessionState copyWith({
    String? activeId,
    List<AccountProfile>? profiles,
    LockSettings? lock,
  }) {
    return AccountSessionState(
      activeId: activeId ?? this.activeId,
      profiles: profiles ?? this.profiles,
      lock: lock ?? this.lock,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'active_id': activeId,
        'profiles': profiles
            .map((AccountProfile profile) => profile.toJson())
            .toList(growable: false),
        'lock': lock.toJson(),
      };
}

/// 生成 PIN 的随机盐（16 字节十六进制）。
String newPinSalt() {
  final Random random = Random.secure();
  return List<int>.generate(
    16,
    (_) => random.nextInt(256),
    growable: false,
  ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// 计算 PIN 摘要，格式为 `salt$sha256(salt:pin)`。
String hashPin(String pin, String salt) {
  final List<int> bytes = utf8.encode('$salt:$pin');
  return '$salt\$${sha256.convert(bytes).toString()}';
}

/// 校验 PIN；摘要格式非法时返回 false。
bool verifyPin(String pin, String encoded) {
  final int separator = encoded.indexOf(r'$');
  if (separator <= 0 || separator == encoded.length - 1) {
    return false;
  }
  final String salt = encoded.substring(0, separator);
  final String expected = encoded.substring(separator + 1);
  final String actual = hashPin(pin, salt).split(r'$').last;
  if (actual.length != expected.length) {
    return false;
  }
  // 定长比较，避免按前缀提前返回。
  int diff = 0;
  for (int i = 0; i < actual.length; i++) {
    diff |= actual.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return diff == 0;
}

String _string(Object? value, {String fallback = ''}) =>
    value is String && value.isNotEmpty ? value : fallback;

int _int(Object? value) => value is int ? value : 0;
