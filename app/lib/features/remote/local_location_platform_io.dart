// Android / iOS / 桌面实现。
//
// 原生宿主需实现 MethodChannel 'nexmem/location'：
//   isServiceEnabled   -> bool
//   checkPermission    -> String granted|denied|deniedForever|unableToDetermine|unsupported
//   requestPermission  -> String 同上
//   getCurrentPosition -> Map {latitude, longitude, accuracy}
// 宿主未接线时所有方法安全降级，不会阻断应用启动。

import 'package:flutter/services.dart';

import 'local_location_platform_types.dart';

class MethodChannelSystemLocation implements SystemLocationPlatform {
  const MethodChannelSystemLocation({this.channel = const MethodChannel('nexmem/location')});

  final MethodChannel channel;

  Future<T?> _call<T>(String method) async {
    try {
      return await channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> isServiceEnabled() async =>
      await _call<bool>('isServiceEnabled') ?? false;

  @override
  Future<SystemLocationPermission> checkPermission() async {
    final Object? raw = await _call<Object>('checkPermission');
    return parseSystemLocationPermission(raw);
  }

  @override
  Future<SystemLocationPermission> requestPermission() async {
    final Object? raw = await _call<Object>('requestPermission');
    return parseSystemLocationPermission(raw);
  }

  @override
  Future<SystemPosition> getCurrentPosition() async {
    final Map<Object?, Object?>? raw = await _call<Map<Object?, Object?>>(
      'getCurrentPosition',
    );
    if (raw == null) {
      throw const SystemLocationException.unsupported();
    }
    final double? lat = _number(raw['latitude']);
    final double? lng = _number(raw['longitude']);
    if (lat == null || lng == null) {
      throw const SystemLocationException('系统定位返回了无效坐标');
    }
    return SystemPosition(
      latitude: lat,
      longitude: lng,
      accuracy: _number(raw['accuracy']) ?? 0,
    );
  }

  static double? _number(Object? value) => switch (value) {
        final double v => v,
        final int v => v.toDouble(),
        final String v => double.tryParse(v),
        _ => null,
      };
}

SystemLocationPlatform makeSystemLocationPlatform() =>
    const MethodChannelSystemLocation();
