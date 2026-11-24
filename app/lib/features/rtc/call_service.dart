// P6-28：通话状态机与信令编排。
//
// 负责把内核的 `rtc.sendSignal` / `rtc.signal` 与媒体引擎串起来：
//   - 主叫：createOffer → 发 offer；收到 answer → setRemoteDescription；
//   - 被叫：收到 offer → createAnswer → 发 answer；
//   - 双方：本地 ICE 候选与对端 candidate 信令互相转发；
//   - 多人：每个成员一条独立 PeerConnection（Mesh），由 callId + peer 双键定位；
//   - 挂断：释放全部媒体并清空会话。
//
// 通话不落盘、不录制（工程方案 §3.6），状态只在内存中。媒体引擎经接口注入，
// 便于用假实现做无插件的单元测试。

import 'dart:async';
import 'dart:math';

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

/// 通话中的一位成员。
class CallParticipant {
  const CallParticipant({
    required this.peer,
    required this.video,
    this.muted = false,
    this.connected = false,
  });

  /// 成员账号公钥（base64url）。
  final String peer;
  final bool video;
  final bool muted;
  final bool connected;
}

/// 当前通话快照，供 UI 渲染。
class CallInfo {
  const CallInfo({
    required this.state,
    required this.peer,
    required this.video,
    this.muted = false,
    this.callId = '',
    this.isGroup = false,
    this.participants = const <CallParticipant>[],
  });

  final CallState state;

  /// 主对端账号公钥（base64url，与契约 `peer` 一致）；群聊时为首个成员。
  final String peer;
  final bool video;
  final bool muted;

  /// 会话标识；群聊中所有成员共享同一个 callId。
  final String callId;

  /// 是否为群聊通话。
  final bool isGroup;

  /// 全部成员（含已接听与呼叫中的），供多人网格渲染。
  final List<CallParticipant> participants;

  CallInfo copyWith({
    CallState? state,
    bool? muted,
    bool? video,
    List<CallParticipant>? participants,
  }) =>
      CallInfo(
        state: state ?? this.state,
        peer: peer,
        video: video ?? this.video,
        muted: muted ?? this.muted,
        callId: callId,
        isGroup: isGroup,
        participants: participants ?? this.participants,
      );
}

class _CallSession {
  _CallSession({
    required this.callId,
    required this.peer,
    required this.media,
    required this.video,
    this.members = const <String>[],
  });

  final String callId;
  final String peer;
  final RtcMediaEngine media;
  final bool video;
  final List<String> members;
  bool connected = false;
  bool muted = false;
  StreamSubscription<RtcLocalCandidate>? candidateSub;
  StreamSubscription<String>? connectionSub;
}

class _PendingOffer {
  const _PendingOffer({required this.peer, required this.signal});

  final String peer;
  final RtcSignal signal;
}

/// 通话服务：一条信令通道 + 每个成员一个媒体引擎 + 多会话状态。
class CallService {
  CallService({
    required this._transport,
    required this._mediaFactory,
    this.selfAccount = '',
  });

  final CoreTransport _transport;
  final RtcMediaEngine Function() _mediaFactory;

  /// 本机账号（base64url），群聊 Mesh 中用来排除自己。
  final String selfAccount;

  final StreamController<CallInfo> _stateChanges =
      StreamController<CallInfo>.broadcast();

  /// callId|peer → 会话。一条会话对应一个 PeerConnection。
  final Map<String, _CallSession> _sessions = <String, _CallSession>{};

  /// callId → 尚未接听的来电（群聊可能同时有多个）。
  final Map<String, _PendingOffer> _pending = <String, _PendingOffer>{};

  CallInfo? _current;
  String? _activeCallId;
  bool _isGroup = false;
  bool _muted = false;

  /// 通话状态变化流；UI 据此刷新来电弹窗/通话页。
  Stream<CallInfo> get changes => _stateChanges.stream;

  /// 当前通话，空闲时为 null。
  CallInfo? get current => _current;

