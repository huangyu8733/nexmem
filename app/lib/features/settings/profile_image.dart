import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;

import 'settings_service.dart';

/// 个人头像与推广图片的纯 Dart 处理：拒绝 GIF、等比压缩到 1024x1024 内、
/// 统一编码为 JPEG，再把 base64 分片写入现有设置 KV。
///
/// 内核 `settings.set` 单值上限 4096 UTF-8 字节，分片后每片 3000 个 ASCII
/// 字符；KV 随账号备份与 P6-41 设置快照迁移，因此图片同样跨设备可带走。
const int profileImageMaxDimension = 1024;
const int profileImageChunkChars = 3000;
const int profileImageMaxBase64Chars = 400 * 1024;

/// 个人资料图片槽位。
enum ProfileImageSlot { avatar, promo }

extension ProfileImageSlotX on ProfileImageSlot {
  String get keyPrefix {
    switch (this) {
      case ProfileImageSlot.avatar:
        return 'profile.avatar';
      case ProfileImageSlot.promo:
        return 'profile.promo_image';
    }
  }

  String get label {
    switch (this) {
      case ProfileImageSlot.avatar:
        return '头像';
      case ProfileImageSlot.promo:
        return '推广图片';
    }
  }
}

/// 图片处理或分片读写失败时抛出的结构化错误。
class ProfileImageException implements Exception {
  const ProfileImageException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 一张已压缩图片的结果：[bytes] 为最终 JPEG，[base64] 为可落库文本。
class ProfileImageData {
  const ProfileImageData({
    required this.base64,
    required this.bytes,
    required this.width,
    required this.height,
    required this.mime,
  });

  final String base64;
  final Uint8List bytes;
  final int width;
  final int height;
  final String mime;

  int get encodedBytes => bytes.length;

  Map<String, dynamic> toMetaJson({required int chunks}) {
    return <String, dynamic>{
      'v': 1,
      'mime': mime,
      'width': width,
      'height': height,
      'bytes': encodedBytes,
      'base64_length': base64.length,
      'chunks': chunks,
    };
  }

  static ProfileImageData fromMetaAndBase64(
    Map<String, dynamic> meta,
    String base64,
  ) {
    final Uint8List bytes = base64Decode(base64);
    return ProfileImageData(
      base64: base64,
      bytes: bytes,
      width: (meta['width'] as num?)?.toInt() ?? 0,
      height: (meta['height'] as num?)?.toInt() ?? 0,
      mime: (meta['mime'] as String?) ?? 'image/jpeg',
    );
  }
}

class _ProfileImageMeta {
  const _ProfileImageMeta({
    required this.chunks,
    required this.base64Length,
    required this.width,
    required this.height,
  });

  final int chunks;
  final int base64Length;
  final int width;
  final int height;

  static _ProfileImageMeta? parse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on Object {
      return null;
    }
    if (decoded is! Map<String, dynamic> || decoded['v'] != 1) {
      return null;
    }
    final int? chunks = (decoded['chunks'] as num?)?.toInt();
    final int? length = (decoded['base64_length'] as num?)?.toInt();
    if (chunks == null || chunks < 1 || length == null || length < 1) {
      return null;
    }
    return _ProfileImageMeta(
      chunks: chunks,
      base64Length: length,
      width: (decoded['width'] as num?)?.toInt() ?? 0,
      height: (decoded['height'] as num?)?.toInt() ?? 0,
    );
  }
}

/// base64 图片的 KV 分片存储。先写分片、最后写 meta，保证读到 meta 时数据完整。
class ProfileImageStore {
  const ProfileImageStore(this._settings);

  final SettingsService _settings;

