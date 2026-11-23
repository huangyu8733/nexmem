import 'package:material_ui/material_ui.dart';

import '../../transport/transport.dart';

/// 本机键值设置（P6-15）：`settings.get` / `settings.set`。
///
/// 界面偏好（外观主题等）需要跨六端持久化；内核复用 `kv` 表落盘并随备份恢复，
/// 客户端只搬运 key/value，不引入插件型依赖（R-18）。
abstract class SettingsService {
  /// 读取设置；未设置时返回 null。
  Future<String?> read(String key);

  /// 写入设置；[value] 为空串时清除该键。
  Future<void> write(String key, String value);

  /// 导出本机设置快照为可跨设备搬运的校验文本（P6-41）。
  Future<SettingsSnapshot> exportSnapshot();

  /// 导入并合并另一设备的设置快照，冲突以导入值覆盖（P6-41）。
  Future<int> importSnapshot(String snapshot, {bool dryRun = false});
}

/// 设置快照导出结果（P6-41）：[snapshot] 为 `settings://v1/` 开头的文本。
class SettingsSnapshot {
  const SettingsSnapshot({required this.snapshot, required this.count});

  final String snapshot;
  final int count;
}

/// 外观主题设置键。
const String themeModeSettingKey = 'ui.theme_mode';

/// 设置值 → 主题模式；未知值返回 null（保持默认跟随系统）。
ThemeMode? themeModeFromSetting(String? value) {
  switch (value) {
    case 'system':
      return ThemeMode.system;
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return null;
  }
}

/// 主题模式 → 设置值。
String themeModeSettingValue(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

/// 通过 [CoreTransport] 调用内核设置契约。
class TransportSettingsService implements SettingsService {
  TransportSettingsService(this._transport);

  final CoreTransport _transport;

  @override
  Future<String?> read(String key) async {
    final Map<String, dynamic> data = await _transport.call(
      'settings.get',
      params: <String, dynamic>{'key': key},
    );
    if (data['found'] != true) {
      return null;
    }
    final Object? value = data['value'];
    return value is String ? value : null;
  }

  @override
  Future<void> write(String key, String value) async {
    await _transport.call(
      'settings.set',
      params: <String, dynamic>{'key': key, 'value': value},
    );
  }

  @override
  Future<SettingsSnapshot> exportSnapshot() async {
    final Map<String, dynamic> data = await _transport.call(
      'settings.exportSnapshot',
    );
    final Object? snapshot = data['snapshot'];
    final Object? count = data['count'];
    if (snapshot is! String || snapshot.isEmpty) {
      throw const FormatException('settings.exportSnapshot 缺少 snapshot');
    }
    return SettingsSnapshot(
      snapshot: snapshot,
      count: count is num ? count.toInt() : 0,
    );
  }

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) async {
    final Map<String, dynamic> data = await _transport.call(
      'settings.importSnapshot',
      params: <String, dynamic>{
        'snapshot': snapshot,
        'dry_run': dryRun,
      },
    );
    final Object? applied = data['applied'];
    return applied is num ? applied.toInt() : 0;
  }
}

/// 未接入内核时的占位实现：读写都返回 NOT_STARTED，界面退回默认值。
class UnavailableSettingsService implements SettingsService {
  const UnavailableSettingsService();

  static const NexmemException _error = NexmemException(
    'NOT_STARTED',
    '设置能力尚未接入内核',
  );

  @override
  Future<String?> read(String key) => Future<String?>.error(_error);

  @override
  Future<void> write(String key, String value) => Future<void>.error(_error);

  @override
  Future<SettingsSnapshot> exportSnapshot() => Future<SettingsSnapshot>.error(_error);

  @override
  Future<int> importSnapshot(String snapshot, {bool dryRun = false}) =>
      Future<int>.error(_error);
}
