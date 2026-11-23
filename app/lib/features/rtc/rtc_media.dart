// P6-28：RTC 媒体引擎抽象（工程方案 §3.6）。
//
// Go 内核只透传 SDP/ICE 信令，采集/编码/渲染完全由客户端媒体层负责。
// 这里把媒体层抽象成接口，使通话状态机可在无平台插件的单元测试里运行，
// 真实实现 [FlutterRtcMediaEngine] 基于 flutter_webrtc，工厂注入到 CallService。

import 'dart:async';

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

  /// 释放 PeerConnection 与本地媒体轨道。
  Future<void> dispose();
}

/// 基于 flutter_webrtc 的媒体引擎实现。
class FlutterRtcMediaEngine implements RtcMediaEngine {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _muted = false;

  final StreamController<RtcLocalCandidate> _candidates =
      StreamController<RtcLocalCandidate>.broadcast();
  final StreamController<String> _states =
      StreamController<String>.broadcast();

  @override
  Stream<RtcLocalCandidate> get onLocalCandidate => _candidates.stream;

  @override
  Stream<String> get onConnectionState => _states.stream;

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
    _pc = await createPeerConnection(_configuration);
    _pc!.onIceCandidate = (RTCIceCandidate c) {
      _candidates.add(RtcLocalCandidate(
        candidate: c.candidate ?? '',
        sdpMid: c.sdpMid,
        sdpMLineIndex: c.sdpMLineIndex ?? 0,
      ));
    };
    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      _states.add(state.toString().split('.').last);
    };

    _localStream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': video
          ? <String, dynamic>{'facingMode': 'user'}
          : false,
    });
    for (final MediaStreamTrack track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
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
  }

  @override
  Future<void> addCandidate(RtcLocalCandidate candidate) async {
    await _pc!.addCandidate(RTCIceCandidate(
      candidate.candidate,
      candidate.sdpMid,
      candidate.sdpMLineIndex,
    ));
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
  Future<void> dispose() async {
    await _candidates.close();
    await _states.close();
    await _localStream?.dispose();
    await _pc?.close();
    _localStream = null;
    _pc = null;
    _muted = false;
  }

  /// 本地媒体流，供通话页渲染小窗；未启动时为 null。
  MediaStream? get localStream => _localStream;

  /// 是否静音。
  bool get muted => _muted;
}
