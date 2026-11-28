/// 从已有图片中识别二维码。
///
/// 平台实现：Android / iOS / macOS 用 mobile_scanner 的图像分析能力，
/// Web / Windows / Linux 暂不支持直接分析图片，安全返回 null。
library;

import 'image_qr_decoder_stub.dart'
    if (dart.library.io) 'image_qr_decoder_io.dart'
    if (dart.library.html) 'image_qr_decoder_web.dart';

/// 当前平台能否分析已有图片中的二维码。
bool get qrImageDecodeSupported => qrImageDecodeSupportedImpl;

typedef QrImageDecoder =
    Future<String?> Function({required String path, String? sourceUri});

/// 可被测试替换的解码入口。
QrImageDecoder qrImageDecoder = decodeQrFromImageImpl;

/// 从本地图片路径或在线图片源识别二维码，返回原始文本；未识别到返回 null。
Future<String?> decodeQrFromImage({
  required String path,
  String? sourceUri,
}) {
  return qrImageDecoder(path: path, sourceUri: sourceUri);
}
