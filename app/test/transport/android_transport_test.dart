import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/android_transport.dart';
import 'package:nexmem_app/transport/transport.dart';

/// 以 mock MethodChannel 模拟 `NexmemPlugin`（P1-07）：
/// `call` 回响应信封、`replayedSince` 回事件帧数组、`ack` 记录水位、
/// `event` 由 `emitFromNative` 反向推给 Dart。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(AndroidTransport.channelName);
  const StandardMethodCodec codec = StandardMethodCodec();

  final List<MethodCall> log = <MethodCall>[];
  late int ackedSeq;
  late List<Map<String, dynamic>> replayFrames;
  late Map<String, dynamic> Function(Map<String, dynamic> request) onCall;
  String? dataDir;
  int startServiceCalls = 0;
  Map<String, dynamic>? pickedFile;
  bool pickFileFails = false;

  Map<String, dynamic> frame(int seq, String type) {
    return <String, dynamic>{
      'seq': seq,
      'type': type,
      'ts': 1000 + seq,
      'data': <String, dynamic>{'seq': seq},
    };
  }

  setUp(() {
    log.clear();
    ackedSeq = 0;
    replayFrames = <Map<String, dynamic>>[];
    dataDir = '/data/user/0/io.nexmem.nexmem_app/files';
    startServiceCalls = 0;
    pickedFile = null;
    pickFileFails = false;
    onCall = (Map<String, dynamic> request) => <String, dynamic>{
      'id': request['id'],
      'ok': true,
      'data': <String, dynamic>{'pong': true},
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          log.add(call);
          switch (call.method) {
            case 'ackedSeq':
              return ackedSeq;
            case 'replaySince':
              return jsonEncode(replayFrames);
            case 'ack':
              final Map<Object?, Object?> args =
                  (call.arguments as Map<Object?, Object?>?) ??
                  const <Object?, Object?>{};
              final int seq = (args['seq'] as num?)?.toInt() ?? 0;
              if (seq > ackedSeq) {
                ackedSeq = seq;
              }
              return null;
            case 'dataDir':
              return dataDir;
            case 'pickFile':
              if (pickFileFails) {
                throw PlatformException(code: 'PICK_FAILED', message: '选择器不可用');
              }
              return pickedFile;
            case 'startService':
              startServiceCalls++;
              return '';
            case 'stopService':
            case 'shutdown':
              return '';
            case 'call':
              final Map<Object?, Object?> args =
                  (call.arguments as Map<Object?, Object?>?) ??
                  const <Object?, Object?>{};
              final String request = args['request'] as String? ?? '{}';
              final Object? decoded = jsonDecode(request);
              if (decoded is! Map<String, dynamic>) {
                return jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': <String, dynamic>{'code': 'INVALID_ARG'},
                });
              }
              return jsonEncode(onCall(decoded));
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 模拟 Kotlin 侧 `ch.invokeMethod("event", payload)`。
  Future<void> emitFromNative(String payload) async {
    final ByteData data = codec.encodeMethodCall(MethodCall('event', payload));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(AndroidTransport.channelName, data, (ByteData? _) {});
  }

  test('connect 读取原生水位并按 since 重放事件', () async {
    ackedSeq = 5;
    replayFrames = <Map<String, dynamic>>[
      frame(6, 'message.new'),
      frame(7, 'state.changed'),
    ];
    final AndroidTransport transport = AndroidTransport(channel: channel);
    final List<CoreEvent> events = <CoreEvent>[];
    final StreamSubscription<CoreEvent> sub = transport.events.listen(events.add);

    await transport.connect();
    await pumpEventQueue();

    expect(events.map((CoreEvent e) => e.seq).toList(), <int>[6, 7]);
    expect(transport.lastSeq, 7);
    expect(log.map((MethodCall c) => c.method).take(2).toList(), <String>[
      'ackedSeq',
      'replaySince',
    ]);
    final MethodCall replay = log.firstWhere(
      (MethodCall c) => c.method == 'replaySince',
    );
    expect(
      (replay.arguments as Map<Object?, Object?>)['since'],
      5,
    );
    // 重放结果同样回写原生水位，避免下一次热重启重复重放。
    expect(ackedSeq, 7);

    await transport.close();
    await sub.cancel();
  });

  test('call 搬运请求信封并解出响应 data', () async {
    final AndroidTransport transport = AndroidTransport(channel: channel);
    await transport.connect();

    final Map<String, dynamic> data = await transport.call(
      'core.ping',
      params: <String, dynamic>{'x': 1},
    );
    expect(data['pong'], true);

    final MethodCall forwarded = log.firstWhere(
      (MethodCall c) => c.method == 'call',
    );
    final Map<String, dynamic> request =
        jsonDecode(
              (forwarded.arguments as Map<Object?, Object?>)['request'] as String,
            )
            as Map<String, dynamic>;
    expect(request['id'], 1);
    expect(request['method'], 'core.ping');
    expect(request['params'], <String, dynamic>{'x': 1});
    expect(request['timeout_ms'], 20000);

    await transport.close();
  });

  test('事件按 seq 去重，重复帧只交付一次', () async {
    final AndroidTransport transport = AndroidTransport(channel: channel);
    final List<CoreEvent> events = <CoreEvent>[];
    final StreamSubscription<CoreEvent> sub = transport.events.listen(events.add);
    await transport.connect();

    await emitFromNative(jsonEncode(frame(1, 'message.new')));
    await emitFromNative(jsonEncode(frame(1, 'message.new')));
    await pumpEventQueue();

    expect(events.length, 1);
    expect(events.single.seq, 1);
    expect(transport.lastSeq, 1);

    await transport.close();
    await sub.cancel();
  });

  test('序号缺口先下发 resync_required 再交付事件', () async {
    ackedSeq = 5;
    final AndroidTransport transport = AndroidTransport(channel: channel);
    final List<CoreEvent> events = <CoreEvent>[];
    final StreamSubscription<CoreEvent> sub = transport.events.listen(events.add);
    await transport.connect();

    await emitFromNative(jsonEncode(frame(8, 'message.new')));
    await pumpEventQueue();

    expect(events.length, 2);
    expect(events.first.isResync, true);
    expect(events.first.data['expected'], 6);
    expect(events.first.data['got'], 8);
    expect(events.last.seq, 8);
    expect(transport.lastSeq, 8);

    await transport.close();
    await sub.cancel();
  });

  test('缺口无法补齐时下发原生 resync_required', () async {
    ackedSeq = 9;
    replayFrames = <Map<String, dynamic>>[
      <String, dynamic>{
        'seq': 0,
        'type': 'resync_required',
        'data': <String, dynamic>{'reason': 'gap', 'oldest_seq': 20},
      },
    ];
    final AndroidTransport transport = AndroidTransport(channel: channel);
    final List<CoreEvent> events = <CoreEvent>[];
    final StreamSubscription<CoreEvent> sub = transport.events.listen(events.add);

    await transport.connect();
    await pumpEventQueue();

    expect(events.length, 1);
    expect(events.single.isResync, true);
    expect(events.single.data['oldest_seq'], 20);
    expect(transport.lastSeq, 9);

    await transport.close();
    await sub.cancel();
  });

  test('失败响应映射为 NexmemException 错误码与 retryable', () async {
    onCall = (Map<String, dynamic> request) => <String, dynamic>{
      'id': request['id'],
      'ok': false,
      'error': <String, dynamic>{
        'code': 'INVALID_ARG',
        'message': '缺少参数',
        'retryable': true,
      },
    };
    final AndroidTransport transport = AndroidTransport(channel: channel);
    await transport.connect();

    await expectLater(
      transport.call('dm.sendText'),
      throwsA(
        isA<NexmemException>()
            .having((NexmemException e) => e.code, 'code', 'INVALID_ARG')
            .having((NexmemException e) => e.retryable, 'retryable', true),
      ),
    );

    await transport.close();
  });

  test('未连接时调用返回 NOT_ONLINE，关闭后返回 NOT_STARTED', () async {
    final AndroidTransport transport = AndroidTransport(channel: channel);
    await expectLater(
      transport.call('core.ping'),
      throwsA(
        isA<NexmemException>().having(
          (NexmemException e) => e.code,
          'code',
          'NOT_ONLINE',
        ),
      ),
    );

    await transport.connect();
    await transport.close();
    await expectLater(
      transport.call('core.ping'),
      throwsA(
        isA<NexmemException>().having(
          (NexmemException e) => e.code,
          'code',
          'NOT_STARTED',
        ),
      ),
    );
  });

  test('appDataDir 与前台服务开关经通道调用', () async {
    final AndroidTransport transport = AndroidTransport(channel: channel);
    await transport.connect();

    expect(await transport.appDataDir(), '/data/user/0/io.nexmem.nexmem_app/files');
    expect(await transport.startForegroundService(), true);
    expect(startServiceCalls, 1);
    expect(log.map((MethodCall c) => c.method), contains('startService'));

    await transport.close();
  });

  test('openAndroidSession 注入 filesDir 作为 data_dir 并拉起前台服务', () async {
    final session = await openAndroidSession();
    expect(session, isNotNull);
    expect(
      session!.startConfig,
      <String, dynamic>{'data_dir': '/data/user/0/io.nexmem.nexmem_app/files'},
    );
    expect(session.pickFile, isNotNull);
    expect(startServiceCalls, 1);
    await session.transport.close();
  });

  test('pickFile 把原生回包映射为附件，取消返回 null', () async {
    final AndroidTransport transport = AndroidTransport(channel: channel);
    await transport.connect();

    pickedFile = <String, dynamic>{
      'name': 'a.txt',
      'size': 12,
      'mime': 'text/plain',
      'path': '/data/cache/nexmem-picked/1-a.txt',
    };
    final attachment = await transport.pickFile();
    expect(attachment, isNotNull);
    expect(attachment!.name, 'a.txt');
    expect(attachment.size, 12);
    expect(attachment.mime, 'text/plain');
    expect(attachment.path, '/data/cache/nexmem-picked/1-a.txt');
    expect(log.map((MethodCall c) => c.method), contains('pickFile'));

    pickedFile = null;
    expect(await transport.pickFile(), isNull);

    await transport.close();
  });

  test('pickFile 原生失败映射为 NOT_ONLINE', () async {
    final AndroidTransport transport = AndroidTransport(channel: channel);
    await transport.connect();
    pickFileFails = true;

    await expectLater(
      transport.pickFile(),
      throwsA(
        isA<NexmemException>()
            .having((NexmemException e) => e.code, 'code', 'NOT_ONLINE')
            .having((NexmemException e) => e.retryable, 'retryable', true),
      ),
    );

    await transport.close();
  });

  test('数据目录不可用时 openAndroidSession 返回 null', () async {
    dataDir = null;
    expect(await openAndroidSession(), isNull);
  });

  group('androidStartConfig', () {
    test('未注入网络配置时仅包含数据目录', () {
      final Map<String, dynamic> config = androidStartConfig('/data/user/0/x/files');
      expect(config['data_dir'], '/data/user/0/x/files');
      expect(config.containsKey('bootstraps'), isFalse);
      expect(config.containsKey('directory_url'), isFalse);
      expect(config.containsKey('relay_addrs'), isFalse);
    });

    test('引导节点、索引服务与中继地址按逗号拆分并去除空白', () {
      final Map<String, dynamic> config = androidCoreStartConfig(
        dataDir: '/data/user/0/x/files',
        bootstraps: ' /ip4/1.2.3.4/tcp/14001/p2p/12D3KooA , , /ip4/5.6.7.8/tcp/14001/p2p/12D3KooB ',
        directoryUrl: ' http://1.2.3.4:8081 ',
        relayAddrs: '/ip4/1.2.3.4/tcp/14002/p2p/12D3KooR1, /ip4/2.2.2.2/tcp/14002/p2p/12D3KooR2',
      );
      expect(config['bootstraps'], <String>[
        '/ip4/1.2.3.4/tcp/14001/p2p/12D3KooA',
        '/ip4/5.6.7.8/tcp/14001/p2p/12D3KooB',
      ]);
      expect(config['directory_url'], 'http://1.2.3.4:8081');
      expect(config['relay_addrs'], <String>[
        '/ip4/1.2.3.4/tcp/14002/p2p/12D3KooR1',
        '/ip4/2.2.2.2/tcp/14002/p2p/12D3KooR2',
      ]);
    });

    test('中继地址为空时不会写入 relay_addrs', () {
      final Map<String, dynamic> config = androidCoreStartConfig(
        dataDir: '/data/user/0/x/files',
        bootstraps: '',
        directoryUrl: '',
        relayAddrs: '  , ,  ',
      );
      expect(config, <String, dynamic>{'data_dir': '/data/user/0/x/files'});
    });

    test('三种发现源配置按开关与列表正确注入', () {
      final Map<String, dynamic> config = androidCoreStartConfig(
        dataDir: '/data/user/0/x/files',
        bootstraps: '',
        directoryUrl: '',
        relayAddrs: '',
        mdns: 'true',
        publicDht: 'true',
        manualAddrs: '/ip4/192.168.1.10/tcp/4001/p2p/12D3KooW1, /ip4/1.2.3.4/udp/4001/quic-v1/p2p/12D3KooW2',
      );
      expect(config['enable_mdns'], isTrue);
      expect(config['public_dht'], isTrue);
      expect(config['manual_addrs'], <String>[
        '/ip4/192.168.1.10/tcp/4001/p2p/12D3KooW1',
        '/ip4/1.2.3.4/udp/4001/quic-v1/p2p/12D3KooW2',
      ]);
    });

    test('发现源未注入时不写入任何相关键', () {
      final Map<String, dynamic> config = androidCoreStartConfig(
        dataDir: '/data/user/0/x/files',
        bootstraps: '',
        directoryUrl: '',
        relayAddrs: '',
      );
      expect(config.containsKey('enable_mdns'), isFalse);
      expect(config.containsKey('public_dht'), isFalse);
      expect(config.containsKey('manual_addrs'), isFalse);
    });
  });
}
