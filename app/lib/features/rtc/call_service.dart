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

import 'package:flutter/foundation.dart';
import 'package:nexmem_app/transport/transport.dart';

import 'rtc_media.dart';
import 'rtc_signal.dart';

/// 通话结束原因，供 UI 文案与通话记录使用。
enum CallEndReason {
  none(''),
  hangup('已挂断'),
  rejected('对方已拒绝'),
  canceled('已取消'),
  noAnswer('无人接听'),
  failed('呼叫失败');

  const CallEndReason(this.label);
  final String label;
}

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
    this.endReason = CallEndReason.none,
    this.startedAt,
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

  /// 结束原因；仅 [CallState.ended] 有意义。
  final CallEndReason endReason;

  /// 接通时刻；未接通为 null。
  final DateTime? startedAt;

  /// 已通话时长；未接通为 [Duration.zero]。
  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  CallInfo copyWith({
    CallState? state,
    bool? muted,
    bool? video,
    List<CallParticipant>? participants,
    CallEndReason? endReason,
    DateTime? startedAt,
  }) =>
      CallInfo(
        state: state ?? this.state,
        peer: peer,
        video: video ?? this.video,
        muted: muted ?? this.muted,
        callId: callId,
        isGroup: isGroup,
        participants: participants ?? this.participants,
        endReason: endReason ?? this.endReason,
        startedAt: startedAt ?? this.startedAt,
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

  /// 来电振铃期间先到的对端 ICE 候选；接听后补加到新会话，避免丢候选。
  final Map<String, List<RtcSignal>> _earlyCandidates =
      <String, List<RtcSignal>>{};

  CallInfo? _current;
  String? _activeCallId;
  bool _isGroup = false;
  bool _muted = false;

  /// 主叫振铃超时（45s 无人接听自动结束）。
  Timer? _ringTimer;

  /// 接通时刻，用于通话计时。
  DateTime? _connectedAt;

  /// 振铃超时时长。
  static const Duration ringTimeout = Duration(seconds: 45);

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
    final bool started = await _startSession(
      callId: callId,
      peer: peer,
      video: video,
      members: <String>[],
      offer: true,
    );
    if (!started) {
      // 采集或信令失败时不再停留在「正在呼叫…」，直接收尾并告知 UI。
      await endCall(reason: CallEndReason.failed);
      return;
    }
    _emit(CallState.outgoing, callId: callId, video: video);
    _startRingTimer();
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
    int started = 0;
    for (final String peer in members) {
      if (await _startSession(
        callId: callId,
        peer: peer,
        video: video,
        members: members,
        offer: true,
      )) {
        started++;
      }
    }
    if (started == 0) {
      await endCall(reason: CallEndReason.failed);
      return;
    }
    _emit(
      CallState.outgoing,
      callId: callId,
      video: video,
      participants: members
          .map((String p) => CallParticipant(peer: p, video: video))
          .toList(growable: false),
    );
    _startRingTimer();
  }

  /// 接听来电。[callId] 为空时接听全部待处理来电。
  Future<void> answer({String? callId}) async {
    final List<String> ids = callId != null
        ? <String>[callId]
        : _pending.keys.toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    String? acceptedCallId;
    for (final String id in ids) {
      final _PendingOffer? pending = _pending.remove(id);
      if (pending == null) {
        continue;
      }
      _activeCallId = id;
      _isGroup = id.startsWith('g-') || pending.signal.members.isNotEmpty;
      final bool accepted = await _acceptOffer(id, pending.peer, pending.signal);
      if (!accepted) {
        // 采集或应答失败：不能对外声称已接通。
        if (_activeCallId == id) {
          _activeCallId = null;
        }
        continue;
      }
      acceptedCallId = id;

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
    if (acceptedCallId == null) {
      await endCall(reason: CallEndReason.failed);
      return;
    }
    _ringTimer?.cancel();
    _ringTimer = null;
    _emit(CallState.connected, callId: acceptedCallId);
  }

  /// 拒绝来电；通知主叫并回到空闲。
  Future<void> reject({String? callId}) async {
    await endCall(reason: CallEndReason.rejected);
  }

  /// 处理来自内核 `rtc.signal` 事件的载荷（std base64）。
  Future<void> handleSignal(String peer, String payloadB64) async {
    final RtcSignal signal;
    try {
      signal = RtcSignal.fromPayloadB64(payloadB64);
    } on FormatException catch (error) {
      debugPrint('Nexmem rtc.signal parse failed: $error');
      return; // 忽略非法/不兼容载荷，避免被对端构造包击穿状态机。
    }

    final String callId = signal.callId.isNotEmpty
        ? signal.callId
        : 'legacy|$peer';
    debugPrint(
      'Nexmem rtc.signal recv type=${signal.type.wireValue} '
      'peer=$peer call=$callId',
    );
    if (signal.type == RtcSignalType.end) {
      // 对端结束/拒绝/取消：立刻收尾，避免主叫干等到超时。
      _pending.remove(callId);
      await endCall(
        reason: _reasonFromWire(signal.reason),
        notifyPeer: false,
      );
      return;
    }
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
      // 振铃阶段对端候选先到：先缓存，接听后统一补加，否则 ICE 少一半候选。
      if (signal.type == RtcSignalType.candidate &&
          _pending.containsKey(callId)) {
        final List<RtcSignal> buffered = _earlyCandidates.putIfAbsent(
          _key(callId, peer),
          () => <RtcSignal>[],
        );
        if (buffered.length < 64) {
          buffered.add(signal);
        }
      }
      return; // 无会话或成员不匹配，忽略迟到的信令。
    }
    try {
      switch (signal.type) {
        case RtcSignalType.answer:
          await session.media.setRemoteDescription(signal.sdp, 'answer');
          session.connected = true;
          _ringTimer?.cancel();
          _ringTimer = null;
          _emit(CallState.connected, callId: callId, video: session.video);
        case RtcSignalType.candidate:
          // 候选是尽力而为：失败只记录，不能拆掉已建立的会话。
          try {
            await session.media.addCandidate(RtcLocalCandidate(
              candidate: signal.sdp,
              sdpMid: signal.mid,
              sdpMLineIndex: signal.index,
            ));
          } on Object catch (error) {
            debugPrint('Nexmem rtc candidate ignored: $error');
          }
        case RtcSignalType.offer:
        case RtcSignalType.end:
          break; // 已在前面处理。
      }
    } catch (_) {
      await _failSession(session);
    }
  }

  /// 挂断：释放全部会话并把结束原因告知 UI。
  ///
  /// [notifyPeer] 为 true 时先给对端发送一条 end 信令（QQ 式双向收尾），
  /// 避免对方干等到振铃超时。收到对端 end 信令时传 false 防止乒乓。
  Future<void> endCall({
    CallEndReason reason = CallEndReason.hangup,
    bool notifyPeer = true,
  }) async {
    final CallEndReason effective = reason == CallEndReason.hangup &&
            _current?.state == CallState.outgoing
        ? CallEndReason.canceled
        : reason;
    final String callId = _activeCallId ?? '';
    final List<String> peers = <String>{
      ..._sessions.values.map((_CallSession session) => session.peer),
      ..._pending.values.map((_PendingOffer pending) => pending.peer),
    }.toList(growable: false);
    if (notifyPeer && callId.isNotEmpty && peers.isNotEmpty) {
      await _broadcastEnd(callId, peers, effective);
    }
    _ringTimer?.cancel();
    _ringTimer = null;
    _pending.clear();
    final List<_CallSession> sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    for (final _CallSession session in sessions) {
      await session.candidateSub?.cancel();
      await session.connectionSub?.cancel();
      await session.media.dispose();
    }
    _emit(CallState.ended, callId: callId, endReason: effective);
    // 结束快照已推给 UI（含结束原因与计时），当前会话回到空闲。
    _current = null;
    _connectedAt = null;
    _activeCallId = null;
    _isGroup = false;
    _muted = false;
  }

  void _startRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, () {
      if (_current?.state == CallState.outgoing) {
        unawaited(endCall(reason: CallEndReason.noAnswer));
      }
    });
  }

  /// 通知所有对端本通已结束；失败只记录，不影响本地收尾。
  Future<void> _broadcastEnd(
    String callId,
    List<String> peers,
    CallEndReason reason,
  ) async {
    for (final String peer in peers) {
      try {
        await _send(
          RtcSignal(
            type: RtcSignalType.end,
            sdp: reason.name,
            callId: callId,
            to: peer,
            reason: reason.name,
          ),
          peer,
        );
      } on Object catch (error) {
        debugPrint('Nexmem rtc end signal failed peer=$peer: $error');
      }
    }
  }

  static CallEndReason _reasonFromWire(String value) {
    for (final CallEndReason reason in CallEndReason.values) {
      if (reason != CallEndReason.none && reason.name == value) {
        return reason;
      }
    }
    return CallEndReason.hangup;
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
  Future<bool> _startSession({
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
      return true;
    } on Object catch (error) {
      debugPrint('Nexmem media start failed peer=$peer: $error');
      await _releaseSession(session);
      return false;
    }
  }

  /// 释放一路会话资源，不改动通话全局状态（是否结束由调用方决定）。
  Future<void> _releaseSession(_CallSession session) async {
    _sessions.remove(_key(session.callId, session.peer));
    await session.candidateSub?.cancel();
    await session.connectionSub?.cancel();
    try {
      await session.media.dispose();
    } on Object catch (error) {
      // 媒体释放失败不能阻断通话状态收尾（例如页面已关闭却仍停留在呼叫中）。
      debugPrint('Nexmem media dispose failed: $error');
    }
  }

  /// 接听某一路 offer：建媒体、应用远端 SDP、回 answer。
  Future<bool> _acceptOffer(
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
      await _flushEarlyCandidates(callId, peer, media);
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
      return true;
    } on Object catch (error) {
      debugPrint('Nexmem accept offer failed peer=$peer: $error');
      await _releaseSession(session);
      return false;
    }
  }

  /// 接听成功后补加振铃期间缓存的对端候选；单条失败不影响通话。
  Future<void> _flushEarlyCandidates(
    String callId,
    String peer,
    RtcMediaEngine media,
  ) async {
    final List<RtcSignal> early =
        _earlyCandidates.remove(_key(callId, peer)) ?? const <RtcSignal>[];
    for (final RtcSignal candidate in early) {
      try {
        await media.addCandidate(RtcLocalCandidate(
          candidate: candidate.sdp,
          sdpMid: candidate.mid,
          sdpMLineIndex: candidate.index,
        ));
      } on Object catch (error) {
        debugPrint('Nexmem early candidate ignored: $error');
      }
    }
  }

  void _bindMedia(_CallSession session) {    session.candidateSub =
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
      debugPrint(
        'Nexmem ice state=$state peer=${session.peer} call=${session.callId}',
      );
      if (state == 'connected') {
        session.connected = true;
        _ringTimer?.cancel();
        _ringTimer = null;
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
      await endCall(reason: CallEndReason.failed);
    } else {
      _emit(_current?.state ?? CallState.connected, callId: session.callId);
    }
  }

  Future<void> _failSession(_CallSession session) async {
    await _dropSession(session);
  }

  Future<void> _send(RtcSignal signal, String peer) async {
    try {
      await _transport.call(
        'rtc.sendSignal',
        params: <String, dynamic>{
          'peer': peer,
          'payload_b64': signal.toPayloadB64(),
        },
      );
    } on Object catch (error) {
      debugPrint(
        'Nexmem rtc signal send failed type=${signal.type.wireValue} '
        'peer=$peer: $error',
      );
      rethrow;
    }
  }

  void _emit(
    CallState state, {
    String callId = '',
    bool? video,
    bool? muted,
    List<CallParticipant>? participants,
    CallEndReason endReason = CallEndReason.none,
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
    // 结束时会话已释放，保留上一帧成员，便于结束页继续显示对方信息。
    if (rendered.isEmpty && state == CallState.ended) {
      rendered.addAll(_current?.participants ?? const <CallParticipant>[]);
    }
    if (state == CallState.connected && _connectedAt == null) {
      _connectedAt = DateTime.now();
    }
    final String peer = sessions.isNotEmpty
        ? sessions.first.peer
        : _pending.values.isNotEmpty
            ? _pending.values.first.peer
            : (_current?.peer ?? '');
    final bool resolvedVideo = video ??
        (sessions.isNotEmpty
            ? sessions.first.video
            : _pending.values.isNotEmpty
                ? _pending.values.first.signal.video
                : (_current?.video ?? false));
    _current = CallInfo(
      state: state,
      peer: peer,
      video: resolvedVideo,
      muted: muted ?? _muted,
      callId: callId.isNotEmpty ? callId : (_activeCallId ?? ''),
      isGroup: _isGroup,
      participants: rendered,
      endReason: endReason,
      startedAt: _connectedAt,
    );
    if (!_stateChanges.isClosed) {
      _stateChanges.add(_current!);
    }
  }

  Future<void> _reset() async {
    _ringTimer?.cancel();
    _ringTimer = null;
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
    _connectedAt = null;
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
