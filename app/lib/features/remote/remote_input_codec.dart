// 远控输入编码：指针事件使用 16 字节二进制（低延迟），按键/文本/文件元数据
// 使用 JSON 文本消息。键名采用跨平台稳定的逻辑名（a、digit0、minus、
// controlLeft…），由各平台注入器映射为本机键码。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 指针/按键修饰位。
class RemoteModifiers {
  static const int shift = 1;
  static const int control = 2;
  static const int alt = 4;
  static const int meta = 8;
}

/// 鼠标按键位。
class RemoteButtons {
  static const int left = 1;
  static const int right = 2;
  static const int middle = 4;
}

/// 指针事件类型。
enum RemotePointerType {
  move(1),
  button(2),
  wheel(3);

  const RemotePointerType(this.code);
  final int code;

  static RemotePointerType? fromCode(int code) {
    for (final RemotePointerType t in RemotePointerType.values) {
      if (t.code == code) {
        return t;
      }
    }
    return null;
  }
}

/// 一次指针事件；[xNorm]/[yNorm] 为相对当前屏幕的 0..65535 归一化坐标。
class RemotePointerEvent {
  const RemotePointerEvent({
    required this.type,
    required this.xNorm,
    required this.yNorm,
    this.buttons = 0,
    this.wheelX = 0,
    this.wheelY = 0,
    this.modifiers = 0,
    this.displayIndex = 0,
  });

  final RemotePointerType type;
  final int xNorm;
  final int yNorm;
  final int buttons;
  final int wheelX;
  final int wheelY;
  final int modifiers;
  final int displayIndex;
}

/// 指针事件二进制编解码。
class RemotePointerCodec {
  static const int length = 16;

  static Uint8List encode(RemotePointerEvent event) {
    final ByteData data = ByteData(length);
    data.setUint8(0, event.type.code);
    data.setUint8(1, event.buttons & 0xFF);
    data.setUint16(2, event.xNorm.clamp(0, 65535), Endian.little);
    data.setUint16(4, event.yNorm.clamp(0, 65535), Endian.little);
    data.setInt16(6, event.wheelY.clamp(-32768, 32767), Endian.little);
    data.setInt16(8, event.wheelX.clamp(-32768, 32767), Endian.little);
    data.setUint8(10, event.modifiers & 0xFF);
    data.setUint8(11, event.displayIndex.clamp(0, 255));
    return data.buffer.asUint8List();
  }

  static RemotePointerEvent? decode(Uint8List bytes) {
    if (bytes.length < length) {
      return null;
    }
    final ByteData data = ByteData.sublistView(bytes, 0, length);
    final RemotePointerType? type =
        RemotePointerType.fromCode(data.getUint8(0));
    if (type == null) {
      return null;
    }
    return RemotePointerEvent(
      type: type,
      xNorm: data.getUint16(2, Endian.little),
      yNorm: data.getUint16(4, Endian.little),
      buttons: data.getUint8(1),
      wheelY: data.getInt16(6, Endian.little),
      wheelX: data.getInt16(8, Endian.little),
      modifiers: data.getUint8(10),
      displayIndex: data.getUint8(11),
    );
  }
}

/// 控制通道 JSON 消息工具。
class RemoteControlMessage {
  static String pointer(RemotePointerEvent event) =>
      jsonEncode(<String, dynamic>{'t': 'pointer'});

  static String button(
    int xNorm,
    int yNorm, {
    required int buttons,
    int modifiers = 0,
    int displayIndex = 0,
  }) =>
      jsonEncode(<String, dynamic>{
        't': 'button',
        'x': xNorm,
        'y': yNorm,
        'b': buttons,
        'mod': modifiers,
        'd': displayIndex,
      });

  static String wheel(
    int xNorm,
    int yNorm, {
    required int delta,
    int modifiers = 0,
    int displayIndex = 0,
  }) =>
      jsonEncode(<String, dynamic>{
        't': 'wheel',
        'x': xNorm,
        'y': yNorm,
        'delta': delta,
        'mod': modifiers,
        'd': displayIndex,
      });

  static String key(String key, {required bool down, int modifiers = 0}) =>
      jsonEncode(<String, dynamic>{
        't': 'key',
        'key': key,
        'down': down,
        'mod': modifiers,
      });

  static String text(String text) =>
      jsonEncode(<String, dynamic>{'t': 'text', 'text': text});

  static String clipboard(String text) =>
      jsonEncode(<String, dynamic>{'t': 'clip', 'text': text});

  static String clipboardRequest() =>
      jsonEncode(<String, dynamic>{'t': 'clipRequest'});

