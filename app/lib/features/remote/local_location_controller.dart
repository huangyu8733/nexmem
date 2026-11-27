// 本机位置：默认空；移动端由用户主动授权系统定位后保存，桌面端保留手工调试入口。
//
// 位置只保存在本机设置 KV，不随消息/信令发送给对端，只用于估算「发现设备」与
// 本机的近似距离。系统定位返回 WGS84，转换到 GCJ-02 后与设备台账/IP 库对齐。

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import '../settings/settings_service.dart';
import 'device_distance.dart';
import 'local_location_platform.dart';

const String kLocalLatitudeSettingKey = 'device.local_latitude';
const String kLocalLongitudeSettingKey = 'device.local_longitude';

/// 这些 error 值本身就是翻译 key，其余按「设置失败：{0}」兜底展示。
const Set<String> kLocalLocationErrorKeys = <String>{
  '定位服务未开启，请先开启系统定位',
  '定位权限被拒绝，请在系统设置中允许位置权限',
  '当前设备不支持系统定位',
};

String _localizedLocalLocationError(BuildContext context, String raw) =>
    kLocalLocationErrorKeys.contains(raw)
        ? context.t(raw)
        : context.t('本机位置设置失败：{0}', [raw]);

class LocalLocationController extends ChangeNotifier {
  LocalLocationController({required this.settings});

  final SettingsService settings;

  double? latitude;
  double? longitude;
  bool loaded = false;
  String? error;

  bool get hasLocation => isValidCoordinate(latitude, longitude);

  Future<void> load() async {
    try {
      final String? latText = await settings.read(kLocalLatitudeSettingKey);
      final String? lngText = await settings.read(kLocalLongitudeSettingKey);
      final double? lat = double.tryParse(latText ?? '');
      final double? lng = double.tryParse(lngText ?? '');
      if (isValidCoordinate(lat, lng)) {
        latitude = lat;
        longitude = lng;
      } else {
        latitude = null;
        longitude = null;
      }
    } on Object {
      latitude = null;
      longitude = null;
    }
    loaded = true;
    _notify();
  }

  /// 移动端通过系统定位获取当前位置；失败时 [error] 为可直接交给 context.t 的 key。
  /// 原生通道未接线时 [SystemLocationPlatform] 会安全降级，不会阻断定位弹窗。
  Future<bool> useSystemLocation() async {
    error = null;
    lastAccuracyMeters = null;
    _notify();
    final SystemLocationPlatform platform = makeSystemLocationPlatform();
    if (!await platform.isServiceEnabled()) {
      error = '定位服务未开启，请先开启系统定位';
      _notify();
      return false;
    }
    SystemLocationPermission permission = await platform.checkPermission();
    if (permission == SystemLocationPermission.denied ||
        permission == SystemLocationPermission.unableToDetermine) {
      permission = await platform.requestPermission();
    }
    if (permission == SystemLocationPermission.unsupported) {
      error = '当前设备不支持系统定位';
      _notify();
      return false;
    }
    if (permission != SystemLocationPermission.granted) {
      error = '定位权限被拒绝，请在系统设置中允许位置权限';
      _notify();
      return false;
    }
    try {
      final SystemPosition position = await platform.getCurrentPosition();
      final ({double latitude, double longitude}) gcj =
          wgs84ToGcj02(position.latitude, position.longitude);
      final bool saved = await save(gcj.latitude, gcj.longitude);
      if (saved) {
        lastAccuracyMeters = position.accuracy;
      }
      return saved;
    } on Object catch (e) {
      error = '$e';
      _notify();
      return false;
    }
  }

  /// 最近一次系统定位的精度（米）；手工输入时为 null。
  double? lastAccuracyMeters;

  /// 两个坐标同时为 null 表示清除；只填一个视为非法。
  Future<bool> save(double? latitudeValue, double? longitudeValue) async {
    if (latitudeValue == null || longitudeValue == null) {
      if (latitudeValue != null || longitudeValue != null) {
        return false;
      }
    } else if (!isValidCoordinate(latitudeValue, longitudeValue)) {
      return false;
    }
    try {
      await settings.write(
        kLocalLatitudeSettingKey,
        latitudeValue?.toString() ?? '',
      );
      await settings.write(
        kLocalLongitudeSettingKey,
        longitudeValue?.toString() ?? '',
      );
      latitude = latitudeValue;
      longitude = longitudeValue;
      // 手工输入/清除不代表系统定位精度，避免沿用上一次定位的精度。
      lastAccuracyMeters = null;
      error = null;
      _notify();
      return true;
    } on Object catch (e) {
      error = '$e';
      _notify();
      return false;
    }
  }

  void _notify() {
    if (mounted) {
      notifyListeners();
    }
  }

  bool mounted = true;

  @override
  void dispose() {
    mounted = false;
    super.dispose();
  }
}

