// 远控媒体层：被控端采集屏幕并发送，控制端只收画面。
//
// 复用 flutter_webrtc：
//   - 屏幕采集：navigator.mediaDevices.getDisplayMedia（桌面原生实现）；
//   - 控制指令：三条 DataChannel（ctl 可靠 / ptr 低延迟 / bulk 分片）；
//   - 画质：getStats + RTCRtpSender.setParameters；
//   - 重连：restartIce + ICE restart offer。
//
// 抽象出 RemoteMediaEngine，便于用假实现测试状态机。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'remote_host_platform.dart';
import 'remote_session.dart';

/// 屏幕采集源（仅 id / 名称，几何由 DisplayGeometryProvider 补齐）。
class RemoteCaptureSource {
  const RemoteCaptureSource({required this.id, required this.name});

  final String id;
  final String name;
}

/// 本地 ICE 候选。
class RemoteIceCandidate {
  const RemoteIceCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  final String candidate;
  final String? sdpMid;
  final int sdpMLineIndex;
}

/// 媒体引擎接口。
abstract class RemoteMediaEngine {
  Stream<RemoteIceCandidate> get onLocalCandidate;
  Stream<String> get onConnectionState;
  Stream<String> get onControl;
  Stream<Uint8List> get onPointer;
  Stream<Uint8List> get onBulk;

  /// 被控端：创建 PeerConnection、采集屏幕、建立 DataChannel。
  Future<void> startHost({required String sourceId, int fps = 24});

  /// 控制端：创建 PeerConnection 与渲染器，等待远端轨道。
  Future<void> startController();

  Future<String> createOffer({bool iceRestart = false});
  Future<String> createAnswer();
  Future<void> setRemoteDescription(String sdp, String type);
  Future<void> addCandidate(RemoteIceCandidate candidate);
  Future<void> restartIce();
  Future<void> switchDisplay(String sourceId, {int fps = 24});
  Future<List<RemoteCaptureSource>> listSources();
  Future<void> setQuality(RemoteQuality quality);
  Future<RemoteNetworkStats> readStats();

  Future<void> sendControl(String text);
  Future<void> sendPointer(Uint8List bytes);
  Future<void> sendBulk(Uint8List bytes);
  bool get bulkWritable;

  Object? get remoteRenderer;

  Future<void> dispose();
}

/// flutter_webrtc 实现。
class FlutterRemoteMediaEngine implements RemoteMediaEngine {
  FlutterRemoteMediaEngine({
    this.iceServers = const <Map<String, dynamic>>[
      <String, dynamic>{
        'urls': <String>['stun:stun.l.google.com:19302'],
      },
    ],
  });

  final List<Map<String, dynamic>> iceServers;

  RTCPeerConnection? _pc;
  MediaStream? _screen;
  MediaStreamTrack? _screenTrack;
  RTCRtpSender? _sender;
  RTCVideoRenderer? _renderer;
  RTCDataChannel? _ctl;
  RTCDataChannel? _ptr;
  RTCDataChannel? _bulk;

  int _lastBytes = 0;
  int _lastStatsAt = 0;
  bool _disposed = false;

  final StreamController<RemoteIceCandidate> _localCandidates =
      StreamController<RemoteIceCandidate>.broadcast();
  final StreamController<String> _states = StreamController<String>.broadcast();
  final StreamController<String> _controls = StreamController<String>.broadcast();
  final StreamController<Uint8List> _pointers =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _bulks =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<RemoteIceCandidate> get onLocalCandidate => _localCandidates.stream;

  @override
  Stream<String> get onConnectionState => _states.stream;

  @override
  Stream<String> get onControl => _controls.stream;

  @override
  Stream<Uint8List> get onPointer => _pointers.stream;

  @override
  Stream<Uint8List> get onBulk => _bulks.stream;

  @override
  Object? get remoteRenderer => _renderer;

  @override
  Future<void> startHost({required String sourceId, int fps = 24}) async {
    await _ensurePeerConnection();
    _bindChannel(_ctl = await _pc!.createDataChannel(
      'rc-ctl',
      RTCDataChannelInit(),
    ));
    _bindChannel(_ptr = await _pc!.createDataChannel(
      'rc-ptr',
      RTCDataChannelInit()
        ..ordered = false
        ..maxRetransmitTime = 100,
    ));
    _bindChannel(_bulk = await _pc!.createDataChannel(
      'rc-bulk',
      RTCDataChannelInit(),
    ));
    await _captureScreen(sourceId, fps: fps);
  }

