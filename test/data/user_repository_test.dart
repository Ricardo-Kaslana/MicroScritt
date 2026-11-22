// 用户档案仓储:单行语义、hash 图片引用事务与未保存时的空档案。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/user_repository.dart';
import 'package:microscritt/models/user.dart';
import '../support/image_fixtures.dart';
import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late UserRepository repo;

  setUp(() async {
    db = await openTestDb();
    repo = UserRepository(db);
  });

  tearDown(() => db.db.close());

  test('load returns empty profile when never saved', () async {
    final user = await repo.load();
    expect(user.name, '');
    expect(user.avatarHash, isNull);
  });

  testWidgets('save round-trips name/avatar and maintains references', (tester) async {
    await tester.runAsync(() async {
      final avatar = await putTestImageHash(db);
      await repo.save(UserProfile(name: '小明', avatarHash: avatar));

      final loaded = await repo.load();
      expect(loaded.id, 1);
      expect(loaded.name, '小明');
      expect(loaded.avatarHash, avatar);
      expect(await repo.avatarHashFor(1), avatar);
      expect(await testImageRefCount(db, avatar), 1);

      await repo.save(UserProfile(name: '小明', avatarHash: avatar));
      expect(await testImageRefCount(db, avatar), 1);
      await repo.updateName('小红');
      expect((await repo.load()).avatarHash, avatar);
      expect(await testImageRefCount(db, avatar), 1);

      await repo.save(const UserProfile(name: '小红', avatarHash: null));
      final reloaded = await repo.load();
      expect(reloaded.name, '小红');
      expect(reloaded.avatarHash, isNull);
      expect(await testImageRefCount(db, avatar), 0);
    });
  });

  testWidgets('replacing avatar acquires new reference before releasing old', (tester) async {
    await tester.runAsync(() async {
      final first = await putTestImageHash(db, width: 8, height: 8);
      final second = await putTestImageHash(db, width: 9, height: 8);
      await repo.save(UserProfile(name: '小明', avatarHash: first));
      await repo.save(UserProfile(name: '小明', avatarHash: second));
      expect(await testImageRefCount(db, first), 0);
      expect(await testImageRefCount(db, second), 1);
    });
  });
}