  static String stats(Map<String, dynamic> stats) =>
      jsonEncode(<String, dynamic>{'t': 'stats', 'stats': stats});

  static String fileOffer({
    required String id,
    required String name,
    required int size,
    required String mime,
    required int chunks,
  }) =>
      jsonEncode(<String, dynamic>{
        't': 'fileOffer',
        'id': id,
        'name': name,
        'size': size,
        'mime': mime,
        'chunks': chunks,
      });

  static String fileAccept(String id) =>
      jsonEncode(<String, dynamic>{'t': 'fileAccept', 'id': id});

  static String fileReject(String id, {String reason = ''}) =>
      jsonEncode(<String, dynamic>{
        't': 'fileReject',
        'id': id,
        'reason': reason,
      });

  static String fileDone(String id, {bool ok = true}) =>
      jsonEncode(<String, dynamic>{'t': 'fileDone', 'id': id, 'ok': ok});

  static String heartbeat() => jsonEncode(<String, dynamic>{'t': 'ping'});
}

/// 跨平台逻辑键名 ↔ 各系统键码。
class RemoteKeyMap {
  /// 逻辑键名集合（与注入器映射表保持一致）。
  static const Set<String> supportedKeys = <String>{
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
    'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'digit0', 'digit1', 'digit2', 'digit3', 'digit4', 'digit5', 'digit6',
    'digit7', 'digit8', 'digit9',
    'minus', 'equal', 'bracketLeft', 'bracketRight', 'backslash',
    'semicolon', 'quote', 'comma', 'period', 'slash', 'backquote',
    'enter', 'tab', 'space', 'backspace', 'escape', 'delete',
    'arrowUp', 'arrowDown', 'arrowLeft', 'arrowRight',
    'home', 'end', 'pageUp', 'pageDown',
    'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10',
    'f11', 'f12',
    'shiftLeft', 'shiftRight', 'controlLeft', 'controlRight',
    'altLeft', 'altRight', 'metaLeft', 'metaRight', 'capsLock',
  };

  /// Flutter 逻辑键 → 逻辑键名；不支持的键返回 null。
  static String? fromLogicalKey(LogicalKeyboardKey key) {
    final String label = key.keyLabel.toLowerCase();
    if (label.length == 1 &&
        ((label.codeUnitAt(0) >= 0x61 && label.codeUnitAt(0) <= 0x7A))) {
      return label;
    }
    if (key == LogicalKeyboardKey.digit0) return 'digit0';
    if (key == LogicalKeyboardKey.digit1) return 'digit1';
    if (key == LogicalKeyboardKey.digit2) return 'digit2';
    if (key == LogicalKeyboardKey.digit3) return 'digit3';
    if (key == LogicalKeyboardKey.digit4) return 'digit4';
    if (key == LogicalKeyboardKey.digit5) return 'digit5';
    if (key == LogicalKeyboardKey.digit6) return 'digit6';
    if (key == LogicalKeyboardKey.digit7) return 'digit7';
    if (key == LogicalKeyboardKey.digit8) return 'digit8';
    if (key == LogicalKeyboardKey.digit9) return 'digit9';
    const Map<int, String> special = <int, String>{
      0x0000000002d: 'minus', // 兼容部分平台的 keyId 形态
    };
    final String? direct = special[key.keyId];
    if (direct != null) {
      return direct;
    }
    if (key == LogicalKeyboardKey.minus) return 'minus';
    if (key == LogicalKeyboardKey.equal) return 'equal';
    if (key == LogicalKeyboardKey.bracketLeft) return 'bracketLeft';
    if (key == LogicalKeyboardKey.bracketRight) return 'bracketRight';
    if (key == LogicalKeyboardKey.backslash) return 'backslash';
    if (key == LogicalKeyboardKey.semicolon) return 'semicolon';
    if (key == LogicalKeyboardKey.quote) return 'quote';
    if (key == LogicalKeyboardKey.comma) return 'comma';
    if (key == LogicalKeyboardKey.period) return 'period';
    if (key == LogicalKeyboardKey.slash) return 'slash';
    if (key == LogicalKeyboardKey.backquote) return 'backquote';
    if (key == LogicalKeyboardKey.enter) return 'enter';
    if (key == LogicalKeyboardKey.numpadEnter) return 'enter';
    if (key == LogicalKeyboardKey.tab) return 'tab';
    if (key == LogicalKeyboardKey.space) return 'space';
    if (key == LogicalKeyboardKey.backspace) return 'backspace';
    if (key == LogicalKeyboardKey.escape) return 'escape';
    if (key == LogicalKeyboardKey.delete) return 'delete';
    if (key == LogicalKeyboardKey.arrowUp) return 'arrowUp';
    if (key == LogicalKeyboardKey.arrowDown) return 'arrowDown';
    if (key == LogicalKeyboardKey.arrowLeft) return 'arrowLeft';
    if (key == LogicalKeyboardKey.arrowRight) return 'arrowRight';
    if (key == LogicalKeyboardKey.home) return 'home';
    if (key == LogicalKeyboardKey.end) return 'end';
    if (key == LogicalKeyboardKey.pageUp) return 'pageUp';
    if (key == LogicalKeyboardKey.pageDown) return 'pageDown';
    if (key == LogicalKeyboardKey.f1) return 'f1';
    if (key == LogicalKeyboardKey.f2) return 'f2';
    if (key == LogicalKeyboardKey.f3) return 'f3';
    if (key == LogicalKeyboardKey.f4) return 'f4';
    if (key == LogicalKeyboardKey.f5) return 'f5';
    if (key == LogicalKeyboardKey.f6) return 'f6';
    if (key == LogicalKeyboardKey.f7) return 'f7';
    if (key == LogicalKeyboardKey.f8) return 'f8';
    if (key == LogicalKeyboardKey.f9) return 'f9';
    if (key == LogicalKeyboardKey.f10) return 'f10';
    if (key == LogicalKeyboardKey.f11) return 'f11';
    if (key == LogicalKeyboardKey.f12) return 'f12';
    if (key == LogicalKeyboardKey.shiftLeft) return 'shiftLeft';
    if (key == LogicalKeyboardKey.shiftRight) return 'shiftRight';
    if (key == LogicalKeyboardKey.controlLeft) return 'controlLeft';
    if (key == LogicalKeyboardKey.controlRight) return 'controlRight';
    if (key == LogicalKeyboardKey.altLeft) return 'altLeft';
    if (key == LogicalKeyboardKey.altRight) return 'altRight';
    if (key == LogicalKeyboardKey.metaLeft) return 'metaLeft';
    if (key == LogicalKeyboardKey.metaRight) return 'metaRight';
    if (key == LogicalKeyboardKey.capsLock) return 'capsLock';
    return null;
  }

