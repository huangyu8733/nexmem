import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexmem_app/transport/transport.dart';

/// 跨端契约测试的 Dart 侧驱动器（X-03）。
///
/// 与 Go 侧 `core/contract/contract_test.go` 读取同一批 `contract/cases/*.json`：
/// Go 校验 `gateway.Handle` 的实际输出，这里校验请求/响应信封的编解码结果，
/// 保证两端对同一份契约的理解一致。
void main() {
  final api = _readJson('../core/contract/api.json') as Map<String, dynamic>;
  final methods = <String>{
    for (final item in api['methods'] as List)
      (item as Map)['name'] as String,
  };
  final errorSpecs = <String, Map<String, dynamic>>{};
  for (final item in api['errors'] as List) {
    final spec = (item as Map).cast<String, dynamic>();
    errorSpecs[spec['code'] as String] = spec;
  }

  final files = Directory('../core/contract/cases')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('契约用例文件存在', () {
    expect(files, isNotEmpty);
  });

  // 与 Go 侧 TestEveryContractMethodHasCase 同口径：契约中的每个方法都必须
  // 至少被一条用例覆盖，避免新增方法时漏掉跨端一致性校验。
  test('每个契约方法都有用例覆盖', () {
    final covered = <String>{};
    for (final file in files) {
      final doc = _readJson(file.path) as Map<String, dynamic>;
      for (final raw in doc['cases'] as List) {
        final request = ((raw as Map)['request'] as Map).cast<String, dynamic>();
        covered.add(request['method'] as String);
      }
    }
    final missing = methods.difference(covered).toList()..sort();
    expect(missing, isEmpty, reason: '缺少用例: ${missing.join(', ')}');
  });

  test('聊天正文在契约层声明 4096 字符上限', () {
    final byName = <String, Map<String, dynamic>>{
      for (final item in api['methods'] as List)
        (item as Map)['name'] as String: item.cast<String, dynamic>(),
    };
    for (final method in const <String>[
      'dm.sendText',
      'dm.sendGroupText',
      'msg.edit',
    ]) {
      final params = byName[method]!['params'] as Map<String, dynamic>;
      final props = (params['properties'] as Map).cast<String, dynamic>();
      final text = (props['text'] as Map).cast<String, dynamic>();
      expect(text['maxLength'], 4096, reason: '$method.text 缺少长度约束');
    }
  });

  for (final file in files) {
    final doc = _readJson(file.path) as Map<String, dynamic>;
    group(file.uri.pathSegments.last, () {
      test('version 受支持', () {
        expect(doc['version'], 1);
      });
      for (final raw in doc['cases'] as List) {
        final item = (raw as Map).cast<String, dynamic>();
        test(item['id'] as String, () {
          _verifyCase(item, methods, errorSpecs);
        });
      }
    });
  }
}

Object? _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync());

void _verifyCase(
  Map<String, dynamic> item,
  Set<String> methods,
  Map<String, Map<String, dynamic>> errorSpecs,
) {
  final request = (item['request'] as Map).cast<String, dynamic>();
  final expected = (item['expect'] as Map).cast<String, dynamic>();
  final response = (item['response'] as Map).cast<String, dynamic>();
  final method = request['method'] as String;

  // 用例与契约文件必须自洽。
  final unknown = item['unknown_method'] == true;
  expect(
    methods.contains(method),
    unknown ? isFalse : isTrue,
    reason: unknown ? '$method 不应出现在契约中' : '$method 不在 contract/api.json 中',
  );

  final wantOk = expected['ok'] == true;
  final wantError = expected['error'] as String?;
  expect(
    wantOk != (wantError != null),
    isTrue,
    reason: 'expect 必须且只能指定 ok 或 error 之一',
  );

  if (wantOk) {
    expect(response['ok'], isTrue);
    expect(response['error'], isNull);
    _checkData(response['data'], item['data_required'], item['data_types']);
  } else {
    final spec = errorSpecs[wantError];
    expect(spec, isNotNull, reason: '错误码 $wantError 不在契约错误码集合中');
    final error = (response['error'] as Map).cast<String, dynamic>();
    expect(error['code'], wantError);
    expect(error['retryable'], spec!['retryable']);
    expect((error['message'] as String).trim(), isNotEmpty);
  }

  // 请求编码：Dart 产出的信封必须与用例中的 request 完全一致。
  // 非对象 params 属于服务端健壮性用例（客户端不会发），只由 Go 侧校验。
  final rawParams = request['params'];
  if (rawParams == null || rawParams is Map) {
    final encoded = encodeRequestEnvelope(
      id: request['id'] as int,
      method: method,
      params: (rawParams as Map?)?.cast<String, dynamic>(),
      timeoutMs: request['timeout_ms'] as int?,
    );
    expect(
      _deepEquals(encoded, request),
      isTrue,
      reason: '请求信封不一致: $encoded vs $request',
    );
  }

  // 响应解码：成功后拿到 data，失败映射为同码异常。
  final envelope = <String, dynamic>{
    'id': request['id'],
    ...response,
  };
  if (wantOk) {
    final data = decodeResponseEnvelope(envelope);
    expect(
      _deepEquals(data, response['data']),
      isTrue,
      reason: '成功响应 data 解码不一致: $data vs ${response['data']}',
    );
    return;
  }
  try {
    decodeResponseEnvelope(envelope);
    fail('错误响应必须抛出 NexmemException');
  } on NexmemException catch (e) {
    expect(e.code, wantError);
    expect(e.retryable, (response['error'] as Map)['retryable']);
  }
}

void _checkData(Object? data, Object? required, Object? types) {
  final map = (data as Map).cast<String, dynamic>();
  for (final name in ((required as List?) ?? const <Object>[]).cast<String>()) {
    expect(map.containsKey(name), isTrue, reason: '缺少字段 $name');
  }
  final typeMap = ((types as Map?) ?? const <Object, Object>{})
      .cast<String, String>();
  typeMap.forEach((name, want) {
    expect(map.containsKey(name), isTrue, reason: '缺少字段 $name');
    expect(
      _matchesType(map[name], want),
      isTrue,
      reason: '字段 $name 期望 $want，实际 ${map[name].runtimeType}',
    );
  });
}

bool _matchesType(Object? value, String want) => switch (want) {
  'bool' => value is bool,
  'int' => value is int,
  'number' => value is num,
  'string' => value is String,
  'array' => value is List,
  'object' => value is Map,
  _ => false,
};

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) {
      return false;
    }
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}
