// P6-28：通话状态机与信令编排。
//
// 负责把内核的 `rtc.sendSignal` / `rtc.signal` 与媒体引擎串起来：
//   - 主叫：createOffer → 发 offer；收到 answer → setRemoteDescription；
//   - 被叫：收到 offer → createAnswer → 发 answer；
//   - 双方：本地 ICE 候选与对端 candidate 信令互相转发；
//   - 挂断：释放媒体并清空会话。
//
// 通话不落盘、不录制（工程方案 §3.6），状态只在内存中。媒体引擎经接口注入，
// 便于用假实现做无插件的单元测试。

import 'dart:async';

import 'package:nexmem_app/transport/transport.dart';

import 'rtc_media.dart';
import 'rtc_signal.dart';

/// 通话状态。
enum CallState {
  idle('空闲'),
  outgoing('呼叫中'),
  incoming('来电'),
  connected('通话中'),
  ended('已结束');

  const CallState(this.label);
  final String label;
}

/// 当前通话快照，供 UI 渲染。
class CallInfo {
  const CallInfo({
    required this.state,
    required this.peer,
    required this.video,
    this.muted = false,
  });

  final CallState state;
  /// 对端账号公钥（base64url，与契约 `peer` 一致）。
  final String peer;
  final bool video;
  final bool muted;

  CallInfo copyWith({CallState? state, bool? muted}) => CallInfo(
        state: state ?? this.state,
        peer: peer,
        video: video,
        muted: muted ?? this.muted,
      );
}

/// 通话服务：一条信令通道 + 一个媒体引擎 + 一份状态。
class CallService {
  CallService({
    required this._transport,
    required this._mediaFactory,
  });

  final CoreTransport _transport;
  final RtcMediaEngine Function() _mediaFactory;

  final StreamController<CallInfo> _stateChanges =
      StreamController<CallInfo>.broadcast();

  StreamSubscription<RtcLocalCandidate>? _candidateSub;
  StreamSubscription<String>? _connectionSub;

  RtcMediaEngine? _media;
  CallInfo? _current;
  String? _peer;
  RtcSignal? _pendingOffer;

  /// 通话状态变化流；UI 据此刷新来电弹窗/通话页。
  Stream<CallInfo> get changes => _stateChanges.stream;

  /// 当前通话，空闲时为 null。
  CallInfo? get current => _current;

  /// 主叫：对 [peer]（base64url 账号）发起通话。
  Future<void> startOutgoing(String peer, {bool video = false}) async {
    await _reset();
    _peer = peer;
    _emit(CallState.outgoing, video: video);
    try {
      final RtcMediaEngine media = _mediaFactory();
      _media = media;
      _bindMedia(media);
      await media.start(video: video);
      final String sdp = await media.createOffer();
      await _send(RtcSignal(type: RtcSignalType.offer, sdp: sdp), peer);
    } catch (_) {
      await _fail();
    }
  }

  /// 接听当前来电（由 [handleSignal] 置起的 offer）。
  Future<void> answer() async {
    final RtcSignal? offer = _pendingOffer;
    final String? peer = _peer;
    if (offer == null || peer == null) {
      return;
    }
    final bool video = false; // 来电当前只支持语音；视频邀请预留。
    _pendingOffer = null;
    await _reset();
    _peer = peer;
    _emit(CallState.incoming, video: video);
    try {
      final RtcMediaEngine media = _mediaFactory();
      _media = media;
      _bindMedia(media);
      await media.start(video: video);
      await media.setRemoteDescription(offer.sdp, 'offer');
      final String sdp = await media.createAnswer();
      await _send(RtcSignal(type: RtcSignalType.answer, sdp: sdp), peer);
      _emit(CallState.connected, video: video);
    } catch (_) {
      await _fail();
    }
  }

  /// 拒绝来电：不建媒体，直接回到空闲。
  Future<void> reject() async {
    _pendingOffer = null;
    await endCall();
  }

  /// 处理来自内核 `rtc.signal` 事件的载荷（std base64）。
  Future<void> handleSignal(String peer, String payloadB64) async {
    final RtcSignal signal;
    try {
      signal = RtcSignal.fromPayloadB64(payloadB64);
    } on FormatException {
      return; // 忽略非法/不兼容载荷，避免被对端构造包击穿状态机。
    }

    if (signal.type == RtcSignalType.offer) {
      // 来电：先记录 offer，等待用户接听；不在这里直接建媒体。
      _peer = peer;
      _pendingOffer = signal;
      _emit(CallState.incoming, video: false);
      return;
    }

    if (_media == null || _peer != peer) {
      return; // 无会话或对端不匹配，忽略迟到的信令。
    }
    try {
      switch (signal.type) {
        case RtcSignalType.answer:
          await _media!.setRemoteDescription(signal.sdp, 'answer');
          _emit(CallState.connected, video: _current?.video ?? false);
        case RtcSignalType.candidate:
          await _media!.addCandidate(RtcLocalCandidate(
            candidate: signal.sdp,
            sdpMid: signal.mid,
            sdpMLineIndex: signal.index,
          ));
        case RtcSignalType.offer:
          break; // 已在前面处理。
      }
    } catch (_) {
      await _fail();
    }
  }

  /// 挂断：释放媒体并清空状态。
  Future<void> endCall() async {
    _pendingOffer = null;
    await _media?.dispose();
    _media = null;
    _peer = null;
    _emit(CallState.ended, video: false);
    _current = null;
  }

  /// 静音切换。
  Future<void> setMuted(bool muted) async {
    await _media?.setMuted(muted);
    if (_current != null) {
      _emit(_current!.state, video: _current!.video, muted: muted);
    }
  }

  /// 绑定媒体引擎的候选/连接状态流。
  void _bindMedia(RtcMediaEngine media) {
    _candidateSub?.cancel();
    _connectionSub?.cancel();
    _candidateSub = media.onLocalCandidate.listen(_onLocalCandidate);
    _connectionSub = media.onConnectionState.listen(_onConnectionState);
  }

  void _onLocalCandidate(RtcLocalCandidate candidate) {
    final String? peer = _peer;
    if (peer == null) {
      return;
    }
    unawaited(_send(
      RtcSignal(
        type: RtcSignalType.candidate,
        sdp: candidate.candidate,
        mid: candidate.sdpMid,
        index: candidate.sdpMLineIndex,
      ),
      peer,
    ));
  }

  void _onConnectionState(String state) {
    if (state == 'connected' && _current?.state != CallState.connected) {
      _emit(CallState.connected, video: _current?.video ?? false);
    } else if (state == 'failed' || state == 'disconnected') {
      unawaited(endCall());
    }
  }

  Future<void> _send(RtcSignal signal, String peer) async {
    await _transport.call(
      'rtc.sendSignal',
      params: <String, dynamic>{
        'peer': peer,
        'payload_b64': signal.toPayloadB64(),
      },
    );
  }

  void _emit(CallState state, {required bool video, bool muted = false}) {
    _current = CallInfo(
      state: state,
      peer: _peer ?? '',
      video: video,
      muted: muted,
    );
    if (!_stateChanges.isClosed) {
      _stateChanges.add(_current!);
    }
  }

  Future<void> _reset() async {
    _pendingOffer = null;
    await _media?.dispose();
    _media = null;
    await _candidateSub?.cancel();
    await _connectionSub?.cancel();
    _candidateSub = null;
    _connectionSub = null;
  }

  Future<void> _fail() async {
    await endCall();
  }

  Future<void> dispose() async {
    await _reset();
    await _stateChanges.close();
  }
}
