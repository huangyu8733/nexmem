/// 账号数据目录存在性探测（默认实现：未知，不予改写）。
///
/// 原生端通过条件导入替换为 `dart:io` 实现；Web 端数据目录在网关进程内，
/// 浏览器无法探测，因此保持默认实现。
Future<bool> accountDataDirExists(String path) async => false;
