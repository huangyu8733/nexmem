// 远程控制密码：只保存 SHA-256 校验值，不保存明文密码。
//
// 控制端台账与被控端偏好都只持久化 credential；发起远控时信令携带同一个
// credential，被控端与本机保存值比对。信令本身走已有的加密 DM 通道。
import 'dart:convert';

import 'package:crypto/crypto.dart';

const int kRemotePasswordMinLength = 6;
const int kRemotePasswordMaxLength = 128;

const String _kCredentialPrefix = 'nexmem-remote-password-v1';

/// 生成可跨设备一致的密码校验值。加固定前缀避免与其他 SHA-256 用途混用。
String remotePasswordCredential(String password) =>
    sha256.convert(utf8.encode('$_kCredentialPrefix:$password')).toString();

bool remotePasswordMatches({
  required String password,
  required String credential,
}) =>
    credential.isNotEmpty && remotePasswordCredential(password) == credential;

/// 返回可直接传给 `context.t()` 的错误文案；null 表示合法。
String? validateRemotePassword(String password) {
  if (password.length < kRemotePasswordMinLength) {
    return '远程控制密码至少 $kRemotePasswordMinLength 位';
  }
  if (password.length > kRemotePasswordMaxLength) {
    return '远程控制密码不能超过 $kRemotePasswordMaxLength 位';
  }
  return null;
}
