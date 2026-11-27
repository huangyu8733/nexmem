import 'account_local_store_stub.dart'
    if (dart.library.io) 'account_local_store_native.dart'
    if (dart.library.js_interop) 'account_local_store_web.dart'
    as impl;

/// 账号档案存储：内核尚未启动或已停止时仍需可用，因此不能走 `core.start`
/// 之后才可用的 `settings.get/set`。
///
/// 桌面/移动端落在应用支持目录的 JSON 文件，Web 端落在 `localStorage`。
class AccountLocalStore {
  const AccountLocalStore();

  Future<Map<String, dynamic>?> read() => impl.readAccountSession();

  Future<void> write(Map<String, dynamic> data) =>
      impl.writeAccountSession(data);

  /// 删除「添加账号」创建的数据目录；只允许 `profiles/<档案ID>` 形态。
  Future<void> deleteAccountData(String dataDir, String profileId) =>
      impl.deleteAccountData(dataDir, profileId);
}
