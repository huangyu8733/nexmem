// 控制端全屏远控页：画面、指针/触控输入、键盘、剪贴板、文件、多屏与画质。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/l10n.dart';
import 'remote_control_service.dart';
import 'remote_device_directory.dart';
import 'remote_group_controller.dart';
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
    this.groupController,
    this.onGroupChanged,
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

  /// 群控状态：由壳层持有，跨会话切换保持勾选。
  final RemoteGroupController? groupController;

  /// 群控勾选或开关变化后通知外部重建。
  final VoidCallback? onGroupChanged;

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

  /// 触屏模式：中控端把手势按多点触摸下发，手机控手机/电脑控手机时
  /// 由被控手机的无障碍服务合成真实触摸；桌面被控端仍可用虚拟触控板走鼠标语义。
  /// 手机控制端默认开启，桌面控制端默认鼠标语义，可随时在工具栏切换。
  bool _touchMode = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  double _padX = 32768;
  double _padY = 32768;

  /// 虚拟键盘上的锁存修饰位（Ctrl/Alt/Shift/Win），点击后持续生效，
  /// 直到再次点击取消或发送一个组合键后自动清除。
  int _latchedModifiers = 0;

  /// 捏合缩放的基准比例；_pinching 为 true 时暂停单指/双指滚动处理。
  double? _pinchStartScale;
  bool _pinching = false;

  /// 双指点击检测：第二指落下时记录时间，短时内两指都抬起且未移动则右键。
  DateTime? _secondFingerDownAt;
  bool _twoFingerTapCandidate = true;

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

  /// 群控生效条件：开关已打开且至少勾选了两台设备。
  bool get _groupActive {
    final RemoteGroupController? group = widget.groupController;
    return group != null && group.enabled && group.targetCount > 1;
  }

  void _show(String message) => widget.onShowMessage?.call(message);

  /// 点击画面、顶栏或其它工具时收起虚拟键盘；键盘按钮自身除外。
  void _dismissKeyboard() {
    if (_showKeyboard && mounted) {
      setState(() => _showKeyboard = false);
    }
  }

  /// 打开远控设备列表，在面板里勾选设备、开关群控、批量断开。
  void _openDeviceSheet() {
    final RemoteGroupController? group = widget.groupController;
    if (group == null) {
      return;
    }
    group.sync();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171A1F),
      isScrollControlled: true,
      builder: (BuildContext _) => RemoteGroupSheet(
        controller: group,
        onChanged: () => setState(() {}),
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }

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
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onScaleEnd: _onScaleEnd,
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
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => _dismissKeyboard(),
                      child: _buildTopBar(context),
                    ),
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

    // 画面只占顶栏与底栏之间的可操作区域，避免边缘被工具栏遮挡点不到。
    // 虚拟键盘展开时进一步上收，保证视频与键盘不重叠。
    const double topInset = 56;
    final double bottomInset = 64 + (_showKeyboard ? 196 : 0);
    final double areaBottom = math.max(topInset + 1, size.height - bottomInset);
    final Rect area = Rect.fromLTRB(0, topInset, size.width, areaBottom);
    if (area.width <= 0 || area.height <= 0) {
      return area;
    }

    final double vw = (info.stats.width > 0
            ? info.stats.width
            : info.display?.pixelWidth ?? 1920)
        .toDouble();
    final double vh = (info.stats.height > 0
            ? info.stats.height
            : info.display?.pixelHeight ?? 1080)
        .toDouble();
    if (vw <= 0 || vh <= 0) {
      return area;
    }
    final double scale = math.min(area.width / vw, area.height / vh);
    final double width = vw * scale;
    final double height = vh * scale;
    return Rect.fromLTWH(
      area.left + (area.width - width) / 2,
      area.top + (area.height - height) / 2,
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
    final RemoteGroupController? group = widget.groupController;
    final String groupLabel = group != null && group.enabled
        ? '  · ${context.t('群控 {0} 台', [group.targetCount])}'
        : '';
    final String subtitle =
        '${info.display?.name ?? ''}  $stats'
        '${info.permissions.input ? '' : '  · ${context.t('仅查看')}'}'
        '$groupLabel';
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
          if (group != null && group.availableTargets.isNotEmpty)
            IconButton(
              key: const ValueKey<String>('remote-group-manage'),
              tooltip: context.t('管理远控设备'),
              icon: const Icon(Icons.devices_other, color: Colors.white),
              onPressed: _openDeviceSheet,
            ),
          if (group != null && group.canGroup)
            IconButton(
              key: const ValueKey<String>('remote-group-toggle'),
              tooltip: context.t('群控模式'),
              icon: Icon(
                group.enabled ? Icons.groups : Icons.groups_outlined,
                color: group.enabled ? Colors.greenAccent : Colors.white,
              ),
              onPressed: () {
                group.setEnabled(!group.enabled);
                setState(() {});
                widget.onGroupChanged?.call();
              },
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
        // 每个按钮可收缩，窄屏/长语种下不会把工具栏挤出屏幕。
        children: <Widget>[
          Flexible(
            child: _toolButton(
              key: 'remote-clipboard-send',
              icon: Icons.content_paste,
              label: context.t('发送剪贴板'),
              onTap: widget.info.permissions.clipboard ? _sendClipboard : null,
            ),
          ),
          Flexible(
            child: _toolButton(
              key: 'remote-clipboard-get',
              icon: Icons.content_paste_go,
              label: context.t('获取剪贴板'),
              onTap:
                  widget.info.permissions.clipboard ? _requestClipboard : null,
            ),
          ),
          Flexible(
            child: _toolButton(
              key: 'remote-file',
              icon: Icons.upload_file,
              label: context.t('发送文件'),
              onTap: widget.info.permissions.file ? widget.onSendFile : null,
            ),
          ),
          Flexible(
            child: _toolButton(
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
          ),
          Flexible(
            child: _toolButton(
              key: 'remote-touchpad',
              icon: Icons.touch_app,
              label: context.t('触控板'),
              onTap: () => setState(() => _showTouchpad = !_showTouchpad),
            ),
          ),
          Flexible(
            child: _toolButton(
              key: 'remote-touch-mode',
              icon: _touchMode ? Icons.smartphone : Icons.mouse,
              label: _touchMode
                  ? context.t('触屏模式')
                  : context.t('鼠标模式'),
              onTap: () => setState(() => _touchMode = !_touchMode),
            ),
          ),
          Flexible(
            child: _toolButton(
              key: 'remote-end',
              icon: Icons.power_settings_new,
              label: context.t('断开'),
              danger: true,
              onTap: _end,
            ),
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
      onTap: onTap == null
          ? null
          : () {
              // 键盘按钮负责自己的开关，其它工具点击时顺手收起键盘。
              if (key != 'remote-keyboard') {
                _dismissKeyboard();
              }
              onTap();
            },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
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
    const List<(String, String)> functionKeys = <(String, String)>[
      ('Esc', 'escape'),
      ('Tab', 'tab'),
      ('Enter', 'enter'),
      // 用 ASCII 标签，避免 iOS 某些字体把 ⌫/←/↑/↓/→/⌘ 渲染成黑方框。
      ('Back', 'backspace'),
      ('Del', 'delete'),
      ('Ins', 'insert'),
      ('Home', 'home'),
      ('End', 'end'),
      ('PgUp', 'pageUp'),
      ('PgDn', 'pageDown'),
      ('Left', 'arrowLeft'),
      ('Up', 'arrowUp'),
      ('Down', 'arrowDown'),
      ('Right', 'arrowRight'),
      ('PrtSc', 'printScreen'),
      ('Menu', 'contextMenu'),
    ];
    const List<(String, int)> modifiers = <(String, int)>[
      ('Ctrl', RemoteModifiers.control),
      ('Alt', RemoteModifiers.alt),
      ('Shift', RemoteModifiers.shift),
      ('Win', RemoteModifiers.meta),
    ];
    final bool apple = _hostIsApple;
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
          // 修饰键锁存：点击后持续生效，组合键发送后自动清除。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final (String label, int bit) in modifiers)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _chipButton(
                      key: 'remote-mod-$label',
                      label: apple && label == 'Ctrl' ? 'Cmd' : label,
                      active: _latchedModifiers & bit != 0,
                      onTap: () => setState(
                        () => _latchedModifiers ^= bit,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 常见组合键快捷栏。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final RemoteComboSpec combo in RemoteCombos.common)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: OutlinedButton(
                      key: ValueKey<String>('remote-combo-${combo.key}-${combo.modifiers}'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        foregroundColor: Colors.white70,
                        // 仅查看时也要保持文字可读，避免整排按钮变成黑方框。
                        disabledForegroundColor: Colors.white54,
                        side: const BorderSide(color: Colors.white24),
                        backgroundColor: Colors.white10,
                        disabledBackgroundColor: Colors.white10,
                      ),
                      onPressed: _canInput
                          ? () => _sendComboTap(
                              combo.key,
                              modifiers: combo.modifiers,
                            )
                          : null,
                      child: Text(combo.displayLabel(apple)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // 功能键 / 导航键 / 扩展键。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final (String label, String key) in functionKeys)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: OutlinedButton(
                      key: ValueKey<String>('remote-key-$key'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        foregroundColor: Colors.white70,
                        // 仅查看时也要保持文字可读，避免整排按钮变成黑方框。
                        disabledForegroundColor: Colors.white54,
                        side: const BorderSide(color: Colors.white24),
                        backgroundColor: Colors.white10,
                        disabledBackgroundColor: Colors.white10,
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

  /// 是否被控端为 Apple 平台（决定组合键文案 Cmd/Ctrl）。
  bool get _hostIsApple {
    final RemoteGroupController? group = widget.groupController;
    if (group != null && group.deviceTypeOf != null) {
      final RemoteDeviceType type = group.typeOf(widget.info.peer);
      if (type == RemoteDeviceType.macos) {
        return true;
      }
    }
    return false;
  }

  Widget _chipButton({
    required String key,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: ValueKey<String>(key),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.tealAccent.withValues(alpha: 0.25) : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? Colors.tealAccent : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.tealAccent : Colors.white70,
            fontSize: 12,
          ),
        ),
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
    // 点击远程画面时收起虚拟键盘，但仍照常下发指针/触摸输入。
    _dismissKeyboard();
    if (!_canInput) {
      return;
    }
    _focus.requestFocus();
    if (_touchMode) {
      _pointers[event.pointer] = event.localPosition;
      _longPress?.cancel();
      _longPressFired = false;
      _secondFingerDownAt = null;
      _twoFingerTapCandidate = true;
      _lastCentroid = null;
      _sendTouchPhase('down');
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
      _secondFingerDownAt = DateTime.now();
      _twoFingerTapCandidate = true;
      _lastCentroid = _centroid();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_canInput) {
      return;
    }
    if (_touchMode) {
      if (!_pointers.containsKey(event.pointer)) {
        return;
      }
      _pointers[event.pointer] = event.localPosition;
      _sendTouchPhase('move');
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
          // 双指发生位移：不是点击，取消右键候选，且缩放中不重复滚动。
          _twoFingerTapCandidate = false;
          if (!_pinching) {
            _sendPointer(
              RemotePointerType.wheel,
              now,
              wheelY: delta.clamp(-10, 10),
            );
          }
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
    if (_touchMode) {
      if (!_pointers.containsKey(event.pointer)) {
        return;
      }
      _pointers[event.pointer] = event.localPosition;
      _sendTouchPhase('up');
      _pointers.remove(event.pointer);
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
    final bool wasTwo = _pointers.length == 2;
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) {
      _longPress?.cancel();
      // 双指点击（两指同时快速落下抬起且未移动）= 右键。
      final bool twoFingerTap = wasTwo &&
          _twoFingerTapCandidate &&
          !_longPressFired &&
          !_pinching &&
          _secondFingerDownAt != null &&
          DateTime.now().difference(_secondFingerDownAt!) <
              const Duration(milliseconds: 400);
      if (twoFingerTap) {
        _sendPointer(
          RemotePointerType.button,
          event.localPosition,
          buttons: RemoteButtons.right,
        );
        _sendPointer(RemotePointerType.button, event.localPosition, buttons: 0);
      } else if (!_longPressFired) {
        _sendPointer(
          RemotePointerType.button,
          event.localPosition,
          buttons: 0,
        );
      }
      _longPressFired = false;
      _buttons = 0;
      _lastCentroid = null;
      _secondFingerDownAt = null;
      _twoFingerTapCandidate = true;
    } else {
      _lastCentroid = _centroid();
    }
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (!_canInput || _buttons != 0 || _touchMode) {
      return;
    }
    _sendPointer(RemotePointerType.move, event.localPosition);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!_canInput || event is! PointerScrollEvent) {
      return;
    }
    final int deltaY = (-event.scrollDelta.dy / 40).round().clamp(-10, 10);
    final int deltaX = (-event.scrollDelta.dx / 40).round().clamp(-10, 10);
    if (deltaY == 0 && deltaX == 0) {
      return;
    }
    // 水平滚动经 wheel 事件的 wheelX 字段下发（触控板双指横滑）。
    final RemoteControlService? service = _service;
    final Rect? rect = _videoRect;
    if (deltaX != 0 && service != null && rect != null) {
      final int x = ((event.localPosition.dx - rect.left) / rect.width * 65535)
          .clamp(0, 65535)
          .round();
      final int y = ((event.localPosition.dy - rect.top) / rect.height * 65535)
          .clamp(0, 65535)
          .round();
      final RemotePointerEvent wheelEvent = RemotePointerEvent(
        type: RemotePointerType.wheel,
        xNorm: x,
        yNorm: y,
        wheelX: deltaX,
        modifiers: RemoteKeyMap.currentModifiers() | _latchedModifiers,
        displayIndex: widget.info.display?.index ?? 0,
      );
      final RemoteGroupController? group = widget.groupController;
      if (_groupActive) {
        unawaited(group!.broadcastPointer(wheelEvent));
      } else {
        unawaited(service.sendPointer(wheelEvent));
      }
    }
    if (deltaY != 0) {
      _sendPointer(
        RemotePointerType.wheel,
        event.localPosition,
        wheelY: deltaY,
      );
    }
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

  // ---------------------------------------------------------------------------
  // 捏合缩放 / 双指手势
  // ---------------------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails details) {
    if (!_canInput || details.pointerCount < 2) {
      return;
    }
    // ScaleStartDetails 无 scale 字段，以 1.0 作为捏合基准。
    _pinchStartScale = 1.0;
    _pinching = true;
    // 缩放期间退出单指左键态，避免误拖拽。
    if (_buttons != 0) {
      _buttons = 0;
      _sendPointer(RemotePointerType.button, _centroid(), buttons: 0);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!_canInput || !_pinching || _pinchStartScale == null) {
      return;
    }
    if (details.pointerCount < 2) {
      return;
    }
    final double scale = details.scale / _pinchStartScale!;
    // 把连续比例换算为离散滚轮步数：放大(scale>1) 发送正向 wheel。
    final int steps = ((scale - 1) * 6).round().clamp(-8, 8);
    if (steps == 0 || steps == _lastPinchSteps) {
      return;
    }
    _lastPinchSteps = steps;
    _pinchStartScale = details.scale;
    _sendPointer(
      RemotePointerType.pinch,
      details.focalPoint,
      wheelY: steps,
    );
    // 缩放手势等价于 Ctrl 修饰；通过 modifiers 位下发，注入器按平台解释。
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _pinchStartScale = null;
    _pinching = false;
    _lastPinchSteps = 0;
  }

  int _lastPinchSteps = 0;

  int _maskOf(int buttons) {
    int mask = 0;
    if (buttons & kPrimaryButton != 0) mask |= RemoteButtons.left;
    if (buttons & kSecondaryButton != 0) mask |= RemoteButtons.right;
    if (buttons & kMiddleMouseButton != 0) mask |= RemoteButtons.middle;
    if (buttons & kBackMouseButton != 0) mask |= RemoteButtons.back;
    if (buttons & kForwardMouseButton != 0) mask |= RemoteButtons.forward;
    return mask;
  }

  /// 把当前触点集合按归一化坐标下发到被控端；群控时广播到所有勾选设备。
  void _sendTouchPhase(String phase) {
    final RemoteControlService? service = _service;
    final Rect? rect = _videoRect;
    if (service == null ||
        rect == null ||
        rect.width <= 0 ||
        rect.height <= 0 ||
        _pointers.isEmpty) {
      return;
    }
    final List<Map<String, int>> points = _pointers.entries
        .map(
          (MapEntry<int, Offset> entry) => <String, int>{
            'id': entry.key,
            'x': ((entry.value.dx - rect.left) / rect.width * 65535)
                .clamp(0, 65535)
                .round(),
            'y': ((entry.value.dy - rect.top) / rect.height * 65535)
                .clamp(0, 65535)
                .round(),
          },
        )
        .toList(growable: false);
    final int modifiers = RemoteKeyMap.currentModifiers() | _latchedModifiers;
    final RemoteGroupController? group = widget.groupController;
    if (_groupActive) {
      unawaited(group!.broadcastTouch(phase, points, modifiers: modifiers));
      return;
    }
    unawaited(service.sendTouch(phase, points, modifiers: modifiers));
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
    int modifiers = RemoteKeyMap.currentModifiers() | _latchedModifiers;
    if (type == RemotePointerType.pinch) {
      // 捏合缩放 = Ctrl + 滚轮，补上 control 修饰位。
      modifiers |= RemoteModifiers.control;
    }
    final RemotePointerEvent event = RemotePointerEvent(
      type: type,
      xNorm: x,
      yNorm: y,
      buttons: buttons,
      wheelY: wheelY,
      modifiers: modifiers,
      displayIndex: widget.info.display?.index ?? 0,
    );
    final RemoteGroupController? group = widget.groupController;
    if (_groupActive) {
      unawaited(group!.broadcastPointer(event));
      return;
    }
    unawaited(service.sendPointer(event));
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
      final int modifiers =
          RemoteKeyMap.currentModifiers() | _latchedModifiers;
      final RemoteGroupController? group = widget.groupController;
      if (_groupActive) {
        unawaited(group!.broadcastKey(name, down: down, modifiers: modifiers));
      } else {
        unawaited(_service!.sendKey(
          name,
          down: down,
          modifiers: modifiers,
        ));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _sendText(String value) {
    if (value.isEmpty) {
      return;
    }
    final RemoteGroupController? group = widget.groupController;
    if (_groupActive) {
      unawaited(group!.broadcastText(value));
    } else {
      unawaited(_service?.sendText(value));
    }
    _text.clear();
  }

  /// 一次完整的按键（按下 + 松开），用于手机端补发功能键。
  /// 若已锁存修饰键，则升级为原子组合键下发，保证修饰键时序正确。
  Future<void> _sendKeyTap(String key) async {
    if (_latchedModifiers != 0) {
      final int mods = _latchedModifiers;
      setState(() => _latchedModifiers = 0);
      await _sendComboTap(key, modifiers: mods);
      return;
    }
    final RemoteGroupController? group = widget.groupController;
    if (_groupActive) {
      await group!.broadcastKey(key, down: true);
      await group.broadcastKey(key, down: false);
      return;
    }
    final RemoteControlService? service = _service;
    if (service == null) {
      return;
    }
    await service.sendKey(key, down: true);
    await service.sendKey(key, down: false);
  }

  /// 发送一个原子组合键（含常见组合键快捷栏与锁存修饰键）。
  Future<void> _sendComboTap(String key, {int modifiers = 0}) async {
    if (modifiers == 0) {
      await _sendKeyTap(key);
      return;
    }
    final RemoteGroupController? group = widget.groupController;
    if (_groupActive) {
      await group!.broadcastCombo(key, modifiers: modifiers);
      return;
    }
    await _service?.sendCombo(key, modifiers: modifiers);
  }

  Future<void> _sendClipboard() async {
    final String emptyText = context.t('本机剪贴板为空');
    final String sentText = context.t('剪贴板已发送');
    final String failedText = context.t('读取剪贴板失败');
    final RemoteGroupController? group = widget.groupController;
    final String groupSentText = context.t(
      '剪贴板已发送到 {0} 台设备',
      [group?.targetCount ?? 0],
    );
    try {
      final ClipboardData? data = await Clipboard.getData('text/plain');
      final String text = data?.text ?? '';
      if (text.isEmpty) {
        _show(emptyText);
        return;
      }
      if (_groupActive) {
        await group!.broadcastClipboard(text);
        _show(groupSentText);
      } else {
        await _service?.sendClipboardText(text);
        _show(sentText);
      }
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
