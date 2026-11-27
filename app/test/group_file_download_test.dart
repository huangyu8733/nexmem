import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/app/core_session.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/features/chat/chat_store.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/transport/transport.dart';

class _DownloadTransport implements CoreTransport {
  @override
  Stream<CoreEvent> get events => const Stream<CoreEvent>.empty();

  @override
  int lastSeq = 0;

  final List<String> methods = <String>[];
  Map<String, dynamic>? lastParams;

  @override
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
  }) async {
    methods.add(method);
    lastParams = params;
    if (method == 'file.downloadGroup') {
      return <String, dynamic>{
        'path': params?['path'],
        'size': 4096,
        'sha256': 'digest',
      };
    }
    return <String, dynamic>{};
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('attachmentFromItem 解析群文件 blob_ref 与 key_b64', () {
    final ChatAttachment? attachment = attachmentFromItem(<dynamic>[
      <String, dynamic>{
        'name': 'group.zip',
        'size': 123,
        'mime': 'application/zip',
        'blob_ref': 'group_offline/x/files/y.bin',
        'key_b64': 'MTIzNA==',
      },
    ]);
    expect(attachment, isNotNull);
    expect(attachment!.blobRef, 'group_offline/x/files/y.bin');
    expect(attachment.keyB64, 'MTIzNA==');
    expect(attachment.canDownloadGroupFile, isTrue);
  });

  test('无下载元数据的附件不显示下载能力', () {
    final ChatAttachment attachment = ChatAttachment(name: 'a.txt', size: 1);
    expect(attachment.canDownloadGroupFile, isFalse);
  });

  test('downloadGroupFile 使用契约参数调用 file.downloadGroup', () async {
    final _DownloadTransport transport = _DownloadTransport();
    final CoreSession session = CoreSession(transport);
    final ChatAttachment attachment = ChatAttachment(
      name: 'group.zip',
      size: 4096,
      blobRef: 'group_offline/x/files/y.bin',
      keyB64: 'MTIzNA==',
    );

    final GroupFileDownload result = await session.downloadGroupFile(
      conversationId: 'group:YWJj',
      attachment: attachment,
      destPath: '/tmp/group.zip',
    );

    expect(transport.methods, contains('file.downloadGroup'));
    expect(transport.lastParams?['group_id'], 'YWJj');
    expect(transport.lastParams?['blob_ref'], 'group_offline/x/files/y.bin');
    expect(transport.lastParams?['key_b64'], 'MTIzNA==');
    expect(transport.lastParams?['path'], '/tmp/group.zip');
    expect(result.path, '/tmp/group.zip');
    expect(result.size, 4096);
    expect(result.sha256, 'digest');
  });

  testWidgets('群文件气泡展示下载按钮，点击回传保存路径', (
    WidgetTester tester,
  ) async {
    final ChatStore store = ChatStore(
      conversationId: 'group-1',
      isGroup: true,
      initial: <ChatMessage>[
        ChatMessage(
          id: 'gf1',
          conversationId: 'group-1',
          text: '',
          sentAt: DateTime(2026, 11, 27),
          isGroup: true,
          attachment: ChatAttachment(
            name: 'report.zip',
            size: 4096,
            mime: 'application/zip',
            blobRef: 'group_offline/x/files/y.bin',
            keyB64: 'MTIzNA==',
          ),
        ),
      ],
    );
    addTearDown(store.dispose);
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: Scaffold(
          body: ChatPage(
            conversation: const ConversationItem(
              id: 'group-1',
              title: '项目群',
              isGroup: true,
            ),
            store: store,
            onDownloadGroupFile: (ConversationItem c, ChatMessage m) async {
              saved = m.attachment?.name;
              return '/tmp/report.zip';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final downloadButton = find.byKey(const ValueKey<String>('group-file-download-gf1'));
    expect(downloadButton, findsOneWidget);
    await tester.tap(downloadButton);
    await tester.pumpAndSettle();
    expect(saved, 'report.zip');
    expect(find.text('群文件已保存到：/tmp/report.zip'), findsOneWidget);
  });

  testWidgets('单聊文件气泡不展示群文件下载按钮', (WidgetTester tester) async {
    final ChatStore store = ChatStore(
      conversationId: 'alice',
      initial: <ChatMessage>[
        ChatMessage(
          id: 'dm1',
          conversationId: 'alice',
          text: '',
          sentAt: DateTime(2026, 11, 27),
          attachment: ChatAttachment(
            name: 'a.txt',
            size: 10,
            path: '/tmp/a.txt',
            blobRef: 'whatever',
            keyB64: 'MTIzNA==',
          ),
        ),
      ],
    );
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: NexmemTheme.light(),
        home: Scaffold(
          body: ChatPage(
            conversation: const ConversationItem(id: 'alice', title: 'Alice'),
            store: store,
            onDownloadGroupFile: (_, _) async => '/tmp/a.txt',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('group-file-download-dm1')),
      findsNothing,
    );
  });
}
