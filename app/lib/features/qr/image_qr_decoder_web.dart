// Web 端 mobile_scanner 不支持 analyzeImage，浏览器 BarcodeDetector 兼容性不一，
// 这里统一降级为 null，由调用方给出「当前平台不支持」提示。
bool get qrImageDecodeSupportedImpl => false;

Future<String?> decodeQrFromImageImpl({
  required String path,
  String? sourceUri,
}) async {
  return null;
}
