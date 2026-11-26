// 控制端全屏远控页：画面、指针/触控输入、键盘、剪贴板、文件、多屏与画质。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 'remote_control_service.dart';
import 'remote_input_codec.dart';
import 'remote_session.dart';
import 'remote_video_view.dart';

/// 顶栏会话切换项：同时控制多台设备时使用。
class RemoteSessionTab {
  const RemoteSessionTab({
    required this.peer,
    required this.name,
    required this.active,
  });

  final String peer;
  final String name;
  final bool active;
}

class RemoteControlPage extends StatefulWidget {
  const RemoteControlPage({
    super.key,
    required this.info,
    this.service,
    this.onClose,
    this.onSendFile,
    this.onShowMessage,
    this.sessions = const <RemoteSessionTab>[],
    this.onSelectSession,
  });

  final RemoteInfo info;
  final RemoteControlService? service;
  final VoidCallback? onClose;

  /// 选择并发送文件；由壳层注入平台文件选择器。
  final Future<void> Function()? onSendFile;
  final ValueChanged<String>? onShowMessage;

  /// 其他同时进行的远控会话，供顶栏切换。
  final List<RemoteSessionTab> sessions;
  final ValueChanged<String>? onSelectSession;

  @override
  State<RemoteControlPage> createState() => _RemoteControlPageState();
}

class _RemoteControlPageState extends State<RemoteControlPage> {
  final FocusNode _focus = FocusNode(debugLabel: 'remote-control');
  final TextEditingController _text = TextEditingController();
  final Map<int, Offset> _pointers = <int, Offset>{};
  Rect? _videoRect;
  int _buttons = 0;
  Offset? _lastCentroid;
  Timer? _longPress;
  bool _longPressFired = false;
  Offset? _lastTouch;
  bool _showKeyboard = false;
  bool _showTouchpad = false;
  double _padX = 32768;
  double _padY = 32768;

  RemoteControlService? get _service => widget.service;

