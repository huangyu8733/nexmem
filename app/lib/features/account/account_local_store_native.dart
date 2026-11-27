import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<File> _file() async {
  final Directory support = await getApplicationSupportDirectory();
  final Directory dir = Directory(p.join(support.path, 'nexmem'));
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return File(p.join(dir.path, 'account_session.json'));
}

Future<Map<String, dynamic>?> readAccountSession() async {
  try {
    final File file = await _file();
    if (!file.existsSync()) {
      return null;
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    return decoded is Map<String, dynamic> ? decoded : null;
  } on Object {
    return null;
  }
}

Future<void> writeAccountSession(Map<String, dynamic> data) async {
  final File file = await _file();
  final File temp = File('${file.path}.tmp');
  await temp.writeAsString(jsonEncode(data), flush: true);
  if (file.existsSync()) {
    await file.delete();
  }
  await temp.rename(file.path);
}

/// 只删除本应用「添加账号」创建的 `profiles/<档案ID>` 目录。
///
/// 先规范路径并校验最后两段，避免误删默认数据目录或用户传入的其他路径。
Future<void> deleteAccountData(String dataDir, String profileId) async {
  if (dataDir.trim().isEmpty ||
      profileId.isEmpty ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(profileId)) {
    return;
  }
  final String normalized = dataDir.replaceAll(r'\', '/');
  final List<String> segments = normalized
      .split('/')
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.length < 2 ||
      segments[segments.length - 2] != 'profiles' ||
      segments.last != profileId) {
    return;
  }
  final String parent = p.canonicalize(p.dirname(normalized));
  final String target = p.join(parent, profileId);
  final Directory directory = Directory(target);
  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
}
