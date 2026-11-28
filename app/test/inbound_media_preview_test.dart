// 接收端媒体预览回归：文件落盘后必须把附件路径补回气泡，否则图片无缩略图、
// 音视频点击打开的是空路径播放器。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/app.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/transport/transport.dart';

class _MediaTransport implements CoreTransport {
  _MediaTransport({this.name = 'photo.jpg', this.mime = 'image/jpeg'});

  final String name;
  final String mime;
  final StreamController<CoreEvent> _events =
      StreamController<CoreEvent>.broadcast(sync: true);
  final List<Map<String, dynamic>?> sinceParams = <Map<String, dynamic>?>[];
  bool _landed = false;

  @override
  Stream<CoreEvent> get events => _events.stream;

  @override
  int lastSeq = 0;

  Map<String, dynamic> _message({required bool landed}) {
    return <String, dynamic>{
      'msg_uuid': 'm-media',
      'conversation_id': 'dm:peer',
      'text': name,
      'direction': 'in',
      'sender_account': 'peer',
      'state': 'received',
      'sent_at': 1700000000000,
      'seq': 10,
      'attachments': <Object?>[
        <String, dynamic>{
          'name': name,
          'size': 100,
          'mime': mime,
          if (landed) 'path': '/tmp/inbox/$name',
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    switch (method) {
      case 'account.me':
        return <String, dynamic>{
          'account_id': 'me',
          'device_id': 'device',
          'display_name': '我',
        };
      case 'settings.get':
        return <String, dynamic>{
          'key': params?['key'],
          'value': '',
          'found': false,
        };
      case 'core.info':
        return <String, dynamic>{
          'api_version': '1',
          'core_version': 'test',
          'features': <String>[],
        };
      case 'conversation.list':
        return <String, dynamic>{
          'items': <Object?>[
            <String, dynamic>{
              'conversation_id': 'dm:peer',
              'title': '图片好友',
              'kind': 'dm',
              'peer': 'peer',
              'last_text': '',
              'last_msg_at': 1700000000000,
              'unread': 0,
            },
          ],
          'has_more': false,
        };
      case 'msg.list':
        return <String, dynamic>{
          'items': <Object?>[_message(landed: _landed)],
          'has_more': false,
        };
      case 'msg.listSince':
        sinceParams.add(params);
        _landed = true;
        return <String, dynamic>{
          'items': <Object?>[_message(landed: true)],
        };
      default:
        return <String, dynamic>{};
    }
  }

  void emit(CoreEvent event) {
    lastSeq = event.seq;
    _events.add(event);
  }

  @override
  Future<void> close() async => _events.close();
}

void main() {
  testWidgets('传输完成后回补附件路径，接收端图片气泡变为可预览', (WidgetTester tester) async {
    final _MediaTransport transport = _MediaTransport();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      NexmemApp(session: CoreSession(transport), enableStartupCheck: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('图片好友'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('chat-image-preview-m-media')),
      findsNothing,
    );

    transport.emit(
      CoreEvent(
        seq: 2,
        type: 'transfer.progress',
        ts: 1700000001000,
        data: <String, dynamic>{
          'msg_uuid': 'm-media',
          'done': 100,
          'total': 100,
          'direction': 'in',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(transport.sinceParams, hasLength(1));
    expect(transport.sinceParams.single?['after_seq'], 9);
    expect(
      find.byKey(const ValueKey<String>('chat-image-preview-m-media')),
      findsOneWidget,
    );
  });

  testWidgets('传输完成后回补附件路径，接收端音乐气泡可点击预览', (WidgetTester tester) async {
    final _MediaTransport transport = _MediaTransport(
      name: 'song.mp3',
      mime: 'audio/mpeg',
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      NexmemApp(session: CoreSession(transport), enableStartupCheck: false),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('图片好友'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('chat-media-preview-m-media')),
      findsNothing,
    );

    transport.emit(
      CoreEvent(
        seq: 2,
        type: 'transfer.progress',
        ts: 1700000001000,
        data: <String, dynamic>{
          'msg_uuid': 'm-media',
          'done': 100,
          'total': 100,
          'direction': 'in',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('chat-media-preview-m-media')),
      findsOneWidget,
    );
  });
}
