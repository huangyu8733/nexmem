// P6-28：RTC 媒体引擎抽象（工程方案 §3.6）。
//
// Go 内核只透传 SDP/ICE 信令，采集/编码/渲染完全由客户端媒体层负责。
// 这里把媒体层抽象成接口，使通话状态机可在无平台插件的单元测试里运行，
// 真实实现 [FlutterRtcMediaEngine] 基于 flutter_webrtc，工厂注入到 CallService。
//
// 一个引擎实例持有一个 PeerConnection；多人通话由 CallService 为每个成员
// 创建一个独立实例，避免单 _pc 覆盖导致第二路会话挤掉第一路。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 一条本地生成的 ICE 候选，待发往对端。
class RtcLocalCandidate {
  const RtcLocalCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  final String candidate;
  final String? sdpMid;
  final int sdpMLineIndex;
}

/// 媒体引擎：管理一个 PeerConnection 的 SDP 协商与音视频轨道。
///
/// [onLocalCandidate] 在收到本地 ICE 候选时触发，由上层编码成 candidate 信令发出；
/// [onConnectionState] 在连接状态变化时触发（connected / disconnected / failed 等）。
abstract class RtcMediaEngine {
  Stream<RtcLocalCandidate> get onLocalCandidate;
  Stream<String> get onConnectionState;

  /// 初始化 PeerConnection 并采集本地媒体（视频通话时含摄像头）。
  Future<void> start({required bool video});

  /// 创建 SDP offer 并设为本地描述，返回 SDP 文本。
  Future<String> createOffer();

  /// 创建 SDP answer 并设为本地描述，返回 SDP 文本。
  Future<String> createAnswer();

  /// 应用对端 SDP（offer 或 answer）。
  Future<void> setRemoteDescription(String sdp, String type);

  /// 应用对端一条 ICE 候选。
  Future<void> addCandidate(RtcLocalCandidate candidate);

  /// 静音/取消静音本地麦克风。
  Future<void> setMuted(bool muted);

  /// 开关本地摄像头（仅视频通话有效）。
  Future<void> setVideoEnabled(bool enabled);

  /// 切换前后摄像头（仅移动端有效）。
  Future<void> switchCamera();

  /// 是否采集了视频轨道。
  bool get hasVideo;

  /// 远端视频渲染对象（flutter_webrtc 的 RTCVideoRenderer），语音通话为 null。
  /// 用 Object 表态，让状态机与单测无需依赖平台插件类型。
  Object? get remoteVideoRenderer;

  /// 本地视频渲染对象，语音通话为 null。
  Object? get localVideoRenderer;

  /// 释放 PeerConnection、渲染器与本地媒体轨道。
  Future<void> dispose();
}

/// 基于 flutter_webrtc 的媒体引擎实现。
class FlutterRtcMediaEngine implements RtcMediaEngine {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  bool _muted = false;
  bool _video = false;
  bool _videoEnabled = true;

  /// 远端 SDP 是否已应用。候选常先于 answer 到达，未应用前必须排队，
  /// 否则 addCandidate 会抛错并拆掉整通会话。
  bool _remoteDescriptionSet = false;

  /// 等待远端描述就绪的 ICE 候选。
  final List<RtcLocalCandidate> _pendingCandidates = <RtcLocalCandidate>[];

  final StreamController<RtcLocalCandidate> _candidates =
      StreamController<RtcLocalCandidate>.broadcast();
  final StreamController<String> _states =
      StreamController<String>.broadcast();

  @override
  Stream<RtcLocalCandidate> get onLocalCandidate => _candidates.stream;

  @override
  Stream<String> get onConnectionState => _states.stream;

  @override
  bool get hasVideo => _video;

  @override
  Object? get remoteVideoRenderer => _remoteRenderer;

  @override
  Object? get localVideoRenderer => _localRenderer;

