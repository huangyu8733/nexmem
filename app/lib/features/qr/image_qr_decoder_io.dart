import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';

bool get qrImageDecodeSupportedImpl => true;

Future<String?> decodeQrFromImageImpl({
  required String path,
  String? sourceUri,
}) async {
  String target = path.trim();
  File? temporary;
  try {
    final String remote = (sourceUri ?? '').trim();
    if (remote.isNotEmpty) {
      final http.Response response = await http
          .get(Uri.parse(remote))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        return null;
      }
      final Directory directory = await getTemporaryDirectory();
      temporary = File(
        '${directory.path}/nexmem-qr-${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await temporary.writeAsBytes(response.bodyBytes);
      target = temporary.path;
    } else {
      if (target.isEmpty || !File(target).existsSync()) {
        return null;
      }
    }

    final MobileScannerController controller = MobileScannerController(
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    );
    try {
      final BarcodeCapture? capture = await controller.analyzeImage(
        target,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );
      for (final Barcode barcode in capture?.barcodes ?? const <Barcode>[]) {
        final String? value = barcode.rawValue?.trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
      return null;
    } finally {
      await controller.dispose();
    }
  } on Object {
    return null;
  } finally {
    if (temporary != null) {
      try {
        if (temporary.existsSync()) {
          temporary.deleteSync();
        }
      } on Object {
        // 临时文件清理失败不影响识别结果。
      }
    }
  }
}
