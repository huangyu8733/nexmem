// 在线升级：版本比较、Release 解析、资产匹配的纯逻辑测试。

import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/features/updater/update_model.dart';

void main() {
  group('版本比较', () {
    test('相同版本相等', () {
      expect(compareVersions('1.1.0', '1.1.0'), 0);
      expect(compareVersions('v1.1.0', '1.1.0'), 0);
      expect(compareVersions('1.1.0+2', '1.1.0'), 0);
    });

    test('正确识别新旧版本', () {
      expect(isNewer('1.0.0', '1.1.0'), isTrue);
      expect(isNewer('1.1.0', '1.0.0'), isFalse);
      expect(isNewer('1.9.9', '1.10.0'), isTrue);
      expect(isNewer('2.0.0', '1.99.99'), isFalse);
      expect(isNewer('1.99.99', '2.0.0'), isTrue);
      expect(isNewer('1.1.0', 'v1.1.1'), isTrue);
    });

    test('位数不同的版本按 0 补齐', () {
      expect(compareVersions('1.1', '1.1.0'), 0);
      expect(compareVersions('1.1.0.1', '1.1.0'), 1);
    });
  });

  group('Release 解析', () {
    test('解析合法响应', () {
      final ReleaseInfo? r = parseRelease(<String, dynamic>{
        'tag_name': 'v1.1.0',
        'html_url': 'https://github.com/huangyu8733/nexmem/releases/tag/v1.1.0',
        'body': '修复若干问题',
        'published_at': '2026-11-24T00:00:00Z',
        'assets': <dynamic>[
          <String, dynamic>{'name': 'Nexmem-1.1.0-windows-x64.zip'},
          <String, dynamic>{'name': 'Nexmem-1.1.0-android.apk'},
        ],
      });
      expect(r, isNotNull);
      expect(r!.version, '1.1.0');
      expect(r.tag, 'v1.1.0');
      expect(r.assets, contains('Nexmem-1.1.0-windows-x64.zip'));
    });

    test('非法响应返回 null', () {
      expect(parseRelease(null), isNull);
      expect(parseRelease(<String, dynamic>{'tag_name': 'bad'}), isNull);
      expect(parseRelease('not a map'), isNull);
    });
  });

  group('资产匹配', () {
    late ReleaseInfo release;
    setUp(() {
      release = ReleaseInfo(
        version: '1.1.0',
        tag: 'v1.1.0',
        pageUrl: 'https://github.com/huangyu8733/nexmem/releases/tag/v1.1.0',
        notes: '',
        publishedAt: '',
        assets: <String>[
          'Nexmem-1.1.0-windows-x64.zip',
          'Nexmem-1.1.0-linux-x64.tar.gz',
          'Nexmem-1.1.0-macos-arm64.zip',
          'Nexmem-1.1.0-android.apk',
          'Nexmem-1.1.0-web.zip',
        ],
      );
    });

    test('各平台匹配到正确资产', () {
      expect(release.assetFor(UpdateChannel.windows),
          'Nexmem-1.1.0-windows-x64.zip');
      expect(release.assetFor(UpdateChannel.linux),
          'Nexmem-1.1.0-linux-x64.tar.gz');
      expect(release.assetFor(UpdateChannel.macos),
          'Nexmem-1.1.0-macos-arm64.zip');
      expect(release.assetFor(UpdateChannel.android),
          'Nexmem-1.1.0-android.apk');
      expect(release.assetFor(UpdateChannel.web), 'Nexmem-1.1.0-web.zip');
    });

    test('缺失资产返回 null', () {
      final ReleaseInfo partial = ReleaseInfo(
        version: '1.1.0',
        tag: 'v1.1.0',
        pageUrl: '',
        notes: '',
        publishedAt: '',
        assets: const <String>[],
      );
      expect(partial.assetFor(UpdateChannel.windows), isNull);
    });
  });
}
