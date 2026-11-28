// 群分享链接：复制出的文本必须能被对端直接解析并发起入群申请。
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/group/group_share_link.dart';

void main() {
  test('构造的入群链接包含群号、群主与群名', () {
    final String link = buildGroupShareLink(
      groupId: 'Z3JvdXA',
      owner: 'b3duZXI',
      title: '周末爬山',
    );

    expect(link, startsWith('nexmem://group/join'));
    expect(link, contains('g=Z3JvdXA'));
    expect(link, contains('o=b3duZXI'));
    expect(link, contains('n='));
  });

  test('解析新版分享文本，群名含空格与中文也不丢失', () {
    final String text = '群聊「周末 爬山」分享：'
        '${buildGroupShareLink(groupId: 'Z3JvdXA', owner: 'b3duZXI', title: '周末 爬山')}';

    final GroupShareInfo? info = parseGroupShareText(text);

    expect(info, isNotNull);
    expect(info!.groupId, 'Z3JvdXA');
    expect(info.owner, 'b3duZXI');
    expect(info.title, '周末 爬山');
  });

  test('兼容旧版纯文本群号与群主', () {
    const String text = '群聊「周末爬山」群号：Z3JvdXA，群主：b3duZXI。把群号发给好友即可申请入群。';

    final GroupShareInfo? info = parseGroupShareText(text);

    expect(info, isNotNull);
    expect(info!.groupId, 'Z3JvdXA');
    expect(info.owner, 'b3duZXI');
    expect(info.title, '周末爬山');
  });

  test('无法识别的文本返回 null', () {
    expect(parseGroupShareText(''), isNull);
    expect(parseGroupShareText('这是普通聊天内容'), isNull);
    expect(parseGroupShareText('nexmem://group/join?g=only-group'), isNull);
  });
}
