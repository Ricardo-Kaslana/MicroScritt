// 制卡草稿引用清理:删除角色业务引用后,再清草稿文件并释放其独立引用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/card_studio_draft_file.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/engine/card_studio/card_diff.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/card_studio_draft_assets.dart';
import 'package:microscritt/state/card_studio_draft_codec.dart';
import 'package:microscritt/state/card_studio_state.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('删除角色后清理草稿不会遗留图片引用', (tester) async {
    await tester.runAsync(() async {
      final db = await openTestDb();
      final dir = await Directory.systemTemp.createTemp('card-draft-assets-');
      final file = CardStudioDraftFile(dir.path);
      try {
        final hash = await putTestImageHash(db);
        final id = await CharacterRepository(
          db,
        ).insert(CharacterCard(name: '待删除', avatarHash: hash));
        await db.transaction((txn) => db.images.acquire(txn, hash));
        final card = (await CharacterRepository(db).get(id))!;
        await file.write(
          id,
          encodeCardStudioDraft(
            CardStudioDraftSnapshot(
              targetCharacterId: id,
              baseCard: card,
              baseEntries: const [],
              draftCard: card,
              draftEntries: const [],
              decisions: ReviewDecisions.acceptAll,
              entries: const [CardStudioEntry.user('优化')],
              sessionLog: const ['用户：优化'],
              heldAssetHashes: [hash],
            ),
          ),
        );
        expect(await testImageRefCount(db, hash), 2);

        await CharacterRepository(db).deleteWithCascade(id);
        expect(await testImageRefCount(db, hash), 1);
        expect(await clearCardStudioDraftAndRelease(db, file, id), isTrue);
        expect(await file.read(id), isNull);
        expect(await testImageRefCount(db, hash), 0);
        expect(
          await db.images.deleteIfUnreferenced(
            now: DateTime.now().add(const Duration(hours: 25)),
          ),
          1,
        );
        expect(await db.images.exists(hash), isFalse);
      } finally {
        await file.read(null);
        await db.db.close();
        if (await dir.exists()) await dir.delete(recursive: true);
        final images = Directory(db.imageRootPath);
        if (await images.exists()) await images.delete(recursive: true);
      }
    });
  });
}
