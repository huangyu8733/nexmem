// 远控状态机测试：授权、信令、媒体、输入注入、token 校验。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/features/remote/input/desktop_input_injector.dart';
import 'package:nexmem_app/features/remote/input/display_geometry.dart';
import 'package:nexmem_app/features/remote/remote_control_service.dart';
import 'package:nexmem_app/features/remote/remote_input_codec.dart';
import 'package:nexmem_app/features/remote/remote_media.dart';
import 'package:nexmem_app/features/remote/remote_prefs.dart';
import 'package:nexmem_app/features/remote/remote_session.dart';
import 'package:nexmem_app/features/remote/remote_signal.dart';
import 'package:nexmem_app/features/remote/remote_storage_stub.dart';
import 'package:nexmem_app/transport/transport.dart';

class _FakeTransport implements CoreTransport {
  final List<(String, Map<String, dynamic>?)> calls =
      <(String, Map<String, dynamic>?)>[];

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    calls.add((method, params));
    return <String, dynamic>{};
  }

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<void> close() async {}
}

class _FakeMedia implements RemoteMediaEngine {
  final StreamController<RemoteIceCandidate> _candidates =
      StreamController<RemoteIceCandidate>.broadcast();
  final StreamController<String> _states = StreamController<String>.broadcast();
  final StreamController<String> _controls = StreamController<String>.broadcast();
  final StreamController<Uint8List> _pointers =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _bulks =
      StreamController<Uint8List>.broadcast();

  bool hostStarted = false;
  bool controllerStarted = false;
  bool disposed = false;
  String? sourceId;
  RemoteQuality? quality;
  String? switchedTo;
  final List<Uint8List> sentPointers = <Uint8List>[];
  final List<String> sentControls = <String>[];
  final List<Uint8List> sentBulk = <Uint8List>[];

  @override
  Stream<RemoteIceCandidate> get onLocalCandidate => _candidates.stream;

  @override
  Stream<String> get onConnectionState => _states.stream;

  @override
  Stream<String> get onControl => _controls.stream;

  @override
  Stream<Uint8List> get onPointer => _pointers.stream;

  @override
  Stream<Uint8List> get onBulk => _bulks.stream;

  @override
  Object? get remoteRenderer => null;

  @override
  Future<void> startHost({required String sourceId, int fps = 24}) async {
    hostStarted = true;
    this.sourceId = sourceId;
  }

  @override
  Future<void> startController() async {
    controllerStarted = true;
  }

  @override
  Future<String> createOffer({bool iceRestart = false}) async => 'offer-sdp';

  @override
  Future<String> createAnswer() async => 'answer-sdp';

  @override
  Future<void> setRemoteDescription(String sdp, String type) async {}

  @override
  Future<void> addCandidate(RemoteIceCandidate candidate) async {}

  @override
  Future<void> restartIce() async {}

  @override
  Future<void> switchDisplay(String sourceId, {int fps = 24}) async {
    switchedTo = sourceId;
  }

  @override
  Future<List<RemoteCaptureSource>> listSources() async =>
      const <RemoteCaptureSource>[
        RemoteCaptureSource(id: '1', name: '屏幕 1'),
      ];

  @override
  Future<void> setQuality(RemoteQuality quality) async {
    this.quality = quality;
  }

  @override
  Future<RemoteNetworkStats> readStats() async => RemoteNetworkStats.zero;

  @override
  Future<void> sendControl(String text) async {
    sentControls.add(text);
  }

  @override
  Future<void> sendPointer(Uint8List bytes) async {
    sentPointers.add(bytes);
  }

  @override
  Future<void> sendBulk(Uint8List bytes) async {
    sentBulk.add(bytes);
  }

  @override
  bool get bulkWritable => true;

  void emitControl(String text) => _controls.add(text);

  void emitPointer(Uint8List bytes) => _pointers.add(bytes);

  void emitState(String state) => _states.add(state);

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeInjector implements DesktopInputInjector {
  final List<RemotePointerEvent> pointers = <RemotePointerEvent>[];
  final List<String> keys = <String>[];
  final List<String> texts = <String>[];

  @override
  bool get supportsInput => true;

  @override
  String get permissionHint => '测试';

  @override
  Future<InputPermissionStatus> checkPermissions() async =>
      InputPermissionStatus.granted;

  @override
  Future<InputPermissionStatus> requestPermissions() async =>
      InputPermissionStatus.granted;

  @override
  Future<void> pointer(
    RemotePointerEvent event, {
    required RemoteDisplay display,
  }) async {
    pointers.add(event);
  }

  @override
  Future<void> key(String key, {required bool down, int modifiers = 0}) async {
    keys.add('$key:${down ? 'down' : 'up'}');
  }

  @override
  Future<void> text(String text) async {
    texts.add(text);
  }

  @override
  Future<void> dispose() async {}
}

class _FakeGeometry implements DisplayGeometryProvider {
  @override
  Future<List<RemoteDisplay>> list() async => const <RemoteDisplay>[
        RemoteDisplay(
          id: '1',
          name: '屏幕 1',
          index: 0,
          x: 0,
          y: 0,
          width: 1920,
          height: 1080,
          pixelWidth: 1920,
          pixelHeight: 1080,
          primary: true,
        ),
      ];

