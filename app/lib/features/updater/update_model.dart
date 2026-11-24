/// GitHub Releases 在线升级：平台无关的数据模型与版本比较逻辑。
///
/// 只依赖纯 Dart，便于在 Web / 桌面 / 移动端共用并单测。
library;

/// 发布渠道：根据当前运行平台选择对应的安装包资产。
enum UpdateChannel { windows, linux, macos, android, web }

/// 一条 GitHub Release 的精简信息。
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.pageUrl,
    required this.notes,
    required this.publishedAt,
    required this.assets,
  });

  /// 纯数字版本，如 `1.1.0`。
  final String version;

  /// GitHub tag，如 `v1.1.0`。
  final String tag;

  /// Release 页面地址。
  final String pageUrl;

  /// Release 说明（Markdown 原文）。
  final String notes;

  /// ISO-8601 发布时间。
  final String publishedAt;

  /// 资产文件名列表。
  final List<String> assets;

  /// 按渠道匹配安装包文件名。
  ///
  /// Windows/macOS 为 zip，Linux 优先 deb（同时提供 tar.gz），Android 为 apk。
  String? assetFor(UpdateChannel channel) {
    final String prefix = 'Nexmem-$version-';
    final String suffix = switch (channel) {
      UpdateChannel.windows => '-windows-x64.zip',
      UpdateChannel.linux => '-linux-x64.tar.gz',
      UpdateChannel.macos => '-macos-arm64.zip',
      UpdateChannel.android => '-android.apk',
      UpdateChannel.web => '-web.zip',
    };
    for (final String a in assets) {
      if (a.startsWith(prefix) && a.endsWith(suffix)) {
        return a;
      }
    }
    // Linux 兼容旧命名 nexmem_<version>_amd64.deb。
    if (channel == UpdateChannel.linux) {
      for (final String a in assets) {
        if (a.contains(version) && (a.endsWith('.deb') || a.contains('linux'))) {
          return a;
        }
      }
    }
    return null;
  }
}

/// 比较两个版本号。返回值：`>0` 表示 a 更新，`<0` 表示 b 更新，`0` 相等。
///
/// 支持形如 `1.1.0`、`v1.1.0`、`1.1.0+2` 的版本，忽略前导 `v` 与构建号。
int compareVersions(String a, String b) {
  List<int> parts(String s) {
    final String cleaned = s.trim().replaceFirst(RegExp(r'^v'), '');
    final String core = cleaned.split(RegExp(r'[+\-]')).first;
    return core
        .split('.')
        .map((String p) => int.tryParse(p) ?? 0)
        .toList(growable: false);
  }

  final List<int> pa = parts(a);
  final List<int> pb = parts(b);
  final int n = pa.length > pb.length ? pa.length : pb.length;
  for (int i = 0; i < n; i++) {
    final int va = i < pa.length ? pa[i] : 0;
    final int vb = i < pb.length ? pb[i] : 0;
    if (va != vb) {
      return va > vb ? 1 : -1;
    }
  }
  return 0;
}

/// 判断 [remote] 是否比 [local] 更新。
bool isNewer(String local, String remote) => compareVersions(remote, local) > 0;

/// 解析 GitHub `/releases/latest` 响应中的必要字段。
///
/// 对缺失/异常字段做容错，避免单个坏字段导致整个升级检查失败。
ReleaseInfo? parseRelease(dynamic json) {
  if (json is! Map<String, dynamic>) {
    return null;
  }
  final String tag = (json['tag_name'] ?? '').toString();
  final String version = tag.replaceFirst(RegExp(r'^v'), '');
  if (version.isEmpty || !RegExp(r'^\d+\.\d+').hasMatch(version)) {
    return null;
  }
  final Object? rawAssets = json['assets'];
  final List<String> assets = <String>[];
  if (rawAssets is List) {
    for (final Object? a in rawAssets) {
      if (a is Map<String, dynamic>) {
        final String name = (a['name'] ?? '').toString();
        if (name.isNotEmpty) {
          assets.add(name);
        }
      } else if (a is String) {
        assets.add(a);
      }
    }
  }
  final String pageUrl = (json['html_url'] ?? '').toString();
  return ReleaseInfo(
    version: version,
    tag: tag,
    pageUrl: pageUrl.isEmpty
        ? 'https://github.com/huangyu8733/nexmem/releases/latest'
        : pageUrl,
    notes: (json['body'] ?? '').toString(),
    publishedAt: (json['published_at'] ?? '').toString(),
    assets: assets,
  );
}
