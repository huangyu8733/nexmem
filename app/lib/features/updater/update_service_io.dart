// 桌面/移动端实现：GitHub Releases API + 流式下载 + 解压 + 打开文件。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'update_model.dart';

/// GitHub 仓库（与 README / release 工作流一致）。
const String kGitHubRepo = 'huangyu8733/nexmem';
const String kLatestReleaseApi =
    'https://api.github.com/repos/$kGitHubRepo/releases/latest';

/// 默认 Release 页面。
const String kReleasePage = 'https://github.com/$kGitHubRepo/releases/latest';

/// 升级服务异常。
class UpdateException implements Exception {
  const UpdateException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'UpdateException: $message';
}

/// 下载进度：`downloaded / total`，total 为 -1 表示未知。
typedef DownloadProgress = void Function(int downloaded, int total);

/// GitHub 在线升级服务（IO 平台）。
class UpdateService {
  final HttpClient _client = HttpClient();

  /// 当前运行平台对应的发布渠道。
  UpdateChannel get channel {
    if (Platform.isAndroid) return UpdateChannel.android;
    if (Platform.isIOS) return UpdateChannel.macos;
    if (Platform.isWindows) return UpdateChannel.windows;
    if (Platform.isMacOS) return UpdateChannel.macos;
    return UpdateChannel.linux;
  }

  /// 请求 GitHub 最新版信息。
  Future<ReleaseInfo> checkLatest() async {
    final HttpClientRequest req = await _client.getUrl(Uri.parse(kLatestReleaseApi));
    req.headers
      ..set('User-Agent', 'Nexmem-Updater')
      ..set('Accept', 'application/vnd.github+json');
    final HttpClientResponse resp = await req.close();
    final String body = await utf8.decoder.bind(resp).join();
    if (resp.statusCode != 200) {
      throw UpdateException('GitHub 返回 ${resp.statusCode}');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const UpdateException('GitHub 响应格式错误');
    }
    final ReleaseInfo? info = parseRelease(decoded);
    if (info == null) {
      throw const UpdateException('未找到有效版本');
    }
    return info;
  }

  /// 下载安装包到临时目录，返回本地文件路径。
  Future<String> download(ReleaseInfo release, DownloadProgress onProgress) async {
    final String? asset = release.assetFor(channel);
    if (asset == null) {
      throw UpdateException('当前平台没有匹配的安装包（${channel.name}）');
    }
    final Uri uri = Uri.parse(
      'https://github.com/$kGitHubRepo/releases/download/${release.tag}/$asset',
    );
    final Directory temp = await getTemporaryDirectory();
    final Directory target = Directory(
      '${temp.path}${Platform.pathSeparator}nexmem-update-${release.version}',
    );
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final String outPath = '${target.path}${Platform.pathSeparator}$asset';
    await _fetch(uri, outPath, onProgress, 0);
    return outPath;
  }

  Future<void> _fetch(
    Uri uri,
    String outPath,
    DownloadProgress onProgress,
    int redirects,
  ) async {
    if (redirects > 5) {
      throw const UpdateException('下载重定向次数过多');
    }
    final HttpClientRequest req = await _client.getUrl(uri);
    req.headers.set('User-Agent', 'Nexmem-Updater');
    final HttpClientResponse resp = await req.close();
    if (resp.statusCode == 302 || resp.statusCode == 301) {
      final String? location = resp.headers.value('location');
      if (location != null) {
        await resp.drain<void>();
        await _fetch(Uri.parse(location), outPath, onProgress, redirects + 1);
        return;
      }
    }
    if (resp.statusCode != 200) {
      throw UpdateException('下载失败：HTTP ${resp.statusCode}');
    }
    final int total = resp.contentLength;
    int received = 0;
    final IOSink sink = File(outPath).openWrite();
    try {
      await for (final List<int> chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await sink.close();
    }
    if (await File(outPath).length() == 0) {
      throw const UpdateException('下载文件为空');
    }
  }

  /// 解压 zip / tar.gz 到同目录，返回目录路径；APK 无需解压。
  Future<String> extract(String filePath) async {
    final String name = filePath.split(RegExp(r'[\\/]')).last;
    final String dirPath = filePath.substring(0, filePath.length - name.length);
    final String lower = name.toLowerCase();
    if (lower.endsWith('.apk')) return dirPath;
    if (lower.endsWith('.zip')) {
      final Archive archive = ZipDecoder().decodeBytes(await File(filePath).readAsBytes());
      extractArchiveToDisk(archive, dirPath);
      return dirPath;
    }
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      final Archive archive =
          TarDecoder().decodeBytes(gzip.decode(await File(filePath).readAsBytes()));
      extractArchiveToDisk(archive, dirPath);
      return dirPath;
    }
    return dirPath;
  }

  /// 在系统文件管理器中打开目录，由用户自行完成安装（不自动替换运行中的程序）。
  Future<void> reveal(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', <String>[path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[path]);
    } else if (Platform.isAndroid) {
      const MethodChannel ch = MethodChannel('io.nexmem/core');
      try {
        await ch.invokeMethod<void>('openPath', <String, dynamic>{'path': path});
      } on MissingPluginException {
        // 用户可从文件管理器手动打开。
      }
    }
  }

  /// 用系统浏览器打开发布页。
  Future<void> openReleasePage(String url) async {
    if (Platform.isWindows) {
      await Process.run('cmd', <String>['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', <String>[url]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[url]);
    } else if (Platform.isAndroid) {
      const MethodChannel ch = MethodChannel('io.nexmem/core');
      try {
        await ch.invokeMethod<void>('openUrl', <String, dynamic>{'url': url});
      } on MissingPluginException {
        // 忽略。
      }
    }
  }

  void close() => _client.close();
}