  @override
  Future<void> startController() async {
    await _ensurePeerConnection();
    _renderer = RTCVideoRenderer();
    await _renderer!.initialize();
    _pc!.onDataChannel = (RTCDataChannel channel) {
      _bindChannel(channel);
    };
    _pc!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) {
        return;
      }
      try {
        _renderer?.srcObject = event.streams.first;
      } on Object {
        // 渲染器尚未初始化完成时忽略，等下一次事件兜底。
      }
    };
  }

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) {
      return;
    }
    _pc = await createPeerConnection(<String, dynamic>{
      'iceServers': iceServers,
    });
    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      _localCandidates.add(RemoteIceCandidate(
        candidate: candidate.candidate ?? '',
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
      ));
    };
    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      _states.add(state.toString().split('.').last);
    };
    // Web 端 onIceConnectionState 常直接跳到 completed，需同时监听
    // PeerConnection 整体状态，避免控制端一直停在「连接中」。
    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      _states.add(state.toString().split('.').last);
    };
  }

  Future<void> _captureScreen(String sourceId, {int fps = 24}) async {
    // flutter_webrtc 在系统授权回调内部立即创建 MediaProjection，因此
    // mediaProjection 前台服务必须在此之前启动（Android 14+ 要求）。
    // targetSdk 34 下该启动不需要预先持有录屏令牌；失败只影响后台保活。
    try {
      await RemoteHostPlatform.startScreenCapture();
    } on Object {
      // 忽略：部分 ROM 会拒绝重复启动前台服务。
    }
    final MediaStream stream =
        await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
      'audio': false,
      'video': <String, dynamic>{
        'deviceId': <String, dynamic>{'exact': sourceId},
        'mandatory': <String, dynamic>{
          'frameRate': fps.toDouble(),
          'minFrameRate': 10.0,
        },
        'cursor': 'always',
      },
    });
    final List<MediaStreamTrack> tracks = stream.getVideoTracks();
    if (tracks.isEmpty) {
      await stream.dispose();
      throw StateError('屏幕采集未返回视频轨道');
    }
    final MediaStreamTrack track = tracks.first;
    await _sender?.replaceTrack(track);
    _sender ??= await _pc!.addTrack(track, stream);
    final MediaStream? oldStream = _screen;
    final MediaStreamTrack? oldTrack = _screenTrack;
    _screen = stream;
    _screenTrack = track;
    if (oldTrack != null && oldTrack.id != track.id) {
      try {
        await oldTrack.stop();
        await oldStream?.dispose();
      } on Object {
        // 旧轨道释放失败不影响新画面。
      }
    }
  }

  void _bindChannel(RTCDataChannel channel) {
    switch (channel.label) {
      case 'rc-ctl':
        _ctl = channel;
        channel.onMessage = (RTCDataChannelMessage message) {
          if (!message.isBinary) {
            _controls.add(message.text);
          }
        };
        break;
      case 'rc-ptr':
        _ptr = channel;
        channel.onMessage = (RTCDataChannelMessage message) {
          if (message.isBinary) {
            _pointers.add(message.binary);
          }
        };
        break;
      case 'rc-bulk':
        _bulk = channel;
        channel.onMessage = (RTCDataChannelMessage message) {
          if (message.isBinary) {
            _bulks.add(message.binary);
          }
        };
        break;
    }
  }

  @override
  Future<String> createOffer({bool iceRestart = false}) async {
    final RTCSessionDescription desc = iceRestart
        ? await _pc!.createOffer(<String, dynamic>{'iceRestart': true})
        : await _pc!.createOffer();
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
    _bindRemoteStreamIfNeeded();
  }

  void _bindRemoteStreamIfNeeded() {
    final RTCVideoRenderer? renderer = _renderer;
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
      // 渲染器初始化中，下一次事件会重试。
    }
  }

  @override
  Future<void> addCandidate(RemoteIceCandidate candidate) async {
    await _pc!.addCandidate(RTCIceCandidate(
      candidate.candidate,
      candidate.sdpMid,
      candidate.sdpMLineIndex,
    ));
    _bindRemoteStreamIfNeeded();
  }

  @override
  Future<void> restartIce() async {
    await _pc?.restartIce();
  }

  @override
  Future<void> switchDisplay(String sourceId, {int fps = 24}) async {
    await _captureScreen(sourceId, fps: fps);
  }

  @override
  Future<List<RemoteCaptureSource>> listSources() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // Android 没有多屏选择，getDisplayMedia 固定采集默认屏幕。
      return const <RemoteCaptureSource>[
        RemoteCaptureSource(id: 'screen', name: '本机屏幕'),
      ];
    }
    try {
      final List<DesktopCapturerSource> sources =
          await desktopCapturer.getSources(
        types: <SourceType>[SourceType.Screen],
      );
      return sources
          .map((DesktopCapturerSource s) =>
              RemoteCaptureSource(id: s.id, name: s.name))
          .toList(growable: false);
    } on Object {
      return const <RemoteCaptureSource>[];
    }
  }

  @override
  Future<void> setQuality(RemoteQuality quality) async {
    final RTCRtpSender? sender = _sender;
    if (sender == null) {
      return;
    }
    try {
      final RTCRtpParameters parameters = sender.parameters;
      final List<RTCRtpEncoding>? encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) {
        return;
      }
      for (final RTCRtpEncoding encoding in encodings) {
        encoding.maxBitrate = quality.maxBitrate;
        encoding.maxFramerate = quality.maxFps;
      }
      await sender.setParameters(parameters);
    } on Object {
      // 部分平台不接受参数修改，保持默认编码即可。
    }
  }

  @override
  Future<RemoteNetworkStats> readStats() async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null) {
      return RemoteNetworkStats.zero;
    }
    try {
      final List<StatsReport> reports = await pc.getStats();
      double fps = 0;
      int width = 0;
      int height = 0;
      int bytes = 0;
      int rttMs = 0;
      double loss = 0;
      for (final StatsReport report in reports) {
        final Map<dynamic, dynamic> v = report.values;
        if (report.type == 'outbound-rtp' &&
            '${v['kind'] ?? v['mediaType']}' == 'video') {
          fps = _num(v['framesPerSecond']);
          width = _num(v['frameWidth']).toInt();
          height = _num(v['frameHeight']).toInt();
          bytes = _num(v['bytesSent']).toInt();
        } else if (report.type == 'candidate-pair' &&
            '${v['state']}' == 'succeeded') {
          rttMs = (_num(v['currentRoundTripTime']) * 1000).round();
        } else if (report.type == 'remote-inbound-rtp') {
          loss = _num(v['fractionLost']);
        }
      }
      final int now = DateTime.now().millisecondsSinceEpoch;
      int kbps = 0;
      if (_lastStatsAt > 0 && now > _lastStatsAt && bytes >= _lastBytes) {
        kbps = ((bytes - _lastBytes) * 8 / (now - _lastStatsAt)).round();
      }
      _lastBytes = bytes;
      _lastStatsAt = now;
      return RemoteNetworkStats(
        fps: fps,
        bitrateKbps: kbps,
        rttMs: rttMs,
        packetLoss: loss,
        width: width,
        height: height,
      );
    } on Object {
      return RemoteNetworkStats.zero;
    }
  }

  static double _num(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse('$value') ?? 0;
  }

  @override
  Future<void> sendControl(String text) async {
    await _ctl?.send(RTCDataChannelMessage(text));
  }

  @override
  Future<void> sendPointer(Uint8List bytes) async {
    final RTCDataChannel? channel = _ptr;
    if (channel == null || (channel.bufferedAmount ?? 0) > 64 * 1024) {
      return; // 指针只保留最新帧，积压时直接丢弃。
    }
    await channel.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  @override
  Future<void> sendBulk(Uint8List bytes) async {
    await _bulk?.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  @override
  bool get bulkWritable => (_bulk?.bufferedAmount ?? 0) < 1024 * 1024;

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _localCandidates.close();
    await _states.close();
    await _controls.close();
    await _pointers.close();
    await _bulks.close();
    try {
      await _ctl?.close();
      await _ptr?.close();
      await _bulk?.close();
    } on Object {
      // 通道可能已由对端关闭。
    }
    _renderer?.srcObject = null;
    await _renderer?.dispose();
    _renderer = null;
    try {
      await _screenTrack?.stop();
      await _screen?.dispose();
    } on Object {
      // 采集轨道已释放时忽略。
    }
    _screenTrack = null;
    _screen = null;
    _sender = null;
    await _pc?.close();
    _pc = null;
    await RemoteHostPlatform.stopScreenCapture();
  }
}
