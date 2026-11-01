import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/user_repository.dart';
import 'package:microscritt/models/user.dart';
import '../support/test_database.dart';

void main() {
  test('load returns empty profile when never saved', () async {
    final db = await openTestDb();
    final repo = UserRepository(db);
    final user = await repo.load();
    expect(user.name, '');
    expect(user.avatarBase64, isNull);
    await db.db.close();
  });

  test('save round-trips name and avatar', () async {
    final db = await openTestDb();
    final repo = UserRepository(db);
    await repo.save(const UserProfile(name: '小明', avatarBase64: 'aGVsbG8='));

    final loaded = await repo.load();
    expect(loaded.id, 1);
    expect(loaded.name, '小明');
    expect(loaded.avatarBase64, 'aGVsbG8=');

    // Single-row semantics: a second save replaces, not appends.
    await repo.save(const UserProfile(name: '小红', avatarBase64: null));
    final reloaded = await repo.load();
    expect(reloaded.name, '小红');
    expect(reloaded.avatarBase64, isNull);
    await db.db.close();
  });

  test('load reads oversized avatar in chunks (Android CursorWindow limit)', () async {
    final db = await openTestDb();
    final repo = UserRepository(db);
    // 2MB + 4321:超过 Android CursorWindow 单行 2MB 上限的量级,且跨过 512K
    // 分块的多个边界。桌面 ffi 无此限制,这里验证 length+substr 分块拼接的
    // 完整性与边界;移动端整列 SELECT 超限行会抛 Row too big。
    final big = 'A' * (2 * 1024 * 1024 + 4321);
    await repo.save(UserProfile(name: '大头像', avatarBase64: big));

    expect(await repo.avatarBase64For(1), big);
    final loaded = await repo.load();
    expect(loaded.name, '大头像');
    expect(loaded.avatarBase64, big);
    await db.db.close();
  });
}
