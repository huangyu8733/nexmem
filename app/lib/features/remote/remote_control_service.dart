// 远控会话状态机：授权、信令、媒体、输入、剪贴板、文件、自适应与重连。
//
// 与 CallService 完全独立：复用内核 rtc.sendSignal 透传通道，但载荷带
// `"app":"rc"`，由壳层分流。所有媒体与输入数据走 WebRTC DataChannel，
// 只有会话控制信令经过内核。

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../transport/transport.dart';
import 'input/desktop_input_injector.dart';
import 'input/display_geometry.dart';
import 'remote_audit.dart';
import 'remote_crc32.dart';
import 'remote_file.dart';
import 'remote_input_codec.dart';
import 'remote_media.dart';
import 'remote_prefs.dart';
import 'remote_session.dart';
import 'remote_signal.dart';
import 'remote_storage.dart';

/// 被控端待确认的文件。
class RemoteFileOffer {
  const RemoteFileOffer({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.peer,
  });

  final String id;
  final String name;
  final int size;
  final String mime;
  final String peer;
}

class _IncomingFile {
  _IncomingFile({
    required this.name,
    required this.size,
    required this.chunks,
    required this.crc,
  });

  final String name;
  final int size;
  final int chunks;
  final int crc;
  final BytesBuilder builder = BytesBuilder(copy: false);
  int received = 0;
}

class _PendingFile {
  _PendingFile(this.handle, this.completer, this.id);

  final RemoteFileHandle handle;
  final Completer<bool> completer;
  final int id;
}