  @override
  Future<void> dispose() async {}
}

const String _peer = 'peer-a';

RemoteControlService _service(
  _FakeTransport transport,
  _FakeMedia media,
  _FakeInjector injector, {
  bool enabled = true,
  String passwordCredential = '',
}) {
  RemotePrefs.instance
    ..enabled = enabled
    ..requireConfirm = true
    ..allowInput = true
    ..allowClipboard = true
    ..allowFile = true
    ..passwordCredential = passwordCredential
    ..loaded = true;
  return RemoteControlService(
    transport: transport,
    mediaFactory: () => media,
    injector: injector,
    geometry: _FakeGeometry(),
    storage: MemoryRemoteStorage(),
    requestTimeout: const Duration(seconds: 30),
    connectTimeout: const Duration(seconds: 30),
  );
}

List<RemoteSignal> _sent(_FakeTransport transport) {
  final List<RemoteSignal> result = <RemoteSignal>[];
  for (final (String method, Map<String, dynamic>? params)
      in transport.calls) {
    if (method != 'rtc.sendSignal' || params == null) {
      continue;
    }
    final Object? payload = params['payload_b64'];
    if (payload is String) {
      result.add(RemoteSignal.fromPayloadB64(payload));
    }
  }
  return result;
}

RemoteSignal _requestSignal({
  String sid = 'r-1',
  String credential = '',
  bool silent = false,
}) =>
    RemoteSignal(
      type: RemoteSignalType.request,
      sid: sid,
      name: '测试端',
      permissions: RemotePermissions.all,
      credential: credential,
      silent: silent,
    );

void main() {
  setUp(() {
    // 测试宿主按桌面被控端运行，避免移动端「仅控制端」分支干扰。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('被控端授权后启动采集并建立会话，输入事件经注入器执行', () async {
    final _FakeTransport transport = _FakeTransport();
    final _FakeMedia media = _FakeMedia();
    final _FakeInjector injector = _FakeInjector();
    final RemoteControlService service =
        _service(transport, media, injector);
    await service.initialize();
    addTearDown(service.dispose);

    await service.handleSignal(_peer, _requestSignal().toPayloadB64());
    expect(service.current?.state, RemoteState.incoming);
    expect(service.current?.isHost, isTrue);

    await service.accept(permissions: RemotePermissions.all);
    expect(media.hostStarted, isTrue);
    expect(media.sourceId, '1');
    final List<RemoteSignal> sent = _sent(transport);
    final RemoteSignal accept =
        sent.firstWhere((RemoteSignal s) => s.type == RemoteSignalType.accept);
    expect(accept.permissions.input, isTrue);
    expect(accept.displays.single.id, '1');
    expect(
      sent.any((RemoteSignal s) => s.type == RemoteSignalType.offer),
      isTrue,
    );

    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.answer,
        sid: accept.sid,
        token: accept.token,
        sdp: 'answer-sdp',
      ).toPayloadB64(),
    );
    expect(service.current?.state, RemoteState.active);
    expect(media.quality, isNotNull);

    media.emitPointer(RemotePointerCodec.encode(
      const RemotePointerEvent(
        type: RemotePointerType.move,
        xNorm: 100,
        yNorm: 200,
      ),
    ));
    await pumpEventQueue();
    expect(injector.pointers, hasLength(1));
    expect(injector.pointers.single.xNorm, 100);

    media.emitControl(jsonEncode(<String, dynamic>{
      't': 'key',
      'key': 'a',
      'down': true,
      'mod': 0,
    }));
    await pumpEventQueue();
    expect(injector.keys, contains('a:down'));

    await service.end();
    expect(service.current?.state, RemoteState.ended);
  });

  test('错误 token 的结束信令被忽略', () async {
    final _FakeTransport transport = _FakeTransport();
    final _FakeMedia media = _FakeMedia();
    final RemoteControlService service =
        _service(transport, media, _FakeInjector());
    await service.initialize();
    addTearDown(service.dispose);

    await service.handleSignal(_peer, _requestSignal().toPayloadB64());
    await service.accept(permissions: RemotePermissions.all);
    final RemoteSignal accept = _sent(transport)
        .firstWhere((RemoteSignal s) => s.type == RemoteSignalType.accept);
    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.answer,
        sid: accept.sid,
        token: accept.token,
        sdp: 'answer-sdp',
      ).toPayloadB64(),
    );
    expect(service.current?.state, RemoteState.active);

    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.end,
        sid: accept.sid,
        token: 'bad-token',
      ).toPayloadB64(),
    );
    expect(service.current?.state, RemoteState.active);
  });

  test('被控端关闭时直接拒绝请求', () async {
    final _FakeTransport transport = _FakeTransport();
    final _FakeMedia media = _FakeMedia();
    final RemoteControlService service =
        _service(transport, media, _FakeInjector(), enabled: false);
    await service.initialize();
    addTearDown(service.dispose);

    await service.handleSignal(_peer, _requestSignal().toPayloadB64());
    expect(service.current, isNull);
    final List<RemoteSignal> sent = _sent(transport);
    expect(sent.single.type, RemoteSignalType.reject);
    expect(sent.single.reason, '被控端未开启远程控制');
  });

  test('被控端设置密码后拒绝无密码或错误密码的远控请求', () async {
    final _FakeTransport transport = _FakeTransport();
    final RemoteControlService service = _service(
      transport,
      _FakeMedia(),
      _FakeInjector(),
      passwordCredential: 'hash-abc',
    );
    await service.initialize();
    addTearDown(service.dispose);

    await service.handleSignal(
      _peer,
      _requestSignal(silent: true).toPayloadB64(),
    );
    expect(service.current, isNull);
    expect(_sent(transport).single.reason, '远程控制密码错误');

    transport.calls.clear();
    await service.handleSignal(
      _peer,
      _requestSignal(sid: 'r-2', credential: 'wrong', silent: true)
          .toPayloadB64(),
    );
    expect(service.current, isNull);
    expect(_sent(transport).single.reason, '远程控制密码错误');
  });

  test('聊天发起的远控即使本机有密码也仍需确认', () async {
    final _FakeTransport transport = _FakeTransport();
    final RemoteControlService service = _service(
      transport,
      _FakeMedia(),
      _FakeInjector(),
      passwordCredential: 'hash-abc',
    );
    await service.initialize();
    addTearDown(service.dispose);

    await service.handleSignal(_peer, _requestSignal().toPayloadB64());
    expect(service.current?.state, RemoteState.incoming);
    expect(service.current?.isHost, isTrue);
    expect(_sent(transport), isEmpty);
  });

  test('被控端收到正确密码校验值后静默接受台账远控', () async {
    final _FakeTransport transport = _FakeTransport();
    final RemoteControlService service = _service(
      transport,
      _FakeMedia(),
      _FakeInjector(),
      passwordCredential: 'hash-abc',
    );
    await service.initialize();
    addTearDown(service.dispose);

    await service.handleSignal(
      _peer,
      _requestSignal(credential: 'hash-abc', silent: true).toPayloadB64(),
    );
    expect(service.current?.isHost, isTrue);
    expect(service.current?.state, RemoteState.connecting);
    expect(
      _sent(transport).any((RemoteSignal s) => s.type == RemoteSignalType.accept),
      isTrue,
    );
  });

  test('控制端完成 offer/answer 后进入 active，并能发送输入', () async {
    final _FakeTransport transport = _FakeTransport();
    final _FakeMedia media = _FakeMedia();
    final RemoteControlService service =
        _service(transport, media, _FakeInjector());
    await service.initialize();
    addTearDown(service.dispose);

    await service.request(_peer, peerName: '对端');
    expect(service.current?.state, RemoteState.outgoing);
    final RemoteSignal request = _sent(transport).single;
    expect(request.type, RemoteSignalType.request);

    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.accept,
        sid: request.sid,
        token: 'token-1',
        permissions: RemotePermissions.all,
        displays: const <RemoteDisplay>[
          RemoteDisplay(
            id: '1',
            name: '屏幕 1',
            index: 0,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            primary: true,
          ),
        ],
        displayId: '1',
      ).toPayloadB64(),
    );
    expect(media.controllerStarted, isTrue);
    expect(service.current?.state, RemoteState.connecting);

    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.offer,
        sid: request.sid,
        token: 'token-1',
        sdp: 'offer-sdp',
      ).toPayloadB64(),
    );
    expect(
      _sent(transport)
          .any((RemoteSignal s) => s.type == RemoteSignalType.answer),
      isTrue,
    );

    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.answer,
        sid: request.sid,
        token: 'token-1',
        sdp: 'answer-sdp',
      ).toPayloadB64(),
    );
    expect(service.current?.state, RemoteState.active);

    await service.sendKey('a', down: true);
    await service.sendPointer(const RemotePointerEvent(
      type: RemotePointerType.move,
      xNorm: 10,
      yNorm: 20,
    ));
    expect(media.sentControls, hasLength(1));
    expect(media.sentPointers, hasLength(1));
  });

  test('ICE 失败收尾时向对端广播 end，避免状态漂移', () async {
    final _FakeTransport transport = _FakeTransport();
    final _FakeMedia media = _FakeMedia();
    final RemoteControlService service =
        _service(transport, media, _FakeInjector());
    await service.initialize();
    addTearDown(service.dispose);

    await service.request(_peer, peerName: '对端');
    final RemoteSignal request = _sent(transport).single;
    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.accept,
        sid: request.sid,
        token: 'token-1',
        permissions: RemotePermissions.all,
        displays: const <RemoteDisplay>[
          RemoteDisplay(
            id: '1',
            name: '屏幕 1',
            index: 0,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            primary: true,
          ),
        ],
        displayId: '1',
      ).toPayloadB64(),
    );
    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.answer,
        sid: request.sid,
        token: 'token-1',
        sdp: 'answer-sdp',
      ).toPayloadB64(),
    );
    expect(service.current?.state, RemoteState.active);

    // 媒体面 failed 先进入 reconnecting，两次重连耗尽后 _fail 必须通知对端。
    final int before = _sent(transport).length;
    media.emitState('RTCPeerConnectionStateFailed');
    await Future<void>.delayed(Duration.zero);
    expect(service.current?.state, RemoteState.reconnecting);
    media.emitState('RTCPeerConnectionStateFailed');
    await Future<void>.delayed(Duration.zero);
    media.emitState('RTCPeerConnectionStateFailed');
    await Future<void>.delayed(Duration.zero);
    expect(service.current?.state, RemoteState.failed);
    final List<RemoteSignal> after = _sent(transport);
    expect(after.length, greaterThan(before));
    expect(
      after.any((RemoteSignal s) =>
          s.type == RemoteSignalType.end && s.sid == request.sid),
      isTrue,
    );
  });

  test('ICE 重连成功后恢复暂停态，避免界面误显示控制中', () async {
    final _FakeTransport transport = _FakeTransport();
    final _FakeMedia media = _FakeMedia();
    final RemoteControlService service =
        _service(transport, media, _FakeInjector());
    await service.initialize();
    addTearDown(service.dispose);

    await service.request(_peer, peerName: '对端');
    final RemoteSignal request = _sent(transport).single;
    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.accept,
        sid: request.sid,
        token: 'token-1',
        permissions: RemotePermissions.all,
        displays: const <RemoteDisplay>[
          RemoteDisplay(
            id: '1',
            name: '屏幕 1',
            index: 0,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            primary: true,
          ),
        ],
        displayId: '1',
      ).toPayloadB64(),
    );
    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.answer,
        sid: request.sid,
        token: 'token-1',
        sdp: 'answer-sdp',
      ).toPayloadB64(),
    );
    expect(service.current?.state, RemoteState.active);

    await service.handleSignal(
      _peer,
      RemoteSignal(
        type: RemoteSignalType.pause,
        sid: request.sid,
        token: 'token-1',
      ).toPayloadB64(),
    );
    expect(service.current?.state, RemoteState.paused);

    media.emitState('RTCIceConnectionStateDisconnected');
    await Future<void>.delayed(Duration.zero);
    expect(service.current?.state, RemoteState.reconnecting);

    media.emitState('RTCIceConnectionStateConnected');
    await Future<void>.delayed(Duration.zero);
    expect(service.current?.state, RemoteState.paused);
  });

  test('Android 可作为被控端接受请求并启动采集', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final _FakeTransport transport = _FakeTransport();
    final _FakeMedia media = _FakeMedia();
    final RemoteControlService service =
        _service(transport, media, _FakeInjector());
    await service.initialize();
    addTearDown(service.dispose);

    await service.handleSignal(_peer, _requestSignal().toPayloadB64());
    expect(service.current?.isHost, isTrue);
    expect(service.current?.state, RemoteState.incoming);

    await service.accept(permissions: RemotePermissions.all);
    expect(media.hostStarted, isTrue);
    final List<RemoteSignal> sent = _sent(transport);
    expect(
      sent.any((RemoteSignal s) => s.type == RemoteSignalType.accept),
      isTrue,
    );
    expect(
      sent.any((RemoteSignal s) => s.type == RemoteSignalType.offer),
      isTrue,
    );
  });

  test('被控支持矩阵：桌面与 Android 支持，iOS/Web 仅控制端', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(RemoteControlService.hostSupported, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(RemoteControlService.hostSupported, isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(RemoteControlService.hostSupported, isTrue);
  });
}
