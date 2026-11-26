// 远控信令编解码与分流标记测试。
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/features/remote/remote_signal.dart';

void main() {
  const RemoteDisplay display = RemoteDisplay(
    id: '1',
    name: '主屏',
    index: 0,
    x: 0,
    y: 0,
    width: 2560,
    height: 1440,
    pixelWidth: 5120,
    pixelHeight: 2880,
    scale: 2,
    primary: true,
  );

  test('request 信令往返保留权限与会话号', () {
    const RemoteSignal signal = RemoteSignal(
      type: RemoteSignalType.request,
      sid: 'r-abc',
      name: '张三',
      permissions: RemotePermissions.all,
    );
    final String payload = signal.toPayloadB64();
    expect(RemoteSignal.peekIsRemote(payload), isTrue);
    final RemoteSignal decoded = RemoteSignal.fromPayloadB64(payload);
    expect(decoded.type, RemoteSignalType.request);
    expect(decoded.sid, 'r-abc');
    expect(decoded.name, '张三');
    expect(decoded.permissions.input, isTrue);
    expect(decoded.permissions.clipboard, isTrue);
    expect(decoded.permissions.file, isTrue);
  });

  test('accept 信令携带 token、屏幕与画质', () {
    final RemoteSignal signal = RemoteSignal(
      type: RemoteSignalType.accept,
      sid: 'r-abc',
      token: 'token-1',
      permissions: const RemotePermissions(input: true),
      displays: const <RemoteDisplay>[display],
      displayId: '1',
      quality: RemoteQuality.sharp.name,
    );
    final RemoteSignal decoded =
        RemoteSignal.fromPayloadB64(signal.toPayloadB64());
    expect(decoded.token, 'token-1');
    expect(decoded.permissions.input, isTrue);
    expect(decoded.permissions.file, isFalse);
    expect(decoded.displays.single.toJson(), display.toJson());
    expect(decoded.displayId, '1');
    expect(decoded.quality, 'sharp');
  });

  test('非远控载荷不会被分流', () {
    expect(RemoteSignal.peekIsRemote('not-base64'), isFalse);
    expect(RemoteSignal.peekIsRemote('e30='), isFalse);
    final String callPayload =
        'eyJ2IjoxLCJ0eXBlIjoib2ZmZXIiLCJjYWxsX2lkIjoiZC0xIn0=';
    expect(RemoteSignal.peekIsRemote(callPayload), isFalse);
  });

  test('非法版本、sid 与类型被拒绝', () {
    expect(
      () => RemoteSignal.fromPayloadB64('eyJhcHAiOiJyYyJ9'),
      throwsFormatException,
    );
    expect(
      () => RemoteSignal.fromPayloadB64(
        'eyJ2IjoxLCJhcHAiOiJyYyIsInR5cGUiOiJyZXF1ZXN0Iiwic2lkIjoiYmFkIn0=',
      ),
      throwsFormatException,
    );
  });

  test('权限集合与空权限序列化稳定', () {
    const RemotePermissions none = RemotePermissions.none;
    expect(none.set, isEmpty);
    expect(none.toJson()['caps'], isEmpty);
    final RemotePermissions parsed = RemotePermissions.fromJson(
      const <String, dynamic>{
        'caps': <String>['input', 'file'],
      },
    );
    expect(parsed.input, isTrue);
    expect(parsed.clipboard, isFalse);
    expect(parsed.file, isTrue);
  });
}
