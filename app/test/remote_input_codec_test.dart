// 远控输入编码、键位映射与坐标归一化测试。
import 'dart:convert';

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

  test('侧键 back/forward 编解码往返', () {
    final RemotePointerEvent decoded = RemotePointerCodec.decode(
      RemotePointerCodec.encode(const RemotePointerEvent(
        type: RemotePointerType.button,
        xNorm: 10,
        yNorm: 20,
        buttons: RemoteButtons.back | RemoteButtons.forward,
      )),
    )!;
    expect(decoded.buttons & RemoteButtons.back, RemoteButtons.back);
    expect(decoded.buttons & RemoteButtons.forward, RemoteButtons.forward);
  });

  test('pinch 类型编解码往返', () {
    final RemotePointerEvent decoded = RemotePointerCodec.decode(
      RemotePointerCodec.encode(const RemotePointerEvent(
        type: RemotePointerType.pinch,
        xNorm: 100,
        yNorm: 200,
        wheelY: 3,
        modifiers: RemoteModifiers.control,
      )),
    )!;
    expect(decoded.type, RemotePointerType.pinch);
    expect(decoded.wheelY, 3);
    expect(decoded.modifiers, RemoteModifiers.control);
  });

  test('组合键消息携带主键与修饰位', () {
    final Map<String, dynamic> msg =
        jsonDecode(RemoteControlMessage.combo('c',
                modifiers: RemoteModifiers.control | RemoteModifiers.shift))
            as Map<String, dynamic>;
    expect(msg['t'], 'combo');
    expect(msg['key'], 'c');
    expect(msg['mod'], RemoteModifiers.control | RemoteModifiers.shift);
  });

  test('触摸消息携带触点数组', () {
    final Map<String, dynamic> msg = jsonDecode(
      RemoteControlMessage.touch('down', <Map<String, int>>[
        <String, int>{'x': 10, 'y': 20, 'id': 0},
        <String, int>{'x': 30, 'y': 40, 'id': 1},
      ]),
    ) as Map<String, dynamic>;
    expect(msg['t'], 'touch');
    expect((msg['points'] as List).length, 2);
  });

  test('常见组合键表包含复制/粘贴/全选/锁屏', () {
    final Set<String> keys = RemoteCombos.common.map((RemoteComboSpec c) =>
        '${c.key}:${c.modifiers}').toSet();
    expect(keys, contains('c:${RemoteModifiers.control}'));
    expect(keys, contains('v:${RemoteModifiers.control}'));
    expect(keys, contains('a:${RemoteModifiers.control}'));
    expect(keys, contains('l:${RemoteModifiers.meta}'));
  });

  test('主修饰键在 macOS 解析为 Cmd，Windows 解析为 Ctrl', () {
    expect(
      RemoteKeyMap.primaryControlKey(TargetPlatform.macOS),
      'metaLeft',
    );
    expect(
      RemoteKeyMap.primaryControlKey(TargetPlatform.windows),
      'controlLeft',
    );
    final List<String> mods = RemoteKeyMap.modifierKeysFor(
      RemoteModifiers.control | RemoteModifiers.shift,
      platform: TargetPlatform.macOS,
    );
    expect(mods, <String>['metaLeft', 'shiftLeft']);
  });
}
