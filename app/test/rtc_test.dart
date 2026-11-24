// P6-28 验收：RTC 信令编解码、通话状态机与通话页 UI。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/rtc/call_page.dart';
import 'package:nexmem_app/features/rtc/call_service.dart';
import 'package:nexmem_app/features/rtc/rtc_media.dart';
import 'package:nexmem_app/features/rtc/rtc_signal.dart';
import 'package:nexmem_app/transport/transport.dart';

// ---------------- 测试替身 ----------------

class _FakeTransport implements CoreTransport {
  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    calls.add((method, params));
    return <String, dynamic>{};
  }

  final List<(String, Map<String, dynamic>?)> calls =
      <(String, Map<String, dynamic>?)>[];

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

class _FakeMedia implements RtcMediaEngine {
  final StreamController<RtcLocalCandidate> _cand =
      StreamController<RtcLocalCandidate>.broadcast();
  final StreamController<String> _state = StreamController<String>.broadcast();

  final List<String> calls = <String>[];
  bool disposed = false;

  @override
  Stream<RtcLocalCandidate> get onLocalCandidate => _cand.stream;

  @override
  Stream<String> get onConnectionState => _state.stream;

  @override
  Future<void> start({required bool video}) async {
    calls.add('start:${video ? 'video' : 'audio'}');
  }

  @override
  Future<String> createOffer() async {
    calls.add('offer');
    return 'v=0 offer-sdp';
  }

  @override
  Future<String> createAnswer() async {
    calls.add('answer');
    return 'v=0 answer-sdp';
  }

  @override
  Future<void> setRemoteDescription(String sdp, String type) async {
    calls.add('remote:$type');
  }

  @override
  Future<void> addCandidate(RtcLocalCandidate candidate) async {
    calls.add('candidate:${candidate.candidate}');
  }

  @override
  Future<void> setMuted(bool muted) async {
    calls.add('muted:$muted');
  }

  @override
  Future<void> setVideoEnabled(bool enabled) async {
    calls.add('video:$enabled');
  }

  @override
  Future<void> switchCamera() async {
    calls.add('switch-camera');
  }

  @override
  bool get hasVideo => false;

  @override
  Object? get remoteVideoRenderer => null;

  @override
  Object? get localVideoRenderer => null;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _cand.close();
    await _state.close();
  }

  void emitCandidate(String value) {
    _cand.add(RtcLocalCandidate(candidate: value, sdpMid: '0', sdpMLineIndex: 0));
  }

  void emitConnected() => _state.add('connected');
}