  /// 发起 1v1 通话（保持原 API 兼容）。
  Future<void> startOutgoing(String peer, {bool video = false}) async {
    await _reset();
    if (peer.isEmpty) {
      return;
    }
    final String callId = 'd-${_newId()}';
    _activeCallId = callId;
    _isGroup = false;
    await _startSession(
      callId: callId,
      peer: peer,
      video: video,
      members: <String>[],
      offer: true,
    );
    _emit(CallState.outgoing, callId: callId, video: video);
  }

  /// 发起群聊通话：与 [peers] 中每个成员各建一条 PeerConnection（Mesh）。
  ///
  /// 建议不超过 4 人；每条会话都会独立采集一次本地音视频。
  Future<void> startGroupOutgoing(
    List<String> peers, {
    bool video = false,
  }) async {
    await _reset();
    final List<String> members = peers
        .where((String peer) => peer.isNotEmpty && peer != selfAccount)
        .toList();
    if (members.isEmpty) {
      return;
    }
    final String callId = 'g-${_newId()}';
    _activeCallId = callId;
    _isGroup = true;
    _emit(
      CallState.outgoing,
      callId: callId,
      video: video,
      participants: members
          .map((String p) => CallParticipant(peer: p, video: video))
          .toList(growable: false),
    );
    for (final String peer in members) {
      await _startSession(
        callId: callId,
        peer: peer,
        video: video,
        members: members,
        offer: true,
      );
    }
    _emit(CallState.outgoing, callId: callId, video: video);
  }

  /// 接听来电。[callId] 为空时接听全部待处理来电。
  Future<void> answer({String? callId}) async {
    final List<String> ids = callId != null
        ? <String>[callId]
        : _pending.keys.toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    for (final String id in ids) {
      final _PendingOffer? pending = _pending.remove(id);
      if (pending == null) {
        continue;
      }
      _activeCallId = id;
      _isGroup = id.startsWith('g-') || pending.signal.members.isNotEmpty;
      await _acceptOffer(id, pending.peer, pending.signal);

      // Mesh：对其余成员也各发一路 offer，让所有人都两两直连。
      final List<String> others = pending.signal.members
          .where(
            (String peer) =>
                peer != selfAccount &&
                peer != pending.peer &&
                !_sessions.containsKey(_key(id, peer)),
          )
          .toList(growable: false);
      for (final String peer in others) {
        await _startSession(
          callId: id,
          peer: peer,
          video: pending.signal.video,
          members: pending.signal.members,
          offer: true,
        );
      }
    }
    _emit(CallState.connected, callId: _activeCallId ?? '');
  }

  /// 拒绝来电；不建媒体，直接回到空闲。
  Future<void> reject({String? callId}) async {
    if (callId != null) {
      _pending.remove(callId);
    } else {
      _pending.clear();
    }
    if (_pending.isEmpty && _sessions.isEmpty) {
      await endCall();
    }
  }

  /// 处理来自内核 `rtc.signal` 事件的载荷（std base64）。
  Future<void> handleSignal(String peer, String payloadB64) async {
    final RtcSignal signal;
    try {
      signal = RtcSignal.fromPayloadB64(payloadB64);
    } on FormatException {
      return; // 忽略非法/不兼容载荷，避免被对端构造包击穿状态机。
    }

    final String callId = signal.callId.isNotEmpty
        ? signal.callId
        : 'legacy|$peer';
    if (signal.type == RtcSignalType.offer) {
      // 已与该成员建立本路会话：重复 offer 直接忽略，避免重建 PC。
      if (_sessions.containsKey(_key(callId, peer))) {
        return;
      }
      if (_sessions.isEmpty) {
        if (_pending.containsKey(callId)) {
          return; // 同一通未接来电的重复投递。
        }
        _pending[callId] = _PendingOffer(peer: peer, signal: signal);
        _activeCallId = callId;
        _isGroup = callId.startsWith('g-') || signal.members.isNotEmpty;
        _emit(CallState.incoming, callId: callId, video: signal.video);
      } else {
        // 通话已建立期间新成员加入：自动建会话并回 answer，不再弹来电页。
        await _acceptOffer(callId, peer, signal);
        _emit(CallState.connected, callId: callId);
      }
      return;
    }

    final _CallSession? session = _findSession(callId, peer);
    if (session == null) {
      return; // 无会话或成员不匹配，忽略迟到的信令。
    }
    try {
      switch (signal.type) {
        case RtcSignalType.answer:
          await session.media.setRemoteDescription(signal.sdp, 'answer');
          session.connected = true;
          _emit(CallState.connected, callId: callId, video: session.video);
        case RtcSignalType.candidate:
          await session.media.addCandidate(RtcLocalCandidate(
            candidate: signal.sdp,
            sdpMid: signal.mid,
            sdpMLineIndex: signal.index,
          ));
        case RtcSignalType.offer:
          break; // 已在前面处理。
      }
    } catch (_) {
      await _failSession(session);
    }
  }

