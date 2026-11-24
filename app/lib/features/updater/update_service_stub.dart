// Web 平台 stub：浏览器不支持直接下载/解压安装包，仅提供跳转 Release 页的能力。

import 'update_model.dart';

const String kGitHubRepo = 'huangyu8733/nexmem';
const String kLatestReleaseApi =
    'https://api.github.com/repos/$kGitHubRepo/releases/latest';
const String kReleasePage = 'https://github.com/$kGitHubRepo/releases/latest';

class UpdateException implements Exception {
  const UpdateException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'UpdateException: $message';
}

typedef DownloadProgress = void Function(int downloaded, int total);

class UpdateService {
  UpdateChannel get channel => UpdateChannel.web;

  Future<ReleaseInfo> checkLatest() async {
    throw const UpdateException('Web 端请在浏览器打开 GitHub 发布页检查更新');
  }

  Future<String> download(ReleaseInfo release, DownloadProgress onProgress) async {
    throw const UpdateException('Web 端不支持直接下载安装包');
  }

  Future<String> extract(String filePath) async => filePath;

  Future<void> reveal(String path) async {}

  Future<void> openReleasePage(String url) async {}

  void close() {}
}
