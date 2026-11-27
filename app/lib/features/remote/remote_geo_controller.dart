// 自动归属地控制器：默认关闭，IP 库随程序内置，用户确认后在本机推断。
//
// 只补全空白的地区/坐标，不覆盖用户手动填写的值；推断结果只写入本机台账，
// 不会作为消息或信令字段发送给对端。

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ip_location.dart';
import 'remote_device_directory.dart';
import '../settings/settings_service.dart';

const String kAutoGeoSettingKey = 'device.auto_geo_enabled';

/// 可选的 ip2region xdb 更新地址；库已随程序内置，留空即可，只有显式刷新
/// 或内置资源不可用时才使用。
const String kIpDbUrlSettingKey = 'device.ip_db_url';

class RemoteGeoController extends ChangeNotifier {
  RemoteGeoController({
    required this.service,
    required this.settings,
    required this.directory,
  });

  final IpLocationService service;
  final SettingsService settings;
  final RemoteDeviceDirectory directory;

  bool enabled = false;
  bool loading = false;
  double progress = 0;
  String? error;

  /// 用户填写的镜像地址；为空时使用 [kIpLocationDbUrl]。
  String mirrorUrl = '';

  Future<void> load() async {
    try {
      final String? value = await settings.read(kAutoGeoSettingKey);
      enabled = value == 'true';
      mirrorUrl = await settings.read(kIpDbUrlSettingKey) ?? '';
    } on Object {
      enabled = false;
      mirrorUrl = '';
    }
    if (enabled) {
      await enrichAll();
    } else if (mounted) {
      notifyListeners();
    }
  }

  bool mounted = true;

  @override
  void dispose() {
    mounted = false;
    super.dispose();
  }

  Future<void> setEnabled(bool value) async {
    if (!value) {
      enabled = false;
      error = null;
      await _persist(false);
      _notify();
      return;
    }

    loading = true;
    progress = 0;
    error = null;
    _notify();
    try {
      await service.ensureLoaded(
        url: mirrorUrl.isEmpty ? null : mirrorUrl,
        onProgress: (int received, int total) {
          progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          _notify();
        },
      );
      enabled = true;
      await _persist(true);
      await enrichAll();
    } on Object catch (e) {
      error = '$e';
      enabled = false;
    } finally {
      loading = false;
      progress = 0;
      _notify();
    }
  }

  /// 保存用户填写的 IP 库镜像地址；仅允许 http(s)，防止注入本地文件协议。
  /// 返回 false 时 [error] 已更新，调用方应留在弹窗中让用户修正。
  Future<bool> setMirrorUrl(String value) async {
    final String trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      final Uri? uri = Uri.tryParse(trimmed);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        error = 'IP 库地址必须是 http(s) URL';
        _notify();
        return false;
      }
    }
    mirrorUrl = trimmed;
    try {
      await settings.write(kIpDbUrlSettingKey, trimmed);
    } on Object catch (e) {
      error = '$e';
      _notify();
      return false;
    }
    error = null;
    _notify();
    return true;
  }

  Future<void> _persist(bool value) async {
    try {
      await settings.write(kAutoGeoSettingKey, value ? 'true' : '');
    } on Object catch (e) {
      error = '$e';
    }
  }

  /// 为台账里已有 IP 但没填地区/坐标的设备补全。手动标注优先。
  Future<void> enrichAll() async {
    if (!enabled || !service.loaded) {
      return;
    }
    for (final RemoteDevice device in List<RemoteDevice>.from(directory.devices)) {
      if (device.ip.isEmpty ||
          (device.region.isNotEmpty && device.hasLocation)) {
        continue;
      }
      final IpRegion? region = service.lookup(device.ip);
      if (region == null) {
        continue;
      }
      await directory.update(
        device.peer,
        region: device.region.isEmpty ? region.displayName : null,
        latitude: device.latitude ?? region.latitude,
        longitude: device.longitude ?? region.longitude,
      );
    }
    _notify();
  }

  void _notify() {
    if (mounted) {
      notifyListeners();
    }
  }
}
