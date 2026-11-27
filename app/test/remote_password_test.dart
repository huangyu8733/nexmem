// 远控密码校验值测试。
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/remote/remote_password.dart';

void main() {
  test('同一密码生成稳定校验值，且不返回明文', () {
    final String first = remotePasswordCredential('123456');
    final String second = remotePasswordCredential('123456');
    expect(first, second);
    expect(first.length, 64);
    expect(first, isNot(contains('123456')));
    expect(remotePasswordCredential('123457'), isNot(first));
  });

  test('校验只接受非空且匹配的密码', () {
    final String credential = remotePasswordCredential('abcdef');
    expect(
      remotePasswordMatches(password: 'abcdef', credential: credential),
      isTrue,
    );
    expect(
      remotePasswordMatches(password: 'ABCDEF', credential: credential),
      isFalse,
    );
    expect(
      remotePasswordMatches(password: 'abcdef', credential: ''),
      isFalse,
    );
  });

  test('长度校验给出明确错误', () {
    expect(validateRemotePassword('12345'), '远程控制密码至少 6 位');
    expect(validateRemotePassword('123456'), isNull);
    expect(
      validateRemotePassword('a' * 129),
      '远程控制密码不能超过 128 位',
    );
  });
}