  /// STUN 服务器；TURN 可选（自建 coturn），默认不配置（工程方案 §3.6）。
  static const Map<String, dynamic> _configuration = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.l.google.com:19302'],
      },
    ],
  };

  @override
  Future<void> start({required bool video}) async {
    _video = video;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _pc = await createPeerConnection(_configuration);
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      // 释放会话后 PeerConnection 仍可能回调，控制器已关闭时直接丢弃。
      if (_candidates.isClosed) {
        return;
      }
      _candidates.add(RtcLocalCandidate(
        candidate: c.candidate ?? '',
        sdpMid: c.sdpMid,
        sdpMLineIndex: c.sdpMLineIndex ?? 0,
      ));
    };
    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      if (_states.isClosed) {
        return;
      }
      _states.add(state.toString().split('.').last);
    };
    // 远端轨道到达时绑定渲染器。onTrack 比 getRemoteStreams 更早拿到流，
    // 是视频小窗能正常出画面最关键的一步。
    _pc!.onTrack = (RTCTrackEvent event) {
      if (!video || _remoteRenderer == null) {
        return;
      }
      final bool isVideo = event.track.kind == 'video';
      if (!isVideo || event.streams.isEmpty) {
        return;
      }
      try {
        _remoteRenderer!.srcObject = event.streams.first;
      } on Object {
        // 渲染器未初始化或已释放时忽略，等待下一次轨道事件兜底。
      }
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': true,
        'video': video
            ? <String, dynamic>{'facingMode': 'user'}
            : false,
      });
    } on Object catch (error) {
      throw StateError('getUserMedia 失败（麦克风/摄像头权限或设备不可用）: $error');
    }
    for (final MediaStreamTrack track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    if (video) {
      _localRenderer = RTCVideoRenderer();
      _remoteRenderer = RTCVideoRenderer();
      await _localRenderer!.initialize();
      await _remoteRenderer!.initialize();
      _localRenderer!.srcObject = _localStream;
    }
  }

  @override
  Future<String> createOffer() async {
    final RTCSessionDescription desc = await _pc!.createOffer();
    await _pc!.setLocalDescription(desc);
    return desc.sdp ?? '';
  }

  @override
  Future<String> createAnswer() async {
    final RTCSessionDescription desc = await _pc!.createAnswer();
    await _pc!.setLocalDescription(desc);
    return desc.sdp ?? '';
  }

  @override
  Future<void> setRemoteDescription(String sdp, String type) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteDescriptionSet = true;
    // 先把排队候选全部应用，再绑定远端流；候选失败不应影响协商结果。
    final List<RtcLocalCandidate> queued =
        List<RtcLocalCandidate>.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final RtcLocalCandidate candidate in queued) {
      await _addCandidateNow(candidate);
    }
    _bindRemoteStreamIfNeeded();
  }

  @override
  Future<void> addCandidate(RtcLocalCandidate candidate) async {
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    await _addCandidateNow(candidate);
  }

  /// 仅做实际添加；候选是尽力而为，失败只记录，不能让会话失败。
  Future<void> _addCandidateNow(RtcLocalCandidate candidate) async {
    try {
      await _pc!.addCandidate(RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ));
      _bindRemoteStreamIfNeeded();
    } on Object catch (error) {
      debugPrint('Nexmem RTC 忽略无效候选: $error');
    }
  }

  /// onTrack 未带流时的兜底：直接从 PeerConnection 取远端流绑定。
  void _bindRemoteStreamIfNeeded() {
    final RTCVideoRenderer? renderer = _remoteRenderer;
    if (renderer == null || renderer.srcObject != null) {
      return;
    }
    final List<MediaStream?> streams =
        _pc?.getRemoteStreams() ?? <MediaStream?>[];
    final MediaStream? stream = streams.cast<MediaStream?>().firstWhere(
          (MediaStream? s) => s != null,
          orElse: () => null,
        );
    if (stream == null) {
      return;
    }
    try {
      renderer.srcObject = stream;
    } on Object {
      // 渲染器可能正在初始化，下一次事件会再试。
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    for (final MediaStreamTrack track in _localStream?.getAudioTracks() ??
        <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    _videoEnabled = enabled;
    for (final MediaStreamTrack track in _localStream?.getVideoTracks() ??
        <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> switchCamera() async {
    final List<MediaStreamTrack> tracks =
        _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isEmpty) {
      return;
    }
    try {
      await Helper.switchCamera(tracks.first);
    } on Object {
      // 桌面端无前后摄；保持当前画面即可。
    }
  }

  /// 本地摄像头是否处于开启状态。
  bool get videoEnabled => _videoEnabled;

  @override
  Future<void> dispose() async {
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    await _candidates.close();
    await _states.close();
    _localRenderer?.srcObject = null;
    _remoteRenderer?.srcObject = null;
    await _localRenderer?.dispose();
    await _remoteRenderer?.dispose();
    await _localStream?.dispose();
    await _pc?.close();
    _localRenderer = null;
    _remoteRenderer = null;
    _localStream = null;
    _pc = null;
    _muted = false;
    _video = false;
    _videoEnabled = true;
  }

  /// 本地媒体流，供通话页渲染小窗；未启动时为 null。
  MediaStream? get localStream => _localStream;

  /// 是否静音。
  bool get muted => _muted;
}
