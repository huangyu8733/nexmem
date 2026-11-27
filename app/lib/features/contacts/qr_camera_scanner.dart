/// 摄像头扫码页：真正打开设备摄像头识别二维码名片。
///
/// 走 `mobile_scanner` 跨平台实现：iOS/Android 用 AVFoundation / CameraX，
/// macOS 用 Apple Vision，Web 用浏览器 getUserMedia + ZXing。
/// 扫到任意文本后立即回调，由调用方校验 `nexmem://add/...` 格式并验签。
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';

/// 扫码页构建器：测试可注入假实现，避免依赖真实摄像头。
typedef QrCameraScannerBuilder = Widget Function(
  BuildContext context,
  void Function(String raw) onDetected,
);

/// 打开摄像头扫码页。识别到二维码后返回原始文本（可能不是 Nexmem 名片，
/// 由调用方决定如何提示）；用户取消返回 null。
Future<String?> showQrCameraScanner(BuildContext context) {
  return showQrCameraScannerWithBuilder(context, scannerBuilder: null);
}

/// 测试可注入 scanner builder 的扫码入口；生产代码请用 [showQrCameraScanner]。
Future<String?> showQrCameraScannerWithBuilder(
  BuildContext context, {
  QrCameraScannerBuilder? scannerBuilder,
}) {
  return Navigator.of(context).push<String?>(
    MaterialPageRoute<String?>(
      builder: (BuildContext routeContext) => QrCameraScannerPage(
        scannerBuilder: scannerBuilder,
      ),
    ),
  );
}

class QrCameraScannerPage extends StatefulWidget {
  const QrCameraScannerPage({
    this.scannerBuilder,
    super.key,
  });

  /// 仅用于测试注入；生产环境为 null，使用真实摄像头。
  final QrCameraScannerBuilder? scannerBuilder;

  @override
  State<QrCameraScannerPage> createState() => _QrCameraScannerPageState();
}

class _QrCameraScannerPageState extends State<QrCameraScannerPage> {
  late final MobileScannerController _controller;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    // 测试注入 builder 时不创建真实 controller，避免打开摄像头。
    if (widget.scannerBuilder == null) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        // 只识别二维码即可，名片是 QR 格式。
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );
    }
  }

  @override
  void dispose() {
    if (widget.scannerBuilder == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) {
      return;
    }
    for (final Barcode barcode in capture.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw != null && raw.trim().isNotEmpty) {
        _finish(raw.trim());
        return;
      }
    }
  }

  void _finish(String raw) {
    if (_handled) {
      return;
    }
    _handled = true;
    Navigator.of(context).pop<String>(raw);
  }

  Widget _buildError(BuildContext context, MobileScannerException error) {
    final String hint = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        context.t('摄像头权限被拒绝，请在系统设置中允许 Nexmem 使用摄像头'),
      MobileScannerErrorCode.unsupported =>
        context.t('当前设备或浏览器不支持摄像头扫码'),
      _ => context.t('摄像头启动失败：{0}', [error.errorCode.name]),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.qr_code_scanner, size: 56),
            const SizedBox(height: 16),
            Text(hint, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop<String?>(null),
              child: Text(context.t('返回手动输入')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final QrCameraScannerBuilder? injected = widget.scannerBuilder;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('摄像头扫码')),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: context.t('关闭'),
          onPressed: () => Navigator.of(context).pop<String?>(null),
        ),
        actions: <Widget>[
          if (injected == null) ...<Widget>[
            IconButton(
              key: const ValueKey<String>('qr-scanner-torch'),
              icon: const Icon(Icons.flashlight_on),
              tooltip: context.t('打开/关闭手电筒'),
              onPressed: () => unawaited(_controller.toggleTorch()),
            ),
            IconButton(
              key: const ValueKey<String>('qr-scanner-switch-camera'),
              icon: const Icon(Icons.cameraswitch),
              tooltip: context.t('切换前后摄像头'),
              onPressed: () => unawaited(_controller.switchCamera()),
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: injected != null
                  ? injected(context, _finish)
                  : MobileScanner(
                      key: const ValueKey<String>('qr-camera-view'),
                      controller: _controller,
                      onDetect: _onDetect,
                      errorBuilder: _buildError,
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                context.t(
                  kIsWeb
                      ? '把二维码对准摄像头，首次使用请允许浏览器访问摄像头'
                      : '把对方的二维码名片对准摄像头',
                ),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