  /// 当前按下的修饰键位（来自 Flutter 全局键盘状态）。
  static int currentModifiers() {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    int bits = 0;
    if (keyboard.isShiftPressed) bits |= RemoteModifiers.shift;
    if (keyboard.isControlPressed) bits |= RemoteModifiers.control;
    if (keyboard.isAltPressed) bits |= RemoteModifiers.alt;
    if (keyboard.isMetaPressed) bits |= RemoteModifiers.meta;
    return bits;
  }

  /// macOS 虚拟键码（kVK_*）。
  static const Map<String, int> macVirtualKeys = <String, int>{
    'a': 0, 's': 1, 'd': 2, 'f': 3, 'h': 4, 'g': 5, 'z': 6, 'x': 7,
    'c': 8, 'v': 9, 'b': 11, 'q': 12, 'w': 13, 'e': 14, 'r': 15,
    'y': 16, 't': 17, 'digit1': 18, 'digit2': 19, 'digit3': 20,
    'digit4': 21, 'digit6': 22, 'digit5': 23, 'equal': 24, 'digit9': 25,
    'digit7': 26, 'minus': 27, 'digit8': 28, 'digit0': 29,
    'bracketRight': 30, 'o': 31, 'u': 32, 'bracketLeft': 33, 'i': 34,
    'p': 35, 'enter': 36, 'l': 37, 'j': 38, 'quote': 39, 'k': 40,
    'semicolon': 41, 'backslash': 42, 'comma': 43, 'slash': 44, 'n': 45,
    'm': 46, 'period': 47, 'tab': 48, 'space': 49, 'backquote': 50,
    'backspace': 51, 'escape': 53, 'metaLeft': 55, 'shiftLeft': 56,
    'capsLock': 57, 'altLeft': 58, 'controlLeft': 59, 'shiftRight': 60,
    'altRight': 61, 'controlRight': 62, 'metaRight': 54,
    'f1': 122, 'f2': 120, 'f3': 99, 'f4': 118, 'f5': 96, 'f6': 97,
    'f7': 98, 'f8': 100, 'f9': 101, 'f10': 109, 'f11': 103, 'f12': 111,
    'home': 115, 'end': 119, 'pageUp': 116, 'pageDown': 121,
    'delete': 117, 'arrowLeft': 123, 'arrowRight': 124, 'arrowDown': 125,
    'arrowUp': 126,
  };

