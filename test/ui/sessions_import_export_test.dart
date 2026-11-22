// 会话归档导出/导入整链路(真实临时文件与真实库):归档结构、
// 桌面 .part 原子替换、同名角色复用与「仅文本」导入。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/export/session_exporter.dart';
import 'package:microscritt/import/zip_store_reader.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/common/session_file_helper.dart';
import 'package:microscritt/ui/sessions_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../support/fake_file_picker.dart';
import '../support/image_fixture.dart';
import '../support/test_database.dart';

/// 导出/导入走真实文件 IO,进度对话框的不定进度条不会收敛,
/// 不能用 pumpAndSettle;按条件轮询,期间留在 runAsync 里推进 IO。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int polls = 160,
}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < polls; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  await tester.pump();
}

/// 右上角导入入口收在三点菜单里;行内操作菜单同为「更多操作」,
/// 需要按位置区分。
Finder appBarMenu() =>
    find.descendant(of: find.byType(AppBar), matching: find.byTooltip('更多操作'));

Finder rowMenu() => find.descendant(
  of: find.byType(ListTile),
  matching: find.byTooltip('更多操作'),
);

void main() {
  const card = CharacterCard(name: 'Alice', firstMessage: '你好');

  testWidgets('exports the full archive to disk and imports it back', (
    tester,
  ) async {
    late AppDatabase db;
    late int charId;
    late Directory tmp;
    late String imageHash;
    await tester.runAsync(() async {
      db = await openTestDb();
      tmp = await Directory.systemTemp.createTemp('session_ui_io');
      charId = await CharacterRepository(db).insert(card);
      final sessionId = await SessionRepository(db).create(charId, '酒馆相遇');
      final messages = MessageRepository(db);
      await messages.append(sessionId: sessionId, role: 'user', content: 'hi');
      imageHash = await putTestImage(db);
      await messages.append(
        sessionId: sessionId,
        role: 'assistant',
        content: '',
        imageHash: imageHash,
      );
    });

    final savePath = '${tmp.path}/session.msarc';
    // 替身只决定保存路径;文件由导出代码自己写入,随后可回读校验内容。
    FakeFilePicker.install(savePath: savePath);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: SessionsScreen(characterId: charId, character: card),
        ),
      ),
    );
    await pumpUntil(tester, () => find.text('酒馆相遇').evaluate().isNotEmpty);

    await tester.tap(rowMenu());
    await tester.pumpAndSettle();
    expect(find.text('导出'), findsOneWidget);
    // 桌面端不提供系统分享面板,菜单里没有「分享」。
    expect(find.text('分享'), findsNothing);
    await tester.tap(find.text('导出'));
    await pumpUntil(
      tester,
      () =>
          File(savePath).existsSync() &&
          find.textContaining('已导出').evaluate().isNotEmpty,
    );
    // 让菜单退出动画与进度对话框的 pop 动画走完,否则遮罩会挡住后续点击。
    await tester.pump(const Duration(milliseconds: 400));
    expect(File(savePath).existsSync(), isTrue);
    await tester.runAsync(() async {
      final reader = await ZipStoreReader.open(File(savePath));
      final metaEntry = reader.entries.singleWhere(
        (e) => e.name == 'meta.json',
      );
      final messagesEntry = reader.entries.singleWhere(
        (e) => e.name == 'messages.ndjson',
      );
      final decoded =
          jsonDecode(
                await reader
                    .openEntry(metaEntry)
                    .transform(utf8.decoder)
                    .join(),
              )
              as Map<String, dynamic>;
      expect(decoded['version'], 5);
      final messageText = await reader
          .openEntry(messagesEntry)
          .transform(utf8.decoder)
          .join();
      final msgs = messageText
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      await reader.close();
      expect(msgs, hasLength(2));
      expect(msgs[1]['imageHash'], imageHash);
    });
    // 桌面流式导出:先写 .part,成功后替换,不残留临时文件。
    expect(File('$savePath.part').existsSync(), isFalse);

    // 导入同一份归档:同名角色复用,会话列表出现第二段同名会话。
    FakeFilePicker.install(pickedPath: savePath);
    await tester.tap(appBarMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入会话'));
    // 归档导入先询问是否解包图片;本用例验证含图路径。
    await pumpUntil(tester, () => find.text('导入选项').evaluate().isNotEmpty);
    await tester.tap(find.text('包含图片'));
    await pumpUntil(tester, () => find.text('酒馆相遇').evaluate().length == 2);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('酒馆相遇'), findsNWidgets(2));

    final sessions = await tester.runAsync(() => db.db.query('sessions'));
    expect(sessions, hasLength(2));
    await tester.runAsync(() async {
      await db.db.close();
      tmp.deleteSync(recursive: true);
    });
  });

  testWidgets('text-only import drops message images and character assets', (
    tester,
  ) async {
    late AppDatabase db;
    late AppDatabase sourceDb;
    late int fillerId;
    late Directory tmp;
    late String archivePath;
    await tester.runAsync(() async {
      db = await openTestDb();
      tmp = await Directory.systemTemp.createTemp('session_ui_text_only');
      // 源库必须落在独立文件路径:内存库共用 ':memory:' 同一实例,关闭源库
      // 会连带关闭目标库。
      sourceDb = await AppDatabase.open(
        factory: databaseFactoryFfi,
        path: p.join(tmp.path, 'source.db'),
        imageRootPath: p.join(tmp.path, 'source-images'),
      );
      final avatar = await putTestImage(sourceDb);
      final background = await putTestImage(sourceDb, alternate: true);
      final sourceChar = await CharacterRepository(sourceDb).insert(
        CharacterCard(
          name: 'Alice',
          avatarHash: avatar,
          backgroundHash: background,
        ),
      );
      final sourceSession = await SessionRepository(
        sourceDb,
      ).create(sourceChar, '带图会话');
      final sourceMessages = MessageRepository(sourceDb);
      await sourceMessages.append(
        sessionId: sourceSession,
        role: 'user',
        content: 'hi',
      );
      await sourceMessages.append(
        sessionId: sourceSession,
        role: 'assistant',
        content: '',
        imageHash: avatar,
        imageUrl: 'https://example.com/a.png',
        imagePrompt: 'a prompt',
      );
      archivePath = '${tmp.path}/text-only.msarc';
      await SessionExporter(
        sourceDb,
      ).exportToFile(sessionId: sourceSession, file: File(archivePath));
      await sourceDb.db.close();

      fillerId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'Filler'));
    });

    FakeFilePicker.install(pickedPath: archivePath);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: SessionsScreen(
            characterId: fillerId,
            character: const CharacterCard(name: 'Filler'),
          ),
        ),
      ),
    );
    await pumpUntil(tester, () => find.text('还没有会话').evaluate().isNotEmpty);

    await tester.tap(appBarMenu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入会话'));
    await pumpUntil(tester, () => find.text('导入选项').evaluate().isNotEmpty);
    await tester.tap(find.text('仅文本'));
    await pumpUntil(
      tester,
      () => find.textContaining('已导入会话').evaluate().isNotEmpty,
    );

    await tester.runAsync(() async {
      final sessions = await db.db.query('sessions');
      expect(sessions, hasLength(1));
      final messages = await db.db.query(
        'messages',
        where: 'session_id = ?',
        whereArgs: [sessions.single['id']],
        orderBy: 'seq',
      );
      // 纯图片消息(空正文)整条略过,只剩文本消息,不留空气泡。
      expect(messages, hasLength(1));
      expect(messages.single['content'], 'hi');
      // 仅文本导入不得留下任何图片引用:哈希、远程 URL 与生成描述全空。
      for (final message in messages) {
        expect(message['image_hash'], isNull);
        expect(message['image_url'], isNull);
        expect(message['image_prompt'], isNull);
      }
      final characters = await db.db.query(
        'characters',
        where: 'name = ?',
        whereArgs: ['Alice'],
      );
      expect(characters.single['avatar_hash'], isNull);
      expect(characters.single['background_hash'], isNull);
      expect(await db.db.query('image_assets'), isEmpty);
      await db.db.close();
      tmp.deleteSync(recursive: true);
    });
  });

  testWidgets('mobile menu offers export and share separately', (tester) async {
    late AppDatabase db;
    late int charId;
    await tester.runAsync(() async {
      db = await openTestDb();
      charId = await CharacterRepository(db).insert(card);
      await SessionRepository(db).create(charId, '酒馆相遇');
    });
    debugMobileSessionExportOverride = true;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: SessionsScreen(characterId: charId, character: card),
          ),
        ),
      );
      await pumpUntil(tester, () => find.text('酒馆相遇').evaluate().isNotEmpty);

      await tester.tap(rowMenu());
      await tester.pumpAndSettle();
      expect(find.text('导出'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
    } finally {
      debugMobileSessionExportOverride = null;
      await tester.runAsync(() => db.db.close());
    }
  });
}
