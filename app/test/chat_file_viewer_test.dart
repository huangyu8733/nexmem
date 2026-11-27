// 聊天附件通用查看 / 保存能力验收。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nexmem_app/app/theme.dart';
import 'package:nexmem_app/features/chat/chat_message.dart';
import 'package:nexmem_app/features/chat/chat_page.dart';
import 'package:nexmem_app/features/chat/chat_store.dart';
import 'package:nexmem_app/features/chats/conversation.dart';
import 'package:nexmem_app/features/files/chat_file_actions.dart';
import 'package:nexmem_app/features/files/chat_file_viewer.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NexmemTheme.light(),
    home: Scaffold(body: child),
  );
}

void main() {
  test('常见文本与代码扩展名可内联预览', () {
    expect(isTextPreviewable('a.txt', ''), isTrue);
    expect(isTextPreviewable('notes.md', ''), isTrue);
    expect(isTextPreviewable('main.dart', ''), isTrue);
    expect(isTextPreviewable('data.json', 'application/json'), isTrue);
    expect(isTextPreviewable('photo.png', 'image/png'), isFalse);
    expect(isArchivePreviewable('bundle.zip'), isTrue);
    expect(isArchivePreviewable('doc.pdf'), isFalse);
  });

  testWidgets('文本文件展示 UTF-8 内容并可选中', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        ChatFileViewer(
          name: 'readme.md',
          mime: 'text/markdown',
          size: 5,
          readBytes: () async => Uint8List.fromList(utf8.encode('hello')),
          onSave: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-file-text-preview')), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('zip 附件列出内部条目', (WidgetTester tester) async {
    final Archive archive = Archive();
    archive.addFile(ArchiveFile('sub/inner.txt', 3, utf8.encode('abc')));
    final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    await tester.pumpWidget(
      _wrap(
        ChatFileViewer(
          name: 'bundle.zip',
          mime: 'application/zip',
          size: bytes.length,
          readBytes: () async => bytes,
          onSave: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('sub/inner.txt'), findsOneWidget);
  });

  testWidgets('不支持的格式展示保存按钮并提示保存位置', (WidgetTester tester) async {
    String? saved;
    await tester.pumpWidget(
      _wrap(
        ChatFileViewer(
          name: 'report.pdf',
          mime: 'application/pdf',
          size: 2048,
          readBytes: () async => Uint8List(0),
          onSave: () async {
            saved = '/tmp/report.pdf';
            return saved;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('chat-file-save')));
    await tester.pumpAndSettle();
    expect(saved, '/tmp/report.pdf');
    expect(find.textContaining('/tmp/report.pdf'), findsWidgets);
  });

  testWidgets('聊天文件气泡注入读取通道后点击打开通用查看页', (WidgetTester tester) async {
    const ConversationItem conversation = ConversationItem(id: 'alice', title: 'Alice');
    final ChatStore store = ChatStore(conversationId: conversation.id);
    addTearDown(store.dispose);
    final ChatMessage message = ChatMessage(
      id: 'txt-1',
      conversationId: 'alice',
      text: 'note.txt',
      sentAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      attachment: ChatAttachment(
        name: 'note.txt',
        size: 5,
        mime: 'text/plain',
        path: '/tmp/note.txt',
      ),
    );
    store.receive(message);
    await tester.pumpWidget(
      _wrap(
        ChatPage(
          conversation: conversation,
          store: store,
          onReadFileBytes: (ChatMessage _) async =>
              Uint8List.fromList(utf8.encode('hello')),
          onSaveFile: (ChatMessage _) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('chat-file-viewer-txt-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('chat-file-text-preview')), findsOneWidget);
  });
}