  /// Windows 虚拟键码（VK_*）。
  static const Map<String, int> windowsVirtualKeys = <String, int>{
    'a': 0x41, 'b': 0x42, 'c': 0x43, 'd': 0x44, 'e': 0x45, 'f': 0x46,
    'g': 0x47, 'h': 0x48, 'i': 0x49, 'j': 0x4A, 'k': 0x4B, 'l': 0x4C,
    'm': 0x4D, 'n': 0x4E, 'o': 0x4F, 'p': 0x50, 'q': 0x51, 'r': 0x52,
    's': 0x53, 't': 0x54, 'u': 0x55, 'v': 0x56, 'w': 0x57, 'x': 0x58,
    'y': 0x59, 'z': 0x5A,
    'digit0': 0x30, 'digit1': 0x31, 'digit2': 0x32, 'digit3': 0x33,
    'digit4': 0x34, 'digit5': 0x35, 'digit6': 0x36, 'digit7': 0x37,
    'digit8': 0x38, 'digit9': 0x39,
    'semicolon': 0xBA, 'equal': 0xBB, 'comma': 0xBC, 'minus': 0xBD,
    'period': 0xBE, 'slash': 0xBF, 'backquote': 0xC0, 'bracketLeft': 0xDB,
    'backslash': 0xDC, 'bracketRight': 0xDD, 'quote': 0xDE,
    'enter': 0x0D, 'tab': 0x09, 'space': 0x20, 'backspace': 0x08,
    'escape': 0x1B, 'delete': 0x2E,
    'arrowLeft': 0x25, 'arrowUp': 0x26, 'arrowRight': 0x27,
    'arrowDown': 0x28, 'home': 0x24, 'end': 0x23, 'pageUp': 0x21,
    'pageDown': 0x22,
    'f1': 0x70, 'f2': 0x71, 'f3': 0x72, 'f4': 0x73, 'f5': 0x74,
    'f6': 0x75, 'f7': 0x76, 'f8': 0x77, 'f9': 0x78, 'f10': 0x79,
    'f11': 0x7A, 'f12': 0x7B,
    'shiftLeft': 0xA0, 'shiftRight': 0xA1, 'controlLeft': 0xA2,
    'controlRight': 0xA3, 'altLeft': 0xA4, 'altRight': 0xA5,
    'metaLeft': 0x5B, 'metaRight': 0x5C, 'capsLock': 0x14,
  };

  /// X11 keysym 名称。
  static const Map<String, String> x11Keysyms = <String, String>{
    'a': 'a', 'b': 'b', 'c': 'c', 'd': 'd', 'e': 'e', 'f': 'f', 'g': 'g',
    'h': 'h', 'i': 'i', 'j': 'j', 'k': 'k', 'l': 'l', 'm': 'm', 'n': 'n',
    'o': 'o', 'p': 'p', 'q': 'q', 'r': 'r', 's': 's', 't': 't', 'u': 'u',
    'v': 'v', 'w': 'w', 'x': 'x', 'y': 'y', 'z': 'z',
    'digit0': '0', 'digit1': '1', 'digit2': '2', 'digit3': '3',
    'digit4': '4', 'digit5': '5', 'digit6': '6', 'digit7': '7',
    'digit8': '8', 'digit9': '9',
    'minus': 'minus', 'equal': 'equal', 'bracketLeft': 'bracketleft',
    'bracketRight': 'bracketright', 'backslash': 'backslash',
    'semicolon': 'semicolon', 'quote': 'apostrophe', 'comma': 'comma',
    'period': 'period', 'slash': 'slash', 'backquote': 'grave',
    'enter': 'Return', 'tab': 'Tab', 'space': 'space',
    'backspace': 'BackSpace', 'escape': 'Escape', 'delete': 'Delete',
    'arrowUp': 'Up', 'arrowDown': 'Down', 'arrowLeft': 'Left',
    'arrowRight': 'Right', 'home': 'Home', 'end': 'End',
    'pageUp': 'Prior', 'pageDown': 'Next',
    'f1': 'F1', 'f2': 'F2', 'f3': 'F3', 'f4': 'F4', 'f5': 'F5',
    'f6': 'F6', 'f7': 'F7', 'f8': 'F8', 'f9': 'F9', 'f10': 'F10',
    'f11': 'F11', 'f12': 'F12',
    'shiftLeft': 'Shift_L', 'shiftRight': 'Shift_R',
    'controlLeft': 'Control_L', 'controlRight': 'Control_R',
    'altLeft': 'Alt_L', 'altRight': 'Alt_R',
    'metaLeft': 'Super_L', 'metaRight': 'Super_R', 'capsLock': 'Caps_Lock',
  };
}
