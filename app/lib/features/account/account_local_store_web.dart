import 'dart:convert';

import 'package:web/web.dart' as web;

const String _key = 'nexmem.account.session.v1';

Future<Map<String, dynamic>?> readAccountSession() async {
  final String? raw = web.window.localStorage.getItem(_key);
  if (raw == null || raw.isEmpty) {
    return null;
  }
  try {
    final Object? decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on Object {
    return null;
  }
}

Future<void> writeAccountSession(Map<String, dynamic> data) async {
  web.window.localStorage.setItem(_key, jsonEncode(data));
}

/// Web 端内核运行在自托管服务上，浏览器无权删除服务端数据目录。
Future<void> deleteAccountData(String dataDir, String profileId) async {}