void main() {
  group('RtcSignal 编解码（工程方案 §3.6）', () {
    test('offer 往返保持类型与 SDP', () {
      const RtcSignal signal = RtcSignal(
        type: RtcSignalType.offer,
        sdp: 'v=0\r\no=- 1 2 IN IP4 127.0.0.1',
      );
      final RtcSignal decoded = RtcSignal.fromPayloadB64(signal.toPayloadB64());
      expect(decoded.type, RtcSignalType.offer);
      expect(decoded.sdp, signal.sdp);
    });

    test('candidate 保留 mid 与 index', () {
      const RtcSignal signal = RtcSignal(
        type: RtcSignalType.candidate,
        sdp: 'candidate:1 1 UDP 1 1.2.3.4 5000 typ host',
        mid: '0',
        index: 3,
      );
      final RtcSignal decoded = RtcSignal.fromPayloadB64(signal.toPayloadB64());
      expect(decoded.type, RtcSignalType.candidate);
      expect(decoded.mid, '0');
      expect(decoded.index, 3);
    });

    test('非法 base64 / 未知类型 / 不兼容版本被拒', () {
      expect(() => RtcSignal.fromPayloadB64('!!!'), throwsFormatException);
      final String unknownType = base64.encode(
        utf8.encode('{"v":1,"type":"weird","sdp":"x"}'),
      );
      expect(() => RtcSignal.fromPayloadB64(unknownType), throwsFormatException);
      final String badVersion = base64.encode(
        utf8.encode('{"v":99,"type":"offer","sdp":"x"}'),
      );
      expect(() => RtcSignal.fromPayloadB64(badVersion), throwsFormatException);
    });

    test('超过 64 KiB 的载荷在编码时被拒', () {
      final RtcSignal huge = RtcSignal(
        type: RtcSignalType.offer,
        sdp: 'x' * (kMaxRtcSignalBytes + 1),
      );
      expect(() => huge.encode(), throwsFormatException);
    });

    test('v2 保留会话标识、视频标记与成员列表', () {
      const RtcSignal signal = RtcSignal(
        type: RtcSignalType.offer,
        sdp: 'v=0 offer',
        callId: 'g-123',
        to: 'peer-1',
        video: true,
        members: <String>['peer-1', 'peer-2', 'peer-3'],
      );
      final RtcSignal decoded = RtcSignal.fromPayloadB64(signal.toPayloadB64());
      expect(decoded.callId, 'g-123');
      expect(decoded.to, 'peer-1');
      expect(decoded.video, isTrue);
      expect(decoded.members, <String>['peer-1', 'peer-2', 'peer-3']);
      final Map<String, dynamic> json = jsonDecode(utf8.decode(signal.encode()))
          as Map<String, dynamic>;
      expect(json['v'], 2);
    });

    test('纯 1v1 语音仍编码为 v1，保持旧端兼容', () {
      const RtcSignal signal = RtcSignal(
        type: RtcSignalType.offer,
        sdp: 'v=0 offer',
      );
      final Map<String, dynamic> json = jsonDecode(utf8.decode(signal.encode()))
          as Map<String, dynamic>;
      expect(json['v'], 1);
      expect(json.containsKey('call_id'), isFalse);
    });
  });

  group('CallService 通话状态机', () {
    test('主叫发 offer，收到 answer 后进入 connected', () async {
      final transport = _FakeTransport();
      late _FakeMedia media;
      final service = CallService(
        transport: transport,
        mediaFactory: () {
          media = _FakeMedia();
          return media;
        },
      );
      await service.startOutgoing('peer-abc', video: false);
      expect(transport.calls.length, 1);
      expect(transport.calls.single.$1, 'rtc.sendSignal');
      expect(transport.calls.single.$2!['peer'], 'peer-abc');
      final RtcSignal offer =
          RtcSignal.fromPayloadB64(transport.calls.single.$2!['payload_b64'] as String);
      expect(offer.type, RtcSignalType.offer);
      expect(service.current!.state, CallState.outgoing);

      final String answer = RtcSignal(
        type: RtcSignalType.answer,
        sdp: 'v=0 answer',
      ).toPayloadB64();
      await service.handleSignal('peer-abc', answer);
      expect(service.current!.state, CallState.connected);
      expect(media.calls, contains('remote:answer'));
      await service.dispose();
    });

    test('收到 offer 置来电状态，answer() 回 answer 并接通', () async {
      final transport = _FakeTransport();
      late _FakeMedia media;
      final service = CallService(
        transport: transport,
        mediaFactory: () {
          media = _FakeMedia();
          return media;
        },
      );
      final String offer = RtcSignal(
        type: RtcSignalType.offer,
        sdp: 'v=0 offer',
      ).toPayloadB64();
      await service.handleSignal('peer-xyz', offer);
      expect(service.current!.state, CallState.incoming);

      await service.answer();
      expect(transport.calls.length, 1);
      final RtcSignal answer =
          RtcSignal.fromPayloadB64(transport.calls.single.$2!['payload_b64'] as String);
      expect(answer.type, RtcSignalType.answer);
      expect(media.calls, contains('remote:offer'));
      expect(service.current!.state, CallState.connected);
      await service.dispose();
    });

    test('对端 candidate 交给媒体层，本地 candidate 经信令发出', () async {
      final transport = _FakeTransport();
      late _FakeMedia media;
      final service = CallService(
        transport: transport,
        mediaFactory: () {
          media = _FakeMedia();
          return media;
        },
      );
      await service.startOutgoing('peer-c');
      await service.handleSignal(
        'peer-c',
        RtcSignal(
          type: RtcSignalType.candidate,
          sdp: 'candidate:remote',
          mid: '0',
          index: 1,
        ).toPayloadB64(),
      );
      expect(media.calls, contains('candidate:candidate:remote'));

      media.emitCandidate('candidate:local');
      await Future<void>.delayed(Duration.zero);
      final RtcSignal last = RtcSignal.fromPayloadB64(
        transport.calls.last.$2!['payload_b64'] as String,
      );
      expect(last.type, RtcSignalType.candidate);
      expect(last.sdp, 'candidate:local');
      await service.dispose();
    });

    test('静音与挂断释放媒体并回到无通话', () async {
      final transport = _FakeTransport();
      late _FakeMedia media;
      final service = CallService(
        transport: transport,
        mediaFactory: () {
          media = _FakeMedia();
          return media;
        },
      );
      await service.startOutgoing('peer-m');
      await service.setMuted(true);
      expect(media.calls, contains('muted:true'));
      expect(service.current!.muted, isTrue);

      await service.endCall();
      expect(media.disposed, isTrue);
      expect(service.current, isNull);
      await service.dispose();
    });

    test('非法信令被忽略，不改动状态', () async {
      final transport = _FakeTransport();
      final service = CallService(
        transport: transport,
        mediaFactory: () => _FakeMedia(),
      );
      await service.handleSignal('peer-x', 'not-base64!!!');
      expect(service.current, isNull);
      expect(transport.calls, isEmpty);
      await service.dispose();
    });

    test('视频邀请在来电中可见，接听时采集视频', () async {
      final transport = _FakeTransport();
      late _FakeMedia media;
      final service = CallService(
        transport: transport,
        mediaFactory: () {
          media = _FakeMedia();
          return media;
        },
      );
      await service.handleSignal(
        'peer-v',
        RtcSignal(
          type: RtcSignalType.offer,
          sdp: 'v=0 offer',
          callId: 'd-v1',
          video: true,
        ).toPayloadB64(),
      );
      expect(service.current!.state, CallState.incoming);
      expect(service.current!.video, isTrue);

      await service.answer();
      expect(media.calls, contains('start:video'));
      final RtcSignal answer = RtcSignal.fromPayloadB64(
        transport.calls.single.$2!['payload_b64'] as String,
      );
      expect(answer.callId, 'd-v1');
      expect(answer.video, isTrue);
      await service.dispose();
    });

    test('群聊呼叫为每个成员各发一路 offer，并共享成员列表', () async {
      final transport = _FakeTransport();
      final List<_FakeMedia> medias = <_FakeMedia>[];
      final service = CallService(
        transport: transport,
        selfAccount: 'self',
        mediaFactory: () {
          final _FakeMedia media = _FakeMedia();
          medias.add(media);
          return media;
        },
      );
      await service.startGroupOutgoing(<String>['p1', 'p2', 'p3']);
      expect(transport.calls.length, 3);
      final List<RtcSignal> offers = transport.calls
          .map(
            ((String, Map<String, dynamic>?) entry) => RtcSignal.fromPayloadB64(
              entry.$2!['payload_b64'] as String,
            ),
          )
          .toList(growable: false);
      expect(offers.every((RtcSignal o) => o.type == RtcSignalType.offer), isTrue);
      expect(offers.map((RtcSignal o) => o.to).toSet(), <String>{'p1', 'p2', 'p3'});
      expect(offers.map((RtcSignal o) => o.callId).toSet().length, 1);
      expect(offers.every((RtcSignal o) => o.members.length == 3), isTrue);
      expect(service.current!.isGroup, isTrue);
      expect(service.current!.participants.length, 3);
      expect(medias.length, 3);
      await service.dispose();
    });

    test('通话中新成员加入时自动接通，不弹新的来电页', () async {
      final transport = _FakeTransport();
      final service = CallService(
        transport: transport,
        selfAccount: 'self',
        mediaFactory: () => _FakeMedia(),
      );
      await service.startGroupOutgoing(<String>['p1']);
      final String callId = service.current!.callId;

      await service.handleSignal(
        'p2',
        RtcSignal(
          type: RtcSignalType.offer,
          sdp: 'v=0 offer from p2',
          callId: callId,
          members: <String>['p1', 'p2'],
        ).toPayloadB64(),
      );
      expect(service.current!.state, isNot(CallState.incoming));
      expect(service.current!.participants.length, 2);
      final RtcSignal answer = RtcSignal.fromPayloadB64(
        transport.calls.last.$2!['payload_b64'] as String,
      );
      expect(answer.type, RtcSignalType.answer);
      await service.dispose();
    });

    test('摄像头开关与切换作用于所有会话', () async {
      final List<_FakeMedia> medias = <_FakeMedia>[];
      final service = CallService(
        transport: _FakeTransport(),
        selfAccount: 'self',
        mediaFactory: () {
          final _FakeMedia media = _FakeMedia();
          medias.add(media);
          return media;
        },
      );
      await service.startGroupOutgoing(<String>['p1', 'p2'], video: true);
      await service.setVideoEnabled(false);
      await service.switchCamera();
      for (final _FakeMedia media in medias) {
        expect(media.calls, contains('video:false'));
      }
      expect(medias.first.calls, contains('switch-camera'));
      await service.dispose();
    });
  });

  group('CallPage 通话 UI', () {
    testWidgets('来电显示接听与拒绝', (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: NexmemTheme.light(),
        home: CallPage(
          info: const CallInfo(
            state: CallState.incoming,
            peer: 'peer-abc',
            video: false,
          ),
          peerName: '张三',
          onAccept: () {},
          onReject: () {},
          onHangup: () {},
          onToggleMute: () {},
        ),
      ));
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('来电，是否接听？'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('call-accept')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('call-reject')), findsOneWidget);
    });

    testWidgets('通话中静音与挂断按钮回调', (WidgetTester tester) async {
      int muted = 0;
      int hung = 0;
      await tester.pumpWidget(MaterialApp(
        theme: NexmemTheme.light(),
        home: CallPage(
          info: const CallInfo(
            state: CallState.connected,
            peer: 'peer-abc',
            video: false,
          ),
          peerName: '张三',
          onAccept: () {},
          onReject: () {},
          onHangup: () => hung++,
          onToggleMute: () => muted++,
        ),
      ));
      expect(find.text('通话中'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('call-mute')));
      await tester.tap(find.byKey(const ValueKey<String>('call-hangup')));
      expect(muted, 1);
      expect(hung, 1);
    });

    testWidgets('群聊视频通话显示成员网格与摄像头按钮', (WidgetTester tester) async {
      int camera = 0;
      int switched = 0;
      await tester.pumpWidget(MaterialApp(
        theme: NexmemTheme.light(),
        home: CallPage(
          info: const CallInfo(
            state: CallState.connected,
            peer: 'p1',
            video: true,
            isGroup: true,
            callId: 'g-1',
            participants: <CallParticipant>[
              CallParticipant(peer: 'p1', video: true, connected: true),
              CallParticipant(peer: 'p2', video: true, connected: true),
              CallParticipant(peer: 'p3', video: true),
            ],
          ),
          peerName: '项目组',
          onAccept: () {},
          onReject: () {},
          onHangup: () {},
          onToggleMute: () {},
          onToggleCamera: () => camera++,
          onSwitchCamera: () => switched++,
        ),
      ));
      expect(find.text('3 人'), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('call-camera')));
      await tester.tap(find.byKey(const ValueKey<String>('call-switch-camera')));
      expect(camera, 1);
      expect(switched, 1);
    });
  });
}
