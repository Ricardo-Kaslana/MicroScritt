// 会话归档导出/导入整链路(真实临时文件与真实库):归档结构、
// 桌面 .part 原子替换与同名角色复用。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/sessions_screen.dart';
import '../support/fake_file_picker.dart';
import '../support/test_database.dart';

/// 导出/导入走真实文件 IO,进度对话框的不定进度条不会收敛,
/// 不能用 pumpAndSettle;按条件轮询,期间留在 runAsync 里推进 IO。
Future<void> pumpUntil(WidgetTester tester, bool Function() condition, {int polls = 160}) async {
  await tester.runAsync(() async {
    for (var i = 0; i < polls; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
  await tester.pump();
}

void main() {
  const card = CharacterCard(name: 'Alice', firstMessage: '你好');

  testWidgets('exports the full archive to disk and imports it back', (tester) async {
    late AppDatabase db;
    late int charId;
    late Directory tmp;
    await tester.runAsync(() async {
      db = await openTestDb();
      tmp = await Directory.systemTemp.createTemp('session_ui_io');
      charId = await CharacterRepository(db).insert(card);
      final sessionId = await SessionRepository(db).create(charId, '酒馆相遇');
      final messages = MessageRepository(db);
      await messages.append(sessionId: sessionId, role: 'user', content: 'hi');
      await messages.append(sessionId: sessionId, role: 'assistant', content: '', imageBase64: 'aGVsbG8=');
    });

    final savePath = '${tmp.path}/session.json';
    // 替身只决定保存路径;文件由导出代码自己写入,随后可回读校验内容。
    FakeFilePicker.install(savePath: savePath);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: SessionsScreen(characterId: charId, character: card)),
    ));
    await pumpUntil(tester, () => find.text('酒馆相遇').evaluate().isNotEmpty);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('导出'), findsOneWidget);
    await tester.tap(find.text('导出'));
    await pumpUntil(tester, () => File(savePath).existsSync() && find.textContaining('已导出').evaluate().isNotEmpty);
    // 让菜单退出动画与进度对话框的 pop 动画走完,否则遮罩会挡住后续点击。
    await tester.pump(const Duration(milliseconds: 400));
    expect(File(savePath).existsSync(), isTrue);
    final decoded = jsonDecode(File(savePath).readAsStringSync()) as Map<String, dynamic>;
    expect(decoded['version'], 4);
    final msgs = decoded['messages'] as List;
    expect(msgs, hasLength(2));
    expect(msgs[1]['imageBase64'], 'aGVsbG8=');
    // 桌面流式导出:先写 .part,成功后替换,不残留临时文件。
    expect(File('$savePath.part').existsSync(), isFalse);

    // 导入同一份归档:同名角色复用,会话列表出现第二段同名会话。
    FakeFilePicker.install(pickedPath: savePath);
    await tester.tap(find.byTooltip('导入会话'));
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
}