  /// 挂断：释放全部会话并清空状态。
  Future<void> endCall() async {
    _pending.clear();
    final List<_CallSession> sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final _CallSession session in sessions) {
      await session.candidateSub?.cancel();
      await session.connectionSub?.cancel();
      await session.media.dispose();
    }
    _emit(CallState.ended, callId: _activeCallId ?? '', video: false);
    _current = null;
    _activeCallId = null;
    _isGroup = false;
  }

  /// 全局静音切换（作用于所有会话）。
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    for (final _CallSession session in _sessions.values) {
      await session.media.setMuted(muted);
      session.muted = muted;
    }
    _emit(_current?.state ?? CallState.connected, muted: muted);
  }

  /// 全局摄像头开关。
  Future<void> setVideoEnabled(bool enabled) async {
    for (final _CallSession session in _sessions.values) {
      await session.media.setVideoEnabled(enabled);
    }
  }

  /// 切换前后摄像头（对第一路视频会话生效）。
  Future<void> switchCamera() async {
    for (final _CallSession session in _sessions.values) {
      if (session.video) {
        await session.media.switchCamera();
        return;
      }
    }
  }

  /// 指定成员的远端视频渲染对象，供通话页构造视图。
  Object? remoteRendererFor(String peer) {
    for (final _CallSession session in _sessions.values) {
      if (session.peer == peer) {
        return session.media.remoteVideoRenderer;
      }
    }
    return null;
  }

  /// 指定成员的本地视频渲染对象（多人时每路会话各有一份）。
  Object? localRendererFor(String peer) {
    for (final _CallSession session in _sessions.values) {
      if (session.peer == peer) {
        return session.media.localVideoRenderer;
      }
    }
    return null;
  }

  /// 建立一路发往 [peer] 的会话并发送 offer。
  Future<void> _startSession({
    required String callId,
    required String peer,
    required bool video,
    required List<String> members,
    required bool offer,
  }) async {
    final RtcMediaEngine media = _mediaFactory();
    final _CallSession session = _CallSession(
      callId: callId,
      peer: peer,
      media: media,
      video: video,
      members: members,
    );
    _sessions[_key(callId, peer)] = session;
    _bindMedia(session);
    try {
      await media.start(video: video);
      if (offer) {
        final String sdp = await media.createOffer();
        await _send(
          RtcSignal(
            type: RtcSignalType.offer,
            sdp: sdp,
            callId: callId,
            to: peer,
            video: video,
            members: members,
          ),
          peer,
        );
      }
    } catch (_) {
      await _failSession(session);
    }
  }

  /// 接听某一路 offer：建媒体、应用远端 SDP、回 answer。
  Future<void> _acceptOffer(
    String callId,
    String peer,
    RtcSignal offer,
  ) async {
    final RtcMediaEngine media = _mediaFactory();
    final _CallSession session = _CallSession(
      callId: callId,
      peer: peer,
      media: media,
      video: offer.video,
      members: offer.members,
    );
    _sessions[_key(callId, peer)] = session;
    _bindMedia(session);
    try {
      await media.start(video: offer.video);
      await media.setRemoteDescription(offer.sdp, 'offer');
      final String sdp = await media.createAnswer();
      await _send(
        RtcSignal(
          type: RtcSignalType.answer,
          sdp: sdp,
          callId: callId,
          to: peer,
          video: offer.video,
          members: offer.members,
        ),
        peer,
      );
      session.connected = true;
    } catch (_) {
      await _failSession(session);
    }
  }

  void _bindMedia(_CallSession session) {
    session.candidateSub =
        session.media.onLocalCandidate.listen((RtcLocalCandidate c) {
      unawaited(_send(
        RtcSignal(
          type: RtcSignalType.candidate,
          sdp: c.candidate,
          mid: c.sdpMid,
          index: c.sdpMLineIndex,
          callId: session.callId,
          to: session.peer,
          video: session.video,
          members: session.members,
        ),
        session.peer,
      ));
    });
    session.connectionSub =
        session.media.onConnectionState.listen((String state) {
      if (state == 'connected') {
        session.connected = true;
        _emit(CallState.connected, callId: session.callId, video: session.video);
      } else if (state == 'failed' || state == 'disconnected') {
        unawaited(_dropSession(session));
      }
    });
  }

  Future<void> _dropSession(_CallSession session) async {
    if (_sessions.remove(_key(session.callId, session.peer)) == null) {
      return;
    }
    await session.candidateSub?.cancel();
    await session.connectionSub?.cancel();
    await session.media.dispose();
    if (_sessions.isEmpty) {
      await endCall();
    } else {
      _emit(_current?.state ?? CallState.connected, callId: session.callId);
    }
  }

  Future<void> _failSession(_CallSession session) async {
    await _dropSession(session);
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

  void _emit(
    CallState state, {
    String callId = '',
    bool? video,
    bool? muted,
    List<CallParticipant>? participants,
  }) {
    final List<_CallSession> sessions = _sessions.values.toList(growable: false);
    final List<CallParticipant> rendered = (participants ??
            sessions
                .map(
                  (_CallSession s) => CallParticipant(
                    peer: s.peer,
                    video: s.video,
                    muted: s.muted,
                    connected: s.connected,
                  ),
                )
                .toList(growable: false))
        .toList(growable: true);
    if (rendered.isEmpty && state == CallState.incoming) {
      for (final _PendingOffer pending in _pending.values) {
        rendered.add(CallParticipant(
          peer: pending.peer,
          video: pending.signal.video,
        ));
      }
    }
    final String peer = sessions.isNotEmpty
        ? sessions.first.peer
        : (_pending.values.isEmpty ? '' : _pending.values.first.peer);
    final bool resolvedVideo = video ??
        (sessions.isNotEmpty
            ? sessions.first.video
            : (_pending.values.isEmpty
                ? false
                : _pending.values.first.signal.video));
    _current = CallInfo(
      state: state,
      peer: peer,
      video: resolvedVideo,
      muted: muted ?? _muted,
      callId: callId.isNotEmpty ? callId : (_activeCallId ?? ''),
      isGroup: _isGroup,
      participants: rendered,
    );
    if (!_stateChanges.isClosed) {
      _stateChanges.add(_current!);
    }
  }

  Future<void> _reset() async {
    _pending.clear();
    final List<_CallSession> sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final _CallSession session in sessions) {
      await session.candidateSub?.cancel();
      await session.connectionSub?.cancel();
      await session.media.dispose();
    }
    _activeCallId = null;
    _isGroup = false;
    _muted = false;
  }

  /// 优先按 callId+peer 精确定位；旧端 v1 信令没有 callId，按 peer 回退查找。
  _CallSession? _findSession(String callId, String peer) {
    final _CallSession? exact = _sessions[_key(callId, peer)];
    if (exact != null) {
      return exact;
    }
    for (final _CallSession session in _sessions.values) {
      if (session.peer == peer) {
        return session;
      }
    }
    return null;
  }

  String _key(String callId, String peer) => '$callId|$peer';

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

  Future<void> dispose() async {
    await _reset();
    await _stateChanges.close();
  }
}