  Future<ProfileImageData?> load(ProfileImageSlot slot) async {
    final _ProfileImageMeta? meta = _ProfileImageMeta.parse(
      await _settings.read(_metaKey(slot)),
    );
    if (meta == null) {
      return null;
    }
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < meta.chunks; i++) {
      final String? part = await _settings.read(_chunkKey(slot, i));
      if (part == null) {
        return null;
      }
      buffer.write(part);
    }
    final String base64 = buffer.toString();
    if (base64.length != meta.base64Length) {
      return null;
    }
    try {
      return ProfileImageData.fromMetaAndBase64(<String, dynamic>{
        'mime': 'image/jpeg',
        'width': meta.width,
        'height': meta.height,
      }, base64);
    } on Object {
      return null;
    }
  }

  Future<void> save(ProfileImageSlot slot, ProfileImageData data) async {
    final _ProfileImageMeta? old = _ProfileImageMeta.parse(
      await _settings.read(_metaKey(slot)),
    );
    final int chunks = (data.base64.length / profileImageChunkChars).ceil();
    for (int i = 0; i < chunks; i++) {
      final int start = i * profileImageChunkChars;
      final int end = math.min(start + profileImageChunkChars, data.base64.length);
      await _settings.write(
        _chunkKey(slot, i),
        data.base64.substring(start, end),
      );
    }
    await _settings.write(
      _metaKey(slot),
      jsonEncode(data.toMetaJson(chunks: chunks)),
    );
    if (old != null) {
      for (int i = chunks; i < old.chunks; i++) {
        await _settings.write(_chunkKey(slot, i), '');
      }
    }
  }

  Future<void> clear(ProfileImageSlot slot) async {
    final _ProfileImageMeta? old = _ProfileImageMeta.parse(
      await _settings.read(_metaKey(slot)),
    );
    if (old != null) {
      for (int i = 0; i < old.chunks; i++) {
        await _settings.write(_chunkKey(slot, i), '');
      }
    }
    await _settings.write(_metaKey(slot), '');
  }

  String _metaKey(ProfileImageSlot slot) => '${slot.keyPrefix}.meta';

  String _chunkKey(ProfileImageSlot slot, int index) =>
      '${slot.keyPrefix}.${index.toString().padLeft(3, '0')}';
}

/// 判断原始字节是否是 GIF（按文件头，不依赖扩展名）。
bool isGifBytes(Uint8List bytes) {
  if (bytes.length < 6) {
    return false;
  }
  final String header = String.fromCharCodes(bytes.sublist(0, 6));
  return header == 'GIF87a' || header == 'GIF89a';
}

/// 校验、等比压缩并编码一张本地图片。
Future<ProfileImageData> prepareProfileImage(
  Uint8List source,
  String fileName,
) async {
  final String lowerName = fileName.toLowerCase();
  if (lowerName.endsWith('.gif') || isGifBytes(source)) {
    throw const ProfileImageException(
      'GIF_UNSUPPORTED',
      '不支持 GIF 图片，请选择 PNG / JPG / BMP',
    );
  }
  final img.Image? decoded = img.decodeImage(source);
  if (decoded == null) {
    throw const ProfileImageException(
      'DECODE_FAILED',
      '无法识别该图片，请选择 PNG / JPG / BMP',
    );
  }
  final img.Image resized = _fitInside(decoded);
  int quality = 82;
  Uint8List encoded = img.encodeJpg(resized, quality: quality);
  String base64 = base64Encode(encoded);
  while (base64.length > profileImageMaxBase64Chars && quality > 45) {
    quality -= 10;
    encoded = img.encodeJpg(resized, quality: quality);
    base64 = base64Encode(encoded);
  }
  if (base64.length > profileImageMaxBase64Chars) {
    throw const ProfileImageException(
      'TOO_LARGE',
      '图片压缩后仍过大，请换一张更小的图片',
    );
  }
  return ProfileImageData(
    base64: base64,
    bytes: encoded,
    width: resized.width,
    height: resized.height,
    mime: 'image/jpeg',
  );
}

/// 从系统文件选择器读到的原始图片（尚未压缩 / 裁剪）。
class PickedProfileImage {
  const PickedProfileImage({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;
}

/// 选一张原始图片供裁剪页使用；取消返回 null。
Future<PickedProfileImage?> pickProfileImageFile() async {
  final PlatformFile? file = await FilePicker.pickFile(type: FileType.image);
  if (file == null) {
    return null;
  }
  try {
    return PickedProfileImage(
      bytes: await file.readAsBytes(),
      name: file.name,
    );
  } on Object {
    throw const ProfileImageException('READ_FAILED', '无法读取所选图片，请重新选择');
  }
}

/// 通过系统文件选择器选一张图片并立即压缩；取消返回 null。
Future<ProfileImageData?> pickProfileImage() async {
  final PlatformFile? file = await FilePicker.pickFile(type: FileType.image);
  if (file == null) {
    return null;
  }
  try {
    final Uint8List bytes = await file.readAsBytes();
    return await prepareProfileImage(bytes, file.name);
  } on Object catch (error) {
    if (error is ProfileImageException) {
      rethrow;
    }
    throw ProfileImageException('READ_FAILED', '无法读取所选图片，请重新选择');
  }
}

img.Image _fitInside(img.Image source) {
  if (source.width <= profileImageMaxDimension &&
      source.height <= profileImageMaxDimension) {
    return source;
  }
  final double scale = math.min(
    profileImageMaxDimension / source.width,
    profileImageMaxDimension / source.height,
  );
  final int width = math.max(1, (source.width * scale).round());
  final int height = math.max(1, (source.height * scale).round());
  return img.copyResize(
    source,
    width: width,
    height: height,
    interpolation: img.Interpolation.average,
  );
}