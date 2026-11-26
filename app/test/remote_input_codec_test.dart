// 远控输入编码、键位映射与坐标归一化测试。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/remote/remote_input_codec.dart';

void main() {
  test('指针事件二进制往返', () {
    const RemotePointerEvent event = RemotePointerEvent(
      type: RemotePointerType.move,
      xNorm: 12345,
      yNorm: 54321,
      buttons: RemoteButtons.left,
      wheelY: 3,
      wheelX: -2,
      modifiers: RemoteModifiers.control | RemoteModifiers.shift,
      displayIndex: 1,
    );
    final RemotePointerEvent decoded =
        RemotePointerCodec.decode(RemotePointerCodec.encode(event))!;
    expect(decoded.type, RemotePointerType.move);
    expect(decoded.xNorm, 12345);
    expect(decoded.yNorm, 54321);
    expect(decoded.buttons, RemoteButtons.left);
    expect(decoded.wheelY, 3);
    expect(decoded.wheelX, -2);
    expect(decoded.modifiers, RemoteModifiers.control | RemoteModifiers.shift);
    expect(decoded.displayIndex, 1);
  });

  test('越界坐标被裁剪到 0..65535', () {
    final Uint8List bytes = RemotePointerCodec.encode(
      const RemotePointerEvent(
        type: RemotePointerType.move,
        xNorm: -10,
        yNorm: 70000,
      ),
    );
    final RemotePointerEvent decoded = RemotePointerCodec.decode(bytes)!;
    expect(decoded.xNorm, 0);
    expect(decoded.yNorm, 65535);
  });

  test('短包与未知类型返回 null', () {
    expect(RemotePointerCodec.decode(Uint8List(4)), isNull);
    final Uint8List bad = Uint8List(16)..[0] = 99;
    expect(RemotePointerCodec.decode(bad), isNull);
  });

  test('三平台键位表覆盖全部支持的逻辑键', () {
    for (final String key in RemoteKeyMap.supportedKeys) {
      expect(RemoteKeyMap.macVirtualKeys.containsKey(key), isTrue, reason: key);
      expect(
        RemoteKeyMap.windowsVirtualKeys.containsKey(key),
        isTrue,
        reason: key,
      );
      expect(RemoteKeyMap.x11Keysyms.containsKey(key), isTrue, reason: key);
    }
  });

  test('Flutter 逻辑键映射到稳定键名', () {
    expect(RemoteKeyMap.fromLogicalKey(LogicalKeyboardKey.keyA), 'a');
    expect(RemoteKeyMap.fromLogicalKey(LogicalKeyboardKey.digit7), 'digit7');
    expect(RemoteKeyMap.fromLogicalKey(LogicalKeyboardKey.arrowUp), 'arrowUp');
    expect(RemoteKeyMap.fromLogicalKey(LogicalKeyboardKey.controlLeft),
        'controlLeft');
    expect(RemoteKeyMap.fromLogicalKey(LogicalKeyboardKey.f12), 'f12');
  });
}