  @override
  void dispose() {
    _longPress?.cancel();
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  bool get _canInput =>
      widget.info.state == RemoteState.active &&
      widget.info.permissions.input &&
      _service != null;

  void _show(String message) => widget.onShowMessage?.call(message);

  @override
  Widget build(BuildContext context) {
    final RemoteInfo info = widget.info;
    if (info.isTerminal) {
      return Scaffold(
        backgroundColor: const Color(0xFF0E1013),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    info.state == RemoteState.failed
                        ? Icons.error_outline
                        : Icons.link_off,
                    color: Colors.white54,
                    size: 44,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    info.error.isEmpty ? context.t('远程控制已结束') : info.error,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey<String>('remote-closed-confirm'),
                    onPressed: _close,
                    child: Text(context.t('关闭')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0E1013),
      body: SafeArea(
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Rect rect = _contentRect(constraints.biggest);
              _videoRect = rect;
              return Stack(
                children: <Widget>[
                  Positioned.fromRect(
                    rect: rect,
                    child: RemoteVideoView(renderer: _service?.remoteRenderer),
                  ),
                  Positioned.fromRect(
                    rect: rect,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerUp,
                      onPointerHover: _onPointerHover,
                      onPointerSignal: _onPointerSignal,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: _buildTopBar(context),
                  ),
                  if (info.state == RemoteState.outgoing ||
                      info.state == RemoteState.connecting ||
                      info.state == RemoteState.reconnecting)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black38,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const CircularProgressIndicator(
                                  color: Colors.white70,
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  context.t(info.state.label),
                                  style: const TextStyle(color: Colors.white70),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _buildBottomBar(context),
                  ),
                  if (info.error.isNotEmpty)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 92,
                      child: _errorBanner(context, info.error),
                    ),
                  if (info.fileTotal > 0)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 132,
                      child: _fileProgress(context, info),
                    ),
                  if (_showKeyboard)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildKeyboardBar(context),
                    ),
                  if (_showTouchpad)
                    Positioned(
                      right: 16,
                      bottom: 150,
                      child: _buildTouchpad(context),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Rect _contentRect(Size size) {
    final RemoteInfo info = widget.info;
    final double vw = (info.stats.width > 0
            ? info.stats.width
            : info.display?.pixelWidth ?? 1920)
        .toDouble();
    final double vh = (info.stats.height > 0
            ? info.stats.height
            : info.display?.pixelHeight ?? 1080)
        .toDouble();
    if (vw <= 0 || vh <= 0) {
      return Offset.zero & size;
    }
    final double scale = math.min(size.width / vw, size.height / vh);
    final double width = vw * scale;
    final double height = vh * scale;
    return Rect.fromLTWH(
      (size.width - width) / 2,
      (size.height - height) / 2,
      width,
      height,
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final RemoteInfo info = widget.info;
    final String stats = info.stats.fps > 0
        ? '${info.stats.fps.toStringAsFixed(0)} fps'
            ' · ${info.stats.rttMs} ms'
            '${info.stats.bitrateKbps > 0 ? ' · ${info.stats.bitrateKbps} kbps' : ''}'
            '${info.stats.packetLoss > 0.005 ? ' · ${context.t('丢包')} ${(info.stats.packetLoss * 100).toStringAsFixed(1)}%' : ''}'
        : info.state.label;
    final String subtitle =
        '${info.display?.name ?? ''}  $stats'
        '${info.permissions.input ? '' : '  · ${context.t('仅查看')}'}';
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('remote-back'),
            tooltip: context.t('结束远控'),
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _end,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  info.peerName.isEmpty ? info.peer : info.peerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          if (widget.sessions.length > 1 &&
              widget.onSelectSession != null)
            PopupMenuButton<String>(
              key: const ValueKey<String>('remote-sessions'),
              tooltip: context.t('切换设备'),
              icon: const Icon(Icons.devices, color: Colors.white),
              onSelected: widget.onSelectSession,
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<String>>[
                for (final RemoteSessionTab tab in widget.sessions)
                  PopupMenuItem<String>(
                    value: tab.peer,
                    child: Text('${tab.active ? '✓ ' : ''}${tab.name}'),
                  ),
              ],
            ),
          if (info.displays.length > 1)
            PopupMenuButton<RemoteDisplay>(
              key: const ValueKey<String>('remote-displays'),
              tooltip: context.t('切换屏幕'),
              icon: const Icon(Icons.monitor, color: Colors.white),
              onSelected: (RemoteDisplay display) {
                unawaited(_service?.switchDisplay(display));
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<RemoteDisplay>>[
                for (final RemoteDisplay d in info.displays)
                  PopupMenuItem<RemoteDisplay>(
                    value: d,
                    child: Text('${d.name}  ${d.width}×${d.height}'),
                  ),
              ],
            ),
          PopupMenuButton<RemoteQuality>(
            key: const ValueKey<String>('remote-quality'),
            tooltip: context.t('画质'),
            icon: const Icon(Icons.tune, color: Colors.white),
            onSelected: (RemoteQuality quality) {
              unawaited(_service?.setQuality(quality));
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<RemoteQuality>>[
              for (final RemoteQuality q in RemoteQuality.values)
                PopupMenuItem<RemoteQuality>(
                  value: q,
                  child: Text(
                    '${q.label}（${q.maxFps}fps）'
                    '${q == info.quality ? ' ✓' : ''}',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          _toolButton(
            key: 'remote-clipboard-send',
            icon: Icons.content_paste,
            label: context.t('发送剪贴板'),
            onTap: widget.info.permissions.clipboard ? _sendClipboard : null,
          ),
          _toolButton(
            key: 'remote-clipboard-get',
            icon: Icons.content_paste_go,
            label: context.t('获取剪贴板'),
            onTap: widget.info.permissions.clipboard ? _requestClipboard : null,
          ),
          _toolButton(
            key: 'remote-file',
            icon: Icons.upload_file,
            label: context.t('发送文件'),
            onTap: widget.info.permissions.file ? widget.onSendFile : null,
          ),
          _toolButton(
            key: 'remote-keyboard',
            icon: Icons.keyboard,
            label: context.t('键盘'),
            onTap: () {
              setState(() => _showKeyboard = !_showKeyboard);
              if (_showKeyboard) {
                _focus.unfocus();
              } else {
                _focus.requestFocus();
              }
            },
          ),
          _toolButton(
            key: 'remote-touchpad',
            icon: Icons.touch_app,
            label: context.t('触控板'),
            onTap: () => setState(() => _showTouchpad = !_showTouchpad),
          ),
          _toolButton(
            key: 'remote-end',
            icon: Icons.power_settings_new,
            label: context.t('断开'),
            danger: true,
            onTap: _end,
          ),
        ],
      ),
    );
  }

  Widget _toolButton({
    required String key,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool danger = false,
  }) {
    return InkWell(
      key: ValueKey<String>(key),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 20,
              color: onTap == null
                  ? Colors.white24
                  : danger
                      ? Colors.redAccent
                      : Colors.white70,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: onTap == null ? Colors.white24 : Colors.white60,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyboardBar(BuildContext context) {
    const List<(String, String)> keys = <(String, String)>[
      ('Esc', 'escape'),
      ('Tab', 'tab'),
      ('Enter', 'enter'),
      ('⌫', 'backspace'),
      ('←', 'arrowLeft'),
      ('↑', 'arrowUp'),
      ('↓', 'arrowDown'),
      ('→', 'arrowRight'),
    ];
    return Container(
      color: const Color(0xFF1A1D21),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('remote-text-field'),
                  controller: _text,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: context.t('输入文字，回车发送到被控端'),
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white10,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (String value) => _sendText(value),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey<String>('remote-text-send'),
                onPressed: () => _sendText(_text.text),
                child: Text(context.t('发送')),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final (String label, String key) in keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: OutlinedButton(
                      key: ValueKey<String>('remote-key-$key'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      onPressed: _canInput
                          ? () => _sendKeyTap(key)
                          : null,
                      child: Text(label),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTouchpad(BuildContext context) {
    return GestureDetector(
      onPanStart: (DragStartDetails details) {
        _lastTouch = details.localPosition;
        _sendPointer(
          RemotePointerType.button,
          _padPosition(),
          buttons: RemoteButtons.left,
        );
      },
      onPanUpdate: (DragUpdateDetails details) {
        final Offset? last = _lastTouch;
        if (last == null) {
          return;
        }
        _padX = (_padX + details.delta.dx * 3).clamp(0, 65535);
        _padY = (_padY + details.delta.dy * 3).clamp(0, 65535);
        _sendPointer(RemotePointerType.move, _padPosition());
      },
      onPanEnd: (DragEndDetails details) {
        _lastTouch = null;
        _sendPointer(RemotePointerType.button, _padPosition(), buttons: 0);
      },
      onTap: () {
        _sendPointer(
          RemotePointerType.button,
          _padPosition(),
          buttons: RemoteButtons.left,
        );
        _sendPointer(RemotePointerType.button, _padPosition(), buttons: 0);
      },
      child: Container(
        width: 220,
        height: 140,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: const Center(
          child: Icon(Icons.touch_app, color: Colors.white38),
        ),
      ),
    );
  }

  Offset _padPosition() => Offset(_padX, _padY);

  Widget _errorBanner(BuildContext context, String error) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC5A1E1E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        error,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  Widget _fileProgress(BuildContext context, RemoteInfo info) {
    final double value = info.fileTotal <= 0
        ? 0
        : (info.fileProgress / info.fileTotal).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${context.t('发送文件')}：${info.fileName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: value,
            minHeight: 4,
            backgroundColor: Colors.white12,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 指针
  // ---------------------------------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (!_canInput) {
      return;
    }
    _focus.requestFocus();
    if (event.kind == PointerDeviceKind.mouse) {
      _buttons = _maskOf(event.buttons);
      _sendPointer(
        RemotePointerType.button,
        event.localPosition,
        buttons: _buttons,
      );
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 1) {
      _longPressFired = false;
      _sendPointer(
        RemotePointerType.button,
        event.localPosition,
        buttons: RemoteButtons.left,
      );
      _buttons = RemoteButtons.left;
      _longPress?.cancel();
      _longPress = Timer(const Duration(milliseconds: 650), () {
        if (_pointers.length != 1 || _longPressFired) {
          return;
        }
        final Offset at = _pointers.values.first;
        _longPressFired = true;
        _buttons = 0;
        _sendPointer(RemotePointerType.button, at, buttons: 0);
        _sendPointer(
          RemotePointerType.button,
          at,
          buttons: RemoteButtons.right,
        );
        _sendPointer(RemotePointerType.button, at, buttons: 0);
      });
    } else if (_pointers.length == 2) {
      _longPress?.cancel();
      // 第二根手指落下时结束单指左键，避免滚动时误拖拽。
      if (_buttons != 0) {
        _buttons = 0;
        _sendPointer(
          RemotePointerType.button,
          event.localPosition,
          buttons: 0,
        );
      }
      _lastCentroid = _centroid();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_canInput) {
      return;
    }
    if (event.kind == PointerDeviceKind.mouse) {
      final int mask = _maskOf(event.buttons);
      if (mask != _buttons) {
        _buttons = mask;
        _sendPointer(
          RemotePointerType.button,
          event.localPosition,
          buttons: mask,
        );
      }
      _sendPointer(
        RemotePointerType.move,
        event.localPosition,
        buttons: mask,
      );
      return;
    }
    if (!_pointers.containsKey(event.pointer)) {
      return;
    }
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length >= 2) {
      final Offset now = _centroid();
      final Offset? last = _lastCentroid;
      _lastCentroid = now;
      if (last != null) {
        final int delta = (-(now.dy - last.dy) / 8).round();
        if (delta != 0) {
          _sendPointer(
            RemotePointerType.wheel,
            now,
            wheelY: delta.clamp(-10, 10),
          );
        }
      }
      return;
    }
    _sendPointer(
      RemotePointerType.move,
      event.localPosition,
      buttons: _buttons,
    );
  }

  void _onPointerUp(PointerEvent event) {
    if (!_canInput) {
      return;
    }
    if (event.kind == PointerDeviceKind.mouse) {
      _buttons = _maskOf(event.buttons);
      _sendPointer(
        RemotePointerType.button,
        event.localPosition,
        buttons: _buttons,
      );
      return;
    }
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) {
      _longPress?.cancel();
      if (!_longPressFired) {
        _sendPointer(
          RemotePointerType.button,
          event.localPosition,
          buttons: 0,
        );
      }
      _longPressFired = false;
      _buttons = 0;
      _lastCentroid = null;
    } else {
      _lastCentroid = _centroid();
    }
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (!_canInput || _buttons != 0) {
      return;
    }
    _sendPointer(RemotePointerType.move, event.localPosition);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!_canInput || event is! PointerScrollEvent) {
      return;
    }
    final int delta = (-event.scrollDelta.dy / 40).round();
    if (delta == 0) {
      return;
    }
    _sendPointer(
      RemotePointerType.wheel,
      event.localPosition,
      wheelY: delta.clamp(-10, 10),
    );
  }

  Offset _centroid() {
    double x = 0;
    double y = 0;
    for (final Offset p in _pointers.values) {
      x += p.dx;
      y += p.dy;
    }
    final double n = _pointers.length.toDouble();
    return Offset(x / n, y / n);
  }

  int _maskOf(int buttons) {
    int mask = 0;
    if (buttons & kPrimaryButton != 0) mask |= RemoteButtons.left;
    if (buttons & kSecondaryButton != 0) mask |= RemoteButtons.right;
    if (buttons & kMiddleMouseButton != 0) mask |= RemoteButtons.middle;
    return mask;
  }

  void _sendPointer(
    RemotePointerType type,
    Offset position, {
    int buttons = 0,
    int wheelY = 0,
  }) {
    final RemoteControlService? service = _service;
    final Rect? rect = _videoRect;
    if (service == null || rect == null || rect.width <= 0 || rect.height <= 0) {
      return;
    }
    final int x = ((position.dx - rect.left) / rect.width * 65535)
        .clamp(0, 65535)
        .round();
    final int y = ((position.dy - rect.top) / rect.height * 65535)
        .clamp(0, 65535)
        .round();
    unawaited(service.sendPointer(RemotePointerEvent(
      type: type,
      xNorm: x,
      yNorm: y,
      buttons: buttons,
      wheelY: wheelY,
      modifiers: RemoteKeyMap.currentModifiers(),
      displayIndex: widget.info.display?.index ?? 0,
    )));
  }

  // ---------------------------------------------------------------------------
  // 键盘与工具动作
  // ---------------------------------------------------------------------------

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_canInput) {
      return KeyEventResult.ignored;
    }
    final String? name = RemoteKeyMap.fromLogicalKey(event.logicalKey);
    if (name == null) {
      return KeyEventResult.ignored;
    }
    final bool down =
        event is KeyDownEvent || event is KeyRepeatEvent;
    if (event is KeyUpEvent || down) {
      unawaited(_service!.sendKey(
        name,
        down: down,
        modifiers: RemoteKeyMap.currentModifiers(),
      ));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _sendText(String value) {
    if (value.isEmpty) {
      return;
    }
    unawaited(_service?.sendText(value));
    _text.clear();
  }

  /// 一次完整的按键（按下 + 松开），用于手机端补发功能键。
  Future<void> _sendKeyTap(String key) async {
    final RemoteControlService? service = _service;
    if (service == null) {
      return;
    }
    await service.sendKey(key, down: true);
    await service.sendKey(key, down: false);
  }

  Future<void> _sendClipboard() async {
    final String emptyText = context.t('本机剪贴板为空');
    final String sentText = context.t('剪贴板已发送');
    final String failedText = context.t('读取剪贴板失败');
    try {
      final ClipboardData? data = await Clipboard.getData('text/plain');
      final String text = data?.text ?? '';
      if (text.isEmpty) {
        _show(emptyText);
        return;
      }
      await _service?.sendClipboardText(text);
      _show(sentText);
    } on Object {
      _show(failedText);
    }
  }

  Future<void> _requestClipboard() async {
    final String sentText = context.t('已请求对端剪贴板');
    await _service?.requestClipboard();
    _show(sentText);
  }

  void _end() {
    unawaited(_service?.end());
    _close();
  }

  void _close() {
    widget.onClose?.call();
  }
}
