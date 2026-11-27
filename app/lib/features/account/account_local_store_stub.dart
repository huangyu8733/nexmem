// 非 Web、非 dart:io 平台（测试等）的内存兜底：不落盘。
Map<String, dynamic>? _memory;

Future<Map<String, dynamic>?> readAccountSession() async => _memory;

Future<void> writeAccountSession(Map<String, dynamic> data) async {
  _memory = data;
}

Future<void> deleteAccountData(String dataDir, String profileId) async {}