/// 远程设备页与扫描发现面板共用的本机位置设置弹窗。
/// 返回 true 表示坐标已保存或已清除；校验失败时留在弹窗内提示。
Future<bool> showLocalLocationDialog({
  required BuildContext context,
  required LocalLocationController controller,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => _LocalLocationDialog(controller: controller),
  );
  return confirmed == true;
}

class _LocalLocationDialog extends StatefulWidget {
  const _LocalLocationDialog({required this.controller});

  final LocalLocationController controller;

  @override
  State<_LocalLocationDialog> createState() => _LocalLocationDialogState();
}

class _LocalLocationDialogState extends State<_LocalLocationDialog> {
  late final TextEditingController _lat = TextEditingController(
    text: widget.controller.latitude?.toString() ?? '',
  );
  late final TextEditingController _lng = TextEditingController(
    text: widget.controller.longitude?.toString() ?? '',
  );
  String? _validationError;
  bool _busy = false;

  bool get _useSystem =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _useSystemLocation() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _validationError = null;
    });
    final bool saved = await widget.controller.useSystemLocation();
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved) {
      Navigator.pop(context, true);
      return;
    }
    final String raw = widget.controller.error ?? '';
    setState(() => _validationError = _localizedLocalLocationError(context, raw));
  }

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String latText = _lat.text.trim();
    final String lngText = _lng.text.trim();
    double? latValue;
    double? lngValue;
    String? error;
    if (latText.isEmpty && lngText.isEmpty) {
      latValue = null;
      lngValue = null;
    } else {
      latValue = double.tryParse(latText);
      lngValue = double.tryParse(lngText);
      if (!isValidCoordinate(latValue, lngValue)) {
        error = context.t('纬度需在 -90~90，经度需在 -180~180；留空表示不标注位置');
      }
    }
    if (error != null) {
      setState(() => _validationError = error);
      return;
    }
    final bool saved = await widget.controller.save(latValue, lngValue);
    if (!mounted) {
      return;
    }
    if (!saved) {
      setState(() => _validationError = context.t(
        '本机位置设置失败：{0}',
        [widget.controller.error ?? ''],
      ));
      return;
    }
    Navigator.pop(context, true);
  }

  Widget _errorText(LocalLocationController controller) {
    if (_validationError == null && controller.error == null) {
      return const SizedBox.shrink();
    }
    final String raw = _validationError ?? controller.error ?? '';
    final String text = _localizedLocalLocationError(context, raw);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final LocalLocationController controller = widget.controller;
    final List<Widget> body = <Widget>[
      Text(
        _useSystem
            ? context.t('本机位置来自系统定位，保存后不会发送给对端')
            : context.t('本机位置只保存在本机，用于估算设备距离，不会发送给对端'),
      ),
      const SizedBox(height: 12),
    ];
    if (_useSystem) {
      body.add(
        _busy
            ? const Center(child: CircularProgressIndicator())
            : FilledButton.icon(
                key: const ValueKey<String>('local-location-system'),
                onPressed: () => unawaited(_useSystemLocation()),
                icon: const Icon(Icons.my_location),
                label: Text(context.t('使用系统定位')),
              ),
      );
      final double? latitude = controller.latitude;
      final double? longitude = controller.longitude;
      if (latitude != null && longitude != null) {
        final NavigatorState navigator = Navigator.of(context);
        final double? accuracy = controller.lastAccuracyMeters;
        body.addAll(<Widget>[
          const SizedBox(height: 12),
          Text(
            context.t('本机位置已设置'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}'
            '${accuracy == null ? '' : context.t('（精度约 {0} 米）', [accuracy.round()])}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextButton(
            onPressed: () => unawaited(() async {
              final bool saved = await controller.save(null, null);
              if (mounted && saved) navigator.pop(true);
            }()),
            child: Text(context.t('清除')),
          ),
        ]);
      }
    } else {
      body.addAll(<Widget>[
        Text(
          context.t('手动输入（桌面调试用）'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey<String>('local-location-latitude'),
          controller: _lat,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          decoration: InputDecoration(labelText: context.t('纬度')),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey<String>('local-location-longitude'),
          controller: _lng,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          decoration: InputDecoration(labelText: context.t('经度')),
        ),
        const SizedBox(height: 8),
        Text(
          context.t('坐标使用 GCJ-02，留空表示清除本机位置'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ]);
    }
    body.add(_errorText(controller));

    return AlertDialog(
      title: Text(context.t('设置本机位置')),
      content: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: body,
      )),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.t('取消')),
        ),
        if (!_useSystem)
          FilledButton(
            key: const ValueKey<String>('local-location-save'),
            onPressed: () => unawaited(_submit()),
            child: Text(context.t('保存')),
          ),
      ],
    );
  }
}
