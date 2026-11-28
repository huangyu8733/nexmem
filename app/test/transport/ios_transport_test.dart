import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/android_transport.dart';
import 'package:nexmem_app/transport/ios_transport.dart';

/// 以 mock MethodChannel 模拟 iOS 插件（P1-08）：
/// 通道契约与 Android 一致，但不含 `startService` / `stopService`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(AndroidTransport.channelName);

  final List<MethodCall> log = <MethodCall>[];
  late int ackedSeq;
  String? dataDir;
  Map<String, dynamic>? pickedFile;

  setUp(() {
    log.clear();
    ackedSeq = 0;
    dataDir = '/var/mobile/Containers/Data/Application/nexmem/Library/Application Support';
    pickedFile = <String, dynamic>{
      'name': 'report.pdf',
      'size': 1024,
      'mime': 'application/pdf',
      'path': '$dataDir/nexmem-picked/report.pdf',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          log.add(call);
          switch (call.method) {
            case 'ackedSeq':
              return ackedSeq;
            case 'replaySince':
              return '[]';
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
            case 'pickImage':
              return pickedFile;
            case 'call':
              final Map<Object?, Object?> args =
                  (call.arguments as Map<Object?, Object?>?) ??
                  const <Object?, Object?>{};
              final Object? decoded = jsonDecode(
                args['request'] as String? ?? '{}',
              );
              final String id = decoded is Map<String, dynamic>
                  ? decoded['id']?.toString() ?? '0'
                  : '0';
              return jsonEncode(<String, dynamic>{
                'id': id,
                'ok': true,
                'data': <String, dynamic>{'pong': true},
              });
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('IOSTransport 使用与 Android 相同的通道契约', () async {
    final IOSTransport transport = IOSTransport();
    await transport.connect();
    final Map<String, dynamic> data = await transport.call('ping');
    expect(data['pong'], isTrue);
    expect(
      log.map((MethodCall call) => call.method),
      containsAll(<String>['ackedSeq', 'replaySince', 'call']),
    );
    await transport.close();
  });

  test('openIOSSession 注入沙盒数据目录且不拉起前台服务', () async {
    final session = await openIOSSession();
    expect(session, isNotNull);
    expect(session!.startConfig?['data_dir'], dataDir);
    expect(session.pickFile, isNotNull);
    expect(session.pickImage, isNotNull);
    final List<String> methods = log
        .map((MethodCall call) => call.method)
        .toList();
    expect(methods, isNot(contains('startService')));
    expect(methods, isNot(contains('stopService')));
    await session.close();
  });

  test('openIOSSession 在数据目录不可用时返回 null', () async {
    dataDir = null;
    expect(await openIOSSession(), isNull);
  });
}
