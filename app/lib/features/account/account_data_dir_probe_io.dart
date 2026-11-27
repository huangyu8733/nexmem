import 'dart:io';

/// 原生端探测账号数据目录是否真实存在。
///
/// 移动端重装/从备份恢复后沙盒容器 UUID 会变化，`account_session.json`
/// 里保存的绝对路径可能已失效；只有确认目录不存在才做目录重定位。
Future<bool> accountDataDirExists(String path) async {
  if (path.trim().isEmpty) {
    return false;
  }
  try {
    return Directory(path).existsSync();
  } on Object {
    return false;
  }
}
