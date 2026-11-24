// P2P 文件共享：CoreSession 的 fs.* 语义方法与模型映射。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/transport/transport.dart';

typedef _Handler = Object? Function(Map<String, dynamic>? params);

class _FakeTransport implements CoreTransport {
  _FakeTransport(this.handlers);

  final Map<String, _Handler> handlers;
  final List<String> methods = <String>[];
  final List<Map<String, dynamic>?> params = <Map<String, dynamic>?>[];

  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int get lastSeq => 0;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    methods.add(method);
    this.params.add(params);
    final _Handler? handler = handlers[method];
    if (handler == null) {
      throw NexmemException('INVALID_ARG', '未知方法 $method');
    }
    final Object? result = handler(params);
    if (result is Map<String, dynamic>) {
      // 真实 transport 在解码响应信封后只返回 data，这里对齐该语义。
      return result;
    }
    throw NexmemException('INVALID_ARG', '$result');
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('发布共享：参数与模型映射正确', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'fs.publish': (Map<String, dynamic>? p) => <String, dynamic>{
        'share_id': 'abc123',
        'name': '资料包',
        'code': 'nexmem://fs/eyJ2IjoxfQ',
        'kind': 'published',
        'file_count': 12,
        'total_size': 1024,
        'local': true,
      },
    });
    final CoreSession session = CoreSession(transport);
    final FileShare share = await session.publishShare('/data/docs', name: '资料包');
    expect(transport.methods, <String>['fs.publish']);
    expect(transport.params.single?['path'], '/data/docs');
    expect(transport.params.single?['name'], '资料包');
    expect(share.shareId, 'abc123');
    expect(share.fileCount, 12);
    expect(share.isPublished, isTrue);
  });

  test('列出/导入/删除共享', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'fs.list': (_) => <String, dynamic>{
        'items': <dynamic>[
          <String, dynamic>{
            'share_id': 's1',
            'name': 'A',
            'kind': 'downloaded',
            'file_count': 3,
            'total_size': 2048,
            'local': true,
          },
        ],
      },
      'fs.import': (Map<String, dynamic>? p) => <String, dynamic>{
        'share_id': 's2',
        'name': 'B',
        'code': '${p?['code']}',
        'kind': 'imported',
        'file_count': 1,
        'total_size': 10,
      },
      'fs.remove': (_) => <String, dynamic>{},
    });
    final CoreSession session = CoreSession(transport);
    final List<FileShare> list = await session.listShares();
    expect(list, hasLength(1));
    expect(list.first.isDownloaded, isTrue);
    final FileShare imported = await session.importShare('nexmem://fs/xyz');
    expect(imported.shareId, 's2');
    expect(transport.params[1]?['code'], 'nexmem://fs/xyz');
    await session.removeShare('s1');
    expect(transport.methods.last, 'fs.remove');
    expect(transport.params.last?['share_id'], 's1');
  });

  test('查看详情映射文件清单', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'fs.get': (_) => <String, dynamic>{
        'share_id': 'd1',
        'name': '资料',
        'code': 'nexmem://fs/d1',
        'owner': 'aabbccdd',
        'files': <dynamic>[
          <String, dynamic>{
            'path': 'docs/a.txt',
            'size': 100,
            'sha256': 'abc',
            'mime': 'text/plain',
          },
        ],
      },
    });
    final CoreSession session = CoreSession(transport);
    final FileShareDetail detail = await session.getShare('d1');
    expect(detail.files, hasLength(1));
    expect(detail.files.first.path, 'docs/a.txt');
    expect(detail.owner, 'aabbccdd');
  });

  test('发送给好友映射消息 UUID', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'fs.send': (Map<String, dynamic>? p) => <String, dynamic>{
        'msg_uuid': 'msg-42',
      },
    });
    final CoreSession session = CoreSession(transport);
    final String msgUuid = await session.sendShare('s1', 'aabbccdd');
    expect(msgUuid, 'msg-42');
    expect(transport.params.single?['share_id'], 's1');
    expect(transport.params.single?['peer'], 'aabbccdd');
  });

  test('下载使用长超时并映射结果', () async {
    final _FakeTransport transport = _FakeTransport(<String, _Handler>{
      'fs.download': (Map<String, dynamic>? p) => <String, dynamic>{
        'share_id': p?['share_id'],
        'dest': p?['dest'],
        'kind': 'downloaded',
      },
    });
    final CoreSession session = CoreSession(transport);
    final FileShare result = await session.downloadShare(
      's1',
      '/data/downloaded',
      parallel: 8,
    );
    expect(result.local, isTrue);
    expect(result.localRoot, '/data/downloaded');
    expect(transport.params.single?['parallel'], 8);
  });
}