class RemoteControlService {
  RemoteControlService({
    required this.transport,
    required this.mediaFactory,
    required this.injector,
    DisplayGeometryProvider? geometry,
    RemoteStorage? storage,
    RemoteFileReader? fileReader,
    this.selfAccount = '',
    this.selfName = '',
    this.requestTimeout = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 45),
    this.idleTimeout = const Duration(minutes: 15),
    this.isContact,
    this.canAccept,
    this.onFileOffer,
  })  : _geometry = geometry ?? createDisplayGeometryProvider(),
        _storage = storage ?? createRemoteStorage(),
        _fileReader = fileReader ?? createRemoteFileReader() {
    _audit = RemoteAudit(_storage);
  }

  final CoreTransport transport;
  final RemoteMediaEngine Function() mediaFactory;
  final DesktopInputInjector injector;
  final DisplayGeometryProvider _geometry;
  final RemoteStorage _storage;
  final RemoteFileReader _fileReader;
  final RemotePrefs _prefs = RemotePrefs.instance;
  late final RemoteAudit _audit;

  final String selfAccount;
  String selfName;
  final Duration requestTimeout;
  final Duration connectTimeout;
  Duration idleTimeout;

  /// 仅联系人可发起（由壳层注入通讯录判断）。
  final Future<bool> Function(String peer)? isContact;

  /// 当前是否允许接受远控（例如正在通话时拒绝）。
  final bool Function()? canAccept;

  /// 被控端文件接收确认；为空时按权限自动接受。
  Future<bool> Function(RemoteFileOffer offer)? onFileOffer;

  final StreamController<RemoteInfo> _changes =
      StreamController<RemoteInfo>.broadcast();

  RemoteInfo? _current;
  RemoteMediaEngine? _media;
  final List<StreamSubscription<Object?>> _mediaSubs =
      <StreamSubscription<Object?>>[];

  String _token = '';
  Timer? _requestTimer;
  Timer? _connectTimer;
  Timer? _idleTimer;
  Timer? _statsTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  DateTime? _lastGoodQualityAt;
  int _qualityIndex = RemoteQuality.balanced.index;

  final Map<int, _IncomingFile> _incomingFiles = <int, _IncomingFile>{};
  final Map<int, _PendingFile> _pendingFiles = <int, _PendingFile>{};
  final List<RemoteIceCandidate> _pendingCandidates = <RemoteIceCandidate>[];
  bool _remoteDescriptionSet = false;

  Stream<RemoteInfo> get changes => _changes.stream;
  RemoteInfo? get current => _current;
  bool get isBusy => _current != null && !_current!.isTerminal;

  /// 可作为被控端的平台：桌面三平台 + Android；iOS 与 Web 只做控制端。
  static bool get hostSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.android);

  /// 控制端渲染对象（被控端为 null）。
  Object? get remoteRenderer => _media?.remoteRenderer;

  Future<void> initialize() async {
    await _prefs.load(_storage);
    await _audit.load();
    idleTimeout = Duration(minutes: _prefs.idleMinutes.clamp(1, 240));
    _qualityIndex = _prefs.quality.index;
  }

  void updateSelfName(String name) {
    selfName = name;
  }

  void updatePeerName(String name) {
    final RemoteInfo? info = _current;
    if (info == null || name.isEmpty) {
      return;
    }
    _emit(info.copyWith(peerName: name));
  }

  /// 控制端发起远控。
  Future<void> request(
    String peer, {
    String peerName = '',
    RemotePermissions permissions = RemotePermissions.all,
  }) async {
    if (peer.isEmpty || isBusy) {
      return;
    }
    _resetSessionState();
    final String sid = 'r-${_randomToken(10)}';
    _emit(RemoteInfo(
      sid: sid,
      peer: peer,
      peerName: peerName,
      role: RemoteRole.controller,
      state: RemoteState.outgoing,
      requested: permissions,
      quality: _prefs.quality,
    ));
    _requestTimer = Timer(requestTimeout, () {
      _fail('对方未在限定时间内响应');
    });
    await _send(RemoteSignal(
      type: RemoteSignalType.request,
      sid: sid,
      name: selfName.isEmpty ? _shortId(selfAccount) : selfName,
      permissions: permissions,
    ));
  }

  /// 被控端接受请求。
  Future<void> accept({RemotePermissions? permissions}) async {
    final RemoteInfo? info = _current;
    if (info == null || !info.isHost || info.state != RemoteState.incoming) {
      return;
    }
    _requestTimer?.cancel();
    final RemotePermissions allowed = _prefs.allowed;
    final RemotePermissions wanted = permissions ?? info.requested;
    final bool inputReady = injector.supportsInput &&
        await injector.checkPermissions() == InputPermissionStatus.granted;
    final RemotePermissions granted = RemotePermissions(
      input: wanted.input && allowed.input && inputReady,
      clipboard: wanted.clipboard && allowed.clipboard,
      file: wanted.file && allowed.file,
    );
    debugPrint('[rc] accept wanted=${wanted.set} allowed=${allowed.set} '
        'inputReady=$inputReady granted=${granted.set}');
    _token = _randomToken(32);
    _emit(info.copyWith(
      state: RemoteState.connecting,
      permissions: granted,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
    _connectTimer = Timer(connectTimeout, () => _fail('建立连接超时'));
    await _audit.add(RemoteAuditEntry(
      timeMs: DateTime.now().millisecondsSinceEpoch,
      peer: info.peer,
      direction: 'host',
      permissions: granted,
      action: 'accept',
    ));
    try {
      final RemoteMediaEngine media = mediaFactory();
      _media = media;
      _bindMedia(media);
      final List<RemoteCaptureSource> sources = await media.listSources();
      if (sources.isEmpty) {
        _fail('没有可采集的屏幕');
        return;
      }
      final List<RemoteDisplay> displays = await _pairDisplays(sources);
      final RemoteDisplay display = displays.firstWhere(
        (RemoteDisplay d) => d.primary,
        orElse: () => displays.first,
      );
      await media.startHost(sourceId: display.id, fps: info.quality.maxFps);
      _emit(_current!.copyWith(displays: displays, display: display));
      await _send(RemoteSignal(
        type: RemoteSignalType.accept,
        sid: info.sid,
        token: _token,
        permissions: granted,
        displays: displays,
        displayId: display.id,
        quality: info.quality.name,
      ));
      final String sdp = await media.createOffer();
      await _send(RemoteSignal(
        type: RemoteSignalType.offer,
        sid: info.sid,
        token: _token,
        sdp: sdp,
      ));
    } on Object catch (error) {
      _fail('启动屏幕共享失败：$error');
    }
  }

  /// 被控端拒绝请求。
  Future<void> reject({String reason = '对方拒绝了远程控制'}) async {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    await _send(RemoteSignal(
      type: RemoteSignalType.reject,
      sid: info.sid,
      reason: reason,
    ));
    _finish(RemoteState.ended, reason: reason);
  }

  /// 主动结束会话。
  Future<void> end({String reason = '会话已结束'}) async {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    await _send(RemoteSignal(
      type: RemoteSignalType.end,
      sid: info.sid,
      token: _token,
      reason: reason,
    ));
    _finish(RemoteState.ended, reason: reason);
  }

  /// 被控端暂停控制（保留画面）。
  Future<void> pause() async {
    final RemoteInfo? info = _current;
    if (info == null || !info.isHost || info.state != RemoteState.active) {
      return;
    }
    _emit(info.copyWith(state: RemoteState.paused));
    await _send(RemoteSignal(
      type: RemoteSignalType.pause,
      sid: info.sid,
      token: _token,
    ));
  }

  /// 被控端恢复控制。
  Future<void> resume() async {
    final RemoteInfo? info = _current;
    if (info == null || !info.isHost || info.state != RemoteState.paused) {
      return;
    }
    _emit(info.copyWith(state: RemoteState.active));
    _resetIdle();
    await _send(RemoteSignal(
      type: RemoteSignalType.resume,
      sid: info.sid,
      token: _token,
    ));
  }

  /// 处理来自内核的远控信令。
  Future<void> handleSignal(String peer, String payloadB64) async {
    final RemoteSignal signal;
    try {
      signal = RemoteSignal.fromPayloadB64(payloadB64);
    } on FormatException {
      return;
    }
    if (signal.type == RemoteSignalType.request) {
      debugPrint('[rc] <- request sid=${signal.sid}');
      await _handleRequest(peer, signal);
      return;
    }
    debugPrint('[rc] <- ${signal.type.wireValue} sid=${signal.sid}');
    final RemoteInfo? info = _current;
    if (info == null || info.peer != peer || info.sid != signal.sid) {
      return;
    }
    final bool tokenRequired = signal.type != RemoteSignalType.accept &&
        signal.type != RemoteSignalType.reject &&
        signal.type != RemoteSignalType.request;
    if (tokenRequired && signal.token != _token) {
      return;
    }
    switch (signal.type) {
      case RemoteSignalType.accept:
        await _onAccept(signal);
        break;
      case RemoteSignalType.reject:
        _finish(RemoteState.failed,
            reason: signal.reason.isEmpty ? '对方拒绝了远程控制' : signal.reason);
        break;
      case RemoteSignalType.offer:
        await _onOffer(signal);
        break;
      case RemoteSignalType.answer:
        await _onAnswer(signal);
        break;
      case RemoteSignalType.candidate:
        final RemoteIceCandidate candidate = RemoteIceCandidate(
          candidate: signal.sdp,
          sdpMid: signal.mid,
          sdpMLineIndex: signal.index,
        );
        if (!_remoteDescriptionSet) {
          // 对端描述尚未落地时先缓存，避免 addCandidate 被丢弃。
          _pendingCandidates.add(candidate);
          break;
        }
        try {
          await _media?.addCandidate(candidate);
        } on Object {
          // 迟到/重复候选直接忽略。
        }
        break;
      case RemoteSignalType.end:
        _finish(RemoteState.ended,
            reason: signal.reason.isEmpty ? '对方结束了远程控制' : signal.reason);
        break;
      case RemoteSignalType.pause:
        _emit(info.copyWith(state: RemoteState.paused));
        break;
      case RemoteSignalType.resume:
        _emit(info.copyWith(state: RemoteState.active));
        break;
      case RemoteSignalType.display:
        await _applyDisplay(signal.displayId);
        break;
      case RemoteSignalType.quality:
        await _applyQuality(signal.quality);
        break;
      case RemoteSignalType.clipboard:
        await _onClipboardSignal(signal);
        break;
      case RemoteSignalType.fileOffer:
        await _onFileOffer(signal);
        break;
      case RemoteSignalType.fileAccept:
        _completeFile(signal.fileId, true);
        break;
      case RemoteSignalType.fileReject:
        _completeFile(signal.fileId, false);
        break;
      case RemoteSignalType.fileDone:
        // 文件完成由分片计数触发，这里只做兜底清理。
        break;
      case RemoteSignalType.stats:
        if (signal.stats != null) {
          _emit(info.copyWith(stats: signal.stats));
        }
        break;
      case RemoteSignalType.request:
        break; // 已在前面处理。
    }
  }

  Future<void> _handleRequest(String peer, RemoteSignal signal) async {
    if (!hostSupported) {
      await _sendRaw(peer, RemoteSignal(
        type: RemoteSignalType.reject,
        sid: signal.sid,
        reason: '当前设备仅支持作为控制端',
      ));
      return;
    }
    if (canAccept != null && !canAccept!()) {
      await _sendRaw(peer, RemoteSignal(
        type: RemoteSignalType.reject,
        sid: signal.sid,
        reason: '本机正在进行通话',
      ));
      return;
    }
    if (!_prefs.enabled) {
      await _sendRaw(peer, RemoteSignal(
        type: RemoteSignalType.reject,
        sid: signal.sid,
        reason: '被控端未开启远程控制',
      ));
      return;
    }
    if (isBusy) {
      await _sendRaw(peer, RemoteSignal(
        type: RemoteSignalType.reject,
        sid: signal.sid,
        reason: '对方正在其他远控会话中',
      ));
      return;
    }
    if (isContact != null && !await isContact!(peer)) {
      await _sendRaw(peer, RemoteSignal(
        type: RemoteSignalType.reject,
        sid: signal.sid,
        reason: '仅联系人可以发起远程控制',
      ));
      return;
    }
    _resetSessionState();
    final RemotePermissions requested = RemotePermissions(
      input: signal.permissions.input && _prefs.allowInput,
      clipboard: signal.permissions.clipboard && _prefs.allowClipboard,
      file: signal.permissions.file && _prefs.allowFile,
    );
    _emit(RemoteInfo(
      sid: signal.sid,
      peer: peer,
      peerName: signal.name,
      role: RemoteRole.host,
      state: RemoteState.incoming,
      requested: requested,
      quality: _prefs.quality,
    ));
    await _audit.add(RemoteAuditEntry(
      timeMs: DateTime.now().millisecondsSinceEpoch,
      peer: peer,
      direction: 'host',
      permissions: requested,
      action: 'request',
    ));
    _requestTimer = Timer(requestTimeout, () {
      unawaited(reject(reason: '请求已过期'));
    });
    if (!_prefs.requireConfirm) {
      await accept(permissions: requested);
    }
  }

  Future<void> _onAccept(RemoteSignal signal) async {
    final RemoteInfo? info = _current;
    if (info == null || !info.isController) {
      return;
    }
    _token = signal.token;
    _requestTimer?.cancel();
    final RemoteDisplay? display = signal.displays.isEmpty
        ? null
        : signal.displays.firstWhere(
            (RemoteDisplay d) => d.id == signal.displayId,
            orElse: () => signal.displays.first,
          );
    _emit(info.copyWith(
      state: RemoteState.connecting,
      permissions: signal.permissions,
      displays: signal.displays,
      display: display,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
    _connectTimer = Timer(connectTimeout, () => _fail('建立连接超时'));
    try {
      final RemoteMediaEngine media = mediaFactory();
      _media = media;
      _bindMedia(media);
      await media.startController();
    } on Object catch (error) {
      _fail('初始化媒体失败：$error');
    }
  }

  Future<void> _onOffer(RemoteSignal signal) async {
    final RemoteInfo? info = _current;
    final RemoteMediaEngine? media = _media;
    if (info == null || media == null || signal.sdp.isEmpty) {
      return;
    }
    try {
      await media.setRemoteDescription(signal.sdp, 'offer');
      await _flushCandidates();
      final String answer = await media.createAnswer();
      await _send(RemoteSignal(
        type: RemoteSignalType.answer,
        sid: info.sid,
        token: _token,
        sdp: answer,
      ));
    } on Object catch (error) {
      _fail('处理 SDP 失败：$error');
    }
  }

  Future<void> _onAnswer(RemoteSignal signal) async {
    final RemoteInfo? info = _current;
    final RemoteMediaEngine? media = _media;
    if (info == null || media == null || signal.sdp.isEmpty) {
      return;
    }
    try {
      await media.setRemoteDescription(signal.sdp, 'answer');
      await _flushCandidates();
      _connectTimer?.cancel();
      _reconnectAttempts = 0;
      _emit(info.copyWith(state: RemoteState.active));
      _startActiveTimers();
      await media.setQuality(info.quality);
    } on Object catch (error) {
      _fail('处理 SDP 失败：$error');
    }
  }

  Future<void> _flushCandidates() async {
    _remoteDescriptionSet = true;
    final List<RemoteIceCandidate> pending =
        List<RemoteIceCandidate>.from(_pendingCandidates);
    _pendingCandidates.clear();
    for (final RemoteIceCandidate candidate in pending) {
      try {
        await _media?.addCandidate(candidate);
      } on Object {
        // 单个候选失败不影响其余候选。
      }
    }
  }

  void _bindMedia(RemoteMediaEngine media) {
    _mediaSubs.add(media.onLocalCandidate.listen((RemoteIceCandidate c) {
      unawaited(_send(RemoteSignal(
        type: RemoteSignalType.candidate,
        sid: _current?.sid ?? '',
        token: _token,
        sdp: c.candidate,
        mid: c.sdpMid,
        index: c.sdpMLineIndex,
      ), critical: false));
    }));
    _mediaSubs.add(media.onConnectionState.listen(_onMediaState));
    _mediaSubs.add(media.onControl.listen((String text) {
      if (_current?.isHost ?? false) {
        unawaited(_onHostControl(text));
      } else {
        _onControllerControl(text);
      }
    }));
    _mediaSubs.add(media.onPointer.listen(_onHostPointer));
    _mediaSubs.add(media.onBulk.listen(_onHostBulk));
  }

  void _onMediaState(String state) {
    // 插件在不同平台给出 "RTCPeerConnectionState.connected"、
    // "RTCIceConnectionStateConnected" 等不同写法，统一归一化。
    final String s = state.toLowerCase();
    final String normalized = s.contains('disconnected')
        ? 'disconnected'
        : s.contains('completed')
            ? 'completed'
            : s.contains('connected')
                ? 'connected'
                : s.contains('failed')
                    ? 'failed'
                    : s.contains('closed')
                        ? 'closed'
                        : s;
    debugPrint('[rc] media state=$state -> $normalized');
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    if (normalized == 'connected' || normalized == 'completed') {
      _reconnectTimer?.cancel();
      _reconnectAttempts = 0;
      if (info.state == RemoteState.connecting ||
          info.state == RemoteState.reconnecting) {
        _emit(info.copyWith(state: RemoteState.active));
        _startActiveTimers();
      }
      return;
    }
    if (normalized == 'disconnected' || normalized == 'failed') {
      if (info.state != RemoteState.active &&
          info.state != RemoteState.paused &&
          info.state != RemoteState.reconnecting) {
        return;
      }
      _emit(info.copyWith(state: RemoteState.reconnecting));
      _statsTimer?.cancel();
      if (normalized == 'failed') {
        unawaited(_tryReconnect());
      } else {
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(seconds: 5), () {
          unawaited(_tryReconnect());
        });
      }
    }
  }

  Future<void> _tryReconnect() async {
    final RemoteInfo? info = _current;
    final RemoteMediaEngine? media = _media;
    if (info == null || media == null || info.isTerminal) {
      return;
    }
    _reconnectAttempts++;
    if (_reconnectAttempts > 2) {
      _fail('连接中断，重连失败');
      return;
    }
    _reconnectTimer?.cancel();
    _emit(info.copyWith(state: RemoteState.reconnecting));
    try {
      await media.restartIce();
      if (info.isHost) {
        final String sdp = await media.createOffer(iceRestart: true);
        await _send(RemoteSignal(
          type: RemoteSignalType.offer,
          sid: info.sid,
          token: _token,
          sdp: sdp,
        ));
      }
    } on Object {
      // 交给下一次重试。
    }
    _reconnectTimer = Timer(const Duration(seconds: 10), () {
      unawaited(_tryReconnect());
    });
  }

  void _startActiveTimers() {
    _resetIdle();
    _statsTimer?.cancel();
    if (_current?.isHost ?? false) {
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_sampleStats());
      });
    }
  }

  Future<void> _sampleStats() async {
    final RemoteInfo? info = _current;
    final RemoteMediaEngine? media = _media;
    if (info == null || media == null || !info.isHost) {
      return;
    }
    final RemoteNetworkStats stats = await media.readStats();
    _adaptQuality(stats);
    _emit(_current!.copyWith(stats: stats));
    try {
      await media.sendControl(RemoteControlMessage.stats(stats.toJson()));
    } on Object {
      // 统计上报失败不影响会话。
    }
  }

  void _adaptQuality(RemoteNetworkStats stats) {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    final bool bad = stats.packetLoss > 0.05 || stats.rttMs > 250;
    final bool good = stats.packetLoss < 0.01 && stats.rttMs < 120;
    if (bad && _qualityIndex > 0) {
      _qualityIndex--;
      _lastGoodQualityAt = null;
      unawaited(_applyQualityLocal(RemoteQuality.values[_qualityIndex]));
      return;
    }
    if (!good) {
      _lastGoodQualityAt = null;
      return;
    }
    _lastGoodQualityAt ??= DateTime.now();
    if (_qualityIndex < RemoteQuality.values.length - 1 &&
        DateTime.now().difference(_lastGoodQualityAt!) >
            const Duration(seconds: 15)) {
      _qualityIndex++;
      _lastGoodQualityAt = null;
      unawaited(_applyQualityLocal(RemoteQuality.values[_qualityIndex]));
    }
  }

  Future<void> _applyQualityLocal(RemoteQuality quality) async {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    _emit(info.copyWith(quality: quality));
    await _media?.setQuality(quality);
  }

  Future<void> _applyQuality(String name) async {
    RemoteQuality? quality;
    for (final RemoteQuality q in RemoteQuality.values) {
      if (q.name == name) {
        quality = q;
        break;
      }
    }
    if (quality == null) {
      return;
    }
    _qualityIndex = quality.index;
    await _applyQualityLocal(quality);
  }

  Future<void> _applyDisplay(String displayId) async {
    final RemoteInfo? info = _current;
    if (info == null || displayId.isEmpty) {
      return;
    }
    RemoteDisplay? display;
    for (final RemoteDisplay d in info.displays) {
      if (d.id == displayId) {
        display = d;
        break;
      }
    }
    if (display == null) {
      return;
    }
    try {
      await _media?.switchDisplay(display.id, fps: info.quality.maxFps);
      _emit(_current!.copyWith(display: display));
    } on Object catch (error) {
      _emit(_current!.copyWith(error: '切换屏幕失败：$error'));
    }
  }

  // ---------------------------------------------------------------------------
  // 控制端 → 被控端输入
  // ---------------------------------------------------------------------------

  Future<void> sendPointer(RemotePointerEvent event) async {
    if (!_canInput) {
      return;
    }
    _resetIdle();
    await _media?.sendPointer(RemotePointerCodec.encode(event));
  }

  Future<void> sendKey(
    String key, {
    required bool down,
    int modifiers = 0,
  }) async {
    if (!_canInput) {
      return;
    }
    _resetIdle();
    await _media?.sendControl(
      RemoteControlMessage.key(key, down: down, modifiers: modifiers),
    );
  }

  Future<void> sendText(String text) async {
    if (!_canInput || text.isEmpty) {
      return;
    }
    _resetIdle();
    await _media?.sendControl(RemoteControlMessage.text(text));
  }

  Future<void> sendClipboardText(String text) async {
    final RemoteInfo? info = _current;
    if (info == null || !info.permissions.clipboard || _media == null) {
      return;
    }
    await _send(RemoteSignal(
      type: RemoteSignalType.clipboard,
      sid: info.sid,
      token: _token,
      text: _clipText(text),
    ));
  }

  /// 内核单帧上限 64 KiB，剪贴板留出 JSON 包装余量。
  static String _clipText(String text) {
    final List<int> bytes = utf8.encode(text);
    if (bytes.length <= 60 * 1024) {
      return text;
    }
    return utf8.decode(bytes.sublist(0, 60 * 1024), allowMalformed: true);
  }

  Future<void> requestClipboard() async {
    final RemoteInfo? info = _current;
    if (info == null || !info.permissions.clipboard || _media == null) {
      return;
    }
    await _send(RemoteSignal(
      type: RemoteSignalType.clipboard,
      sid: info.sid,
      token: _token,
      text: '',
    ));
  }

  Future<void> switchDisplay(RemoteDisplay display) async {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    _emit(info.copyWith(display: display));
    await _send(RemoteSignal(
      type: RemoteSignalType.display,
      sid: info.sid,
      token: _token,
      displayId: display.id,
    ));
  }

  Future<void> setQuality(RemoteQuality quality) async {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    _qualityIndex = quality.index;
    _emit(info.copyWith(quality: quality));
    await _send(RemoteSignal(
      type: RemoteSignalType.quality,
      sid: info.sid,
      token: _token,
      quality: quality.name,
    ));
    await _media?.setQuality(quality);
  }

  bool get _canInput {
    final RemoteInfo? info = _current;
    return info != null &&
        info.isController &&
        info.state == RemoteState.active &&
        info.permissions.input;
  }

  Future<void> _onHostControl(String text) async {
    final RemoteInfo? info = _current;
    if (info == null || !info.isHost) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    switch (decoded['t']) {
      case 'key':
        if (!info.permissions.input || info.state != RemoteState.active) {
          return;
        }
        _resetIdle();
        await injector.key(
          '${decoded['key'] ?? ''}',
          down: decoded['down'] == true,
          modifiers: (decoded['mod'] as num?)?.toInt() ?? 0,
        );
      case 'text':
        if (!info.permissions.input || info.state != RemoteState.active) {
          return;
        }
        _resetIdle();
        await _injectText('${decoded['text'] ?? ''}');
      case 'clip':
        if (!info.permissions.clipboard || info.state != RemoteState.active) {
          return;
        }
        await _writeClipboard('${decoded['text'] ?? ''}');
      case 'clipRequest':
        if (!info.permissions.clipboard || info.state != RemoteState.active) {
          return;
        }
        await _sendHostClipboard();
      case 'stats':
        break;
      case 'fileDone':
        break;
    }
  }

  void _onControllerControl(String text) {
    final RemoteInfo? info = _current;
    if (info == null || !info.isController) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    if (decoded['t'] == 'stats') {
      final Object? stats = decoded['stats'];
      if (stats is Map<String, dynamic>) {
        _emit(info.copyWith(stats: RemoteNetworkStats.fromJson(stats)));
      }
    }
  }

  Future<void> _injectText(String text) async {
    if (text.isEmpty) {
      return;
    }
    try {
      await injector.text(text);
      return;
    } on UnsupportedError {
      // 退回剪贴板粘贴。
    }
    if (!(_current?.permissions.clipboard ?? false)) {
      return;
    }
    await _writeClipboard(text);
    final bool meta = defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final String modifier = meta ? 'metaLeft' : 'controlLeft';
    final int mods = meta ? RemoteModifiers.meta : RemoteModifiers.control;
    await injector.key(modifier, down: true, modifiers: mods);
    await injector.key('v', down: true, modifiers: mods);
    await injector.key('v', down: false, modifiers: mods);
    await injector.key(modifier, down: false);
  }

  Future<void> _writeClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on Object {
      // 无剪贴板权限或平台不支持时忽略。
    }
  }

  Future<void> _sendHostClipboard() async {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    String text = '';
    try {
      final ClipboardData? data = await Clipboard.getData('text/plain');
      text = data?.text ?? '';
    } on Object {
      text = '';
    }
    if (text.isEmpty) {
      return;
    }
    await _send(RemoteSignal(
      type: RemoteSignalType.clipboard,
      sid: info.sid,
      token: _token,
      text: _clipText(text),
    ));
  }

  Future<void> _onClipboardSignal(RemoteSignal signal) async {
    final RemoteInfo? info = _current;
    if (info == null || !info.permissions.clipboard) {
      return;
    }
    if (info.isHost) {
      if (signal.text.isEmpty) {
        await _sendHostClipboard();
      } else {
        await _writeClipboard(signal.text);
      }
      return;
    }
    if (signal.text.isNotEmpty) {
      await _writeClipboard(signal.text);
    }
  }

  void _onHostPointer(Uint8List bytes) {
    final RemoteInfo? info = _current;
    if (info == null ||
        !info.isHost ||
        info.state != RemoteState.active ||
        !info.permissions.input) {
      return;
    }
    final RemotePointerEvent? event = RemotePointerCodec.decode(bytes);
    final RemoteDisplay? display = info.display;
    if (event == null || display == null) {
      return;
    }
    _resetIdle();
    unawaited(injector.pointer(event, display: display));
  }

  // ---------------------------------------------------------------------------
  // 文件
  // ---------------------------------------------------------------------------

  Future<bool> sendFile(String path, {String? name}) async {
    final RemoteInfo? info = _current;
    if (info == null || !info.isController || info.state != RemoteState.active) {
      return false;
    }
    RemoteFileHandle? handle;
    try {
      handle = await _fileReader.open(path);
      if (handle.size > 2 * 1024 * 1024 * 1024) {
        _emit(_current!.copyWith(error: '文件超过 2 GB，暂不支持'));
        await handle.close();
        return false;
      }
      final int id = 1 + Random.secure().nextInt(0xFFFFFF);
      final Completer<bool> completer = Completer<bool>();
      _pendingFiles[id] = _PendingFile(handle, completer, id);
      _emit(_current!.copyWith(
        fileName: name ?? handle.name,
        fileTotal: handle.size,
        fileProgress: 0,
      ));
      await _send(RemoteSignal(
        type: RemoteSignalType.fileOffer,
        sid: info.sid,
        token: _token,
        fileId: '$id',
        fileName: name ?? handle.name,
        fileSize: handle.size,
        fileMime: '',
        text: '${handle.crc}',
      ));
      final bool accepted = await completer.future
          .timeout(const Duration(seconds: 45), onTimeout: () => false);
      if (!accepted) {
        _pendingFiles.remove(id);
        await handle.close();
        return false;
      }
      final Uint8List header = Uint8List(8);
      final ByteData headerData = ByteData.sublistView(header);
      headerData.setUint32(0, id, Endian.little);
      int index = 0;
      while (true) {
        final Uint8List? chunk = await handle.nextChunk();
        if (chunk == null) {
          break;
        }
        if (_current == null || _current!.isTerminal) {
          return false;
        }
        headerData.setUint32(4, index, Endian.little);
        final Uint8List packet = Uint8List(8 + chunk.length)
          ..setRange(0, 8, header)
          ..setRange(8, 8 + chunk.length, chunk);
        await _waitBulkWritable();
        await _media?.sendBulk(packet);
        index++;
        _emit(_current!.copyWith(
          fileProgress: (index * _fileReader.chunkSize)
              .clamp(0, _current!.fileTotal),
        ));
      }
      await _media?.sendControl(RemoteControlMessage.fileDone('$id'));
      _emit(_current!.copyWith(fileProgress: _current!.fileTotal));
      unawaited(_resetFileProgressLater());
      await _audit.add(RemoteAuditEntry(
        timeMs: DateTime.now().millisecondsSinceEpoch,
        peer: info.peer,
        direction: 'controller',
        permissions: info.permissions,
        action: 'file-send',
        reason: '${handle.size} bytes',
      ));
      return true;
    } on Object catch (error) {
      _emit(_current!.copyWith(error: '发送文件失败：$error'));
      return false;
    } finally {
      await handle?.close();
      _pendingFiles.removeWhere((int _, _PendingFile p) => p.handle == handle);
    }
  }

  Future<void> _waitBulkWritable() async {
    final RemoteMediaEngine? media = _media;
    if (media == null) {
      return;
    }
    int waited = 0;
    while (!media.bulkWritable) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited += 10;
      if (waited > 15000 || _current == null || _current!.isTerminal) {
        return;
      }
    }
  }

  void _completeFile(String fileId, bool accepted) {
    final int? id = int.tryParse(fileId);
    if (id == null) {
      return;
    }
    final _PendingFile? pending = _pendingFiles[id];
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(accepted);
    }
  }

  Future<void> _onFileOffer(RemoteSignal signal) async {
    final RemoteInfo? info = _current;
    if (info == null || !info.isHost) {
      return;
    }
    final int? id = int.tryParse(signal.fileId);
    if (id == null) {
      return;
    }
    if (!info.permissions.file || info.state != RemoteState.active) {
      await _send(RemoteSignal(
        type: RemoteSignalType.fileReject,
        sid: info.sid,
        token: _token,
        fileId: signal.fileId,
        reason: '未授权文件传输',
      ));
      return;
    }
    final RemoteFileOffer offer = RemoteFileOffer(
      id: signal.fileId,
      name: signal.fileName,
      size: signal.fileSize,
      mime: signal.fileMime,
      peer: info.peer,
    );
    final bool accepted = onFileOffer == null || await onFileOffer!(offer);
    if (!accepted) {
      await _send(RemoteSignal(
        type: RemoteSignalType.fileReject,
        sid: info.sid,
        token: _token,
        fileId: signal.fileId,
        reason: '已拒绝接收',
      ));
      return;
    }
    final int chunks = signal.fileSize == 0
        ? 0
        : (signal.fileSize + _fileReader.chunkSize - 1) ~/
            _fileReader.chunkSize;
    _incomingFiles[id] = _IncomingFile(
      name: signal.fileName,
      size: signal.fileSize,
      chunks: chunks,
      crc: int.tryParse(signal.text) ?? 0,
    );
    _emit(_current!.copyWith(
      fileName: signal.fileName,
      fileTotal: signal.fileSize,
      fileProgress: 0,
    ));
    await _send(RemoteSignal(
      type: RemoteSignalType.fileAccept,
      sid: info.sid,
      token: _token,
      fileId: signal.fileId,
    ));
    if (chunks == 0) {
      _incomingFiles.remove(id);
      await _finishIncomingFile(info.peer, _IncomingFile(
        name: signal.fileName,
        size: 0,
        chunks: 0,
        crc: 0,
      ));
    }
  }

  void _onHostBulk(Uint8List bytes) {
    final RemoteInfo? info = _current;
    if (info == null || !info.isHost || bytes.length < 8) {
      return;
    }
    final ByteData header = ByteData.sublistView(bytes, 0, 8);
    final int id = header.getUint32(0, Endian.little);
    final int index = header.getUint32(4, Endian.little);
    final _IncomingFile? file = _incomingFiles[id];
    if (file == null || index != file.received) {
      return;
    }
    file.builder.add(Uint8List.sublistView(bytes, 8));
    file.received++;
    _emit(_current!.copyWith(
      fileProgress: (file.received * _fileReader.chunkSize)
          .clamp(0, file.size),
    ));
    if (file.received >= file.chunks) {
      _incomingFiles.remove(id);
      unawaited(_finishIncomingFile(info.peer, file));
    }
  }

  Future<void> _finishIncomingFile(String peer, _IncomingFile file) async {
    final Uint8List data = file.builder.takeBytes();
    if (data.length != file.size) {
      _emit(_current!.copyWith(error: '文件接收不完整'));
      return;
    }
    final Crc32 crc = Crc32()..add(data);
    if (crc.value != file.crc) {
      _emit(_current!.copyWith(error: '文件校验失败'));
      return;
    }
    try {
      final String path = await _storage.saveDownload(file.name, data);
      _emit(_current!.copyWith(
        fileProgress: file.size,
        fileName: file.name,
      ));
      unawaited(_resetFileProgressLater());
      await _audit.add(RemoteAuditEntry(
        timeMs: DateTime.now().millisecondsSinceEpoch,
        peer: peer,
        direction: 'host',
        permissions: _current?.permissions ?? RemotePermissions.none,
        action: 'file-receive',
        reason: path,
      ));
    } on Object catch (error) {
      _emit(_current!.copyWith(error: '保存文件失败：$error'));
    }
  }

  // ---------------------------------------------------------------------------
  // 会话收尾
  // ---------------------------------------------------------------------------

  void _finish(RemoteState state, {String reason = ''}) {
    final RemoteInfo? info = _current;
    if (info == null) {
      return;
    }
    _cancelTimers();
    final Future<void> cleanup = _disposeMedia();
    unawaited(cleanup);
    final int started = info.startedAtMs;
    final int duration = started == 0
        ? 0
        : DateTime.now().millisecondsSinceEpoch - started;
    unawaited(_audit.add(RemoteAuditEntry(
      timeMs: DateTime.now().millisecondsSinceEpoch,
      peer: info.peer,
      direction: info.isHost ? 'host' : 'controller',
      permissions: info.permissions,
      action: 'end',
      durationMs: duration,
      reason: reason,
    )));
    _emit(info.copyWith(
      state: state,
      error: state == RemoteState.failed ? reason : '',
      fileProgress: 0,
      fileTotal: 0,
      fileName: '',
    ));
    _clearFileState();
  }

  void _fail(String reason) => _finish(RemoteState.failed, reason: reason);

  void _cancelTimers() {
    _requestTimer?.cancel();
    _connectTimer?.cancel();
    _idleTimer?.cancel();
    _statsTimer?.cancel();
    _reconnectTimer?.cancel();
    _requestTimer = null;
    _connectTimer = null;
    _idleTimer = null;
    _statsTimer = null;
    _reconnectTimer = null;
  }

  Future<void> _disposeMedia() async {
    final List<StreamSubscription<Object?>> subs =
        List<StreamSubscription<Object?>>.from(_mediaSubs);
    _mediaSubs.clear();
    for (final StreamSubscription<Object?> sub in subs) {
      await sub.cancel();
    }
    final RemoteMediaEngine? media = _media;
    _media = null;
    _token = '';
    try {
      await media?.dispose();
    } on Object {
      // 释放失败不影响状态收尾。
    }
  }

  void _clearFileState() {
    for (final _IncomingFile file in _incomingFiles.values) {
      file.builder.clear();
    }
    _incomingFiles.clear();
    for (final _PendingFile pending in _pendingFiles.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(false);
      }
    }
    _pendingFiles.clear();
  }

  Future<void> _resetFileProgressLater() async {
    final String? sid = _current?.sid;
    await Future<void>.delayed(const Duration(seconds: 3));
    final RemoteInfo? info = _current;
    if (info == null || info.sid != sid || info.isTerminal) {
      return;
    }
    _emit(info.copyWith(fileProgress: 0, fileTotal: 0, fileName: ''));
  }

  void _resetIdle() {
    _idleTimer?.cancel();
    if (!(_current?.isHost ?? false)) {
      return;
    }
    _idleTimer = Timer(idleTimeout, () {
      unawaited(end(reason: '长时间无操作，已自动断开'));
    });
  }

  void _resetSessionState() {
    _cancelTimers();
    unawaited(_disposeMedia());
    _clearFileState();
    _pendingCandidates.clear();
    _remoteDescriptionSet = false;
    _token = '';
    _reconnectAttempts = 0;
    _lastGoodQualityAt = null;
    _current = null;
    _incomingFiles.clear();
    _pendingFiles.clear();
  }

  /// 关闭终态快照，允许发起下一轮会话。
  void dismiss() {
    if (_current?.isTerminal ?? false) {
      _current = null;
    }
  }

  Future<void> dispose() async {
    _cancelTimers();
    await _disposeMedia();
    await _geometry.dispose();
    await injector.dispose();
    await _changes.close();
  }

  void _emit(RemoteInfo info) {
    _current = info;
    if (!_changes.isClosed) {
      _changes.add(info);
    }
  }

  Future<List<RemoteDisplay>> _pairDisplays(
    List<RemoteCaptureSource> sources,
  ) async {
    final List<RemoteDisplay> geometry = await _geometry.list();
    final List<RemoteDisplay> result = <RemoteDisplay>[];
    for (int i = 0; i < sources.length; i++) {
      final RemoteCaptureSource source = sources[i];
      RemoteDisplay? match;
      for (final RemoteDisplay g in geometry) {
        if (g.id == source.id) {
          match = g;
          break;
        }
      }
      match ??= i < geometry.length ? geometry[i] : null;
      result.add(RemoteDisplay(
        id: source.id,
        name: source.name.isEmpty ? match?.name ?? '屏幕 ${i + 1}' : source.name,
        index: i,
        x: match?.x ?? 0,
        y: match?.y ?? 0,
        width: match?.width ?? 1920,
        height: match?.height ?? 1080,
        pixelWidth: match?.pixelWidth ?? 1920,
        pixelHeight: match?.pixelHeight ?? 1080,
        scale: match?.scale ?? 1,
        primary: match?.primary ?? i == 0,
      ));
    }
    return result;
  }

  Future<void> _send(
    RemoteSignal signal, {
    bool critical = true,
  }) async {
    final String peer = _current?.peer ?? '';
    if (peer.isEmpty) {
      return;
    }
    try {
      await _sendRaw(peer, signal);
    } on NexmemException catch (error) {
      if (critical) {
        _fail(error.code == 'NOT_ONLINE'
            ? '对方不在线，无法建立远程控制'
            : '发送信令失败：${error.message}');
      }
    } on Object catch (error) {
      if (critical) {
        _fail('发送信令失败：$error');
      }
    }
  }

  Future<void> _sendRaw(String peer, RemoteSignal signal) async {
    final String payload = signal.toPayloadB64();
    debugPrint('[rc] -> ${signal.type.wireValue} ${payload.length}B sid=${signal.sid}');
    await transport.call('rtc.sendSignal', params: <String, dynamic>{
      'peer': peer,
      'payload_b64': payload,
    });
  }

  static String _randomToken(int bytes) {
    final Random random = Random.secure();
    final List<int> data =
        List<int>.generate(bytes, (_) => random.nextInt(256));
    return base64Url.encode(data).replaceAll('=', '');
  }

  static String _shortId(String id) =>
      id.length <= 8 ? id : '${id.substring(0, 8)}…';
}
