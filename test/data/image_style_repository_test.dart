// 生图风格预设仓储:字段往返、空值语义与名称唯一约束。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_style_repository.dart';
import 'package:microscritt/models/image_style_preset.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late ImageStyleRepository repo;

  setUp(() async {
    db = await openTestDb();
    repo = ImageStyleRepository(db);
  });

  tearDown(() async {
    await db.db.close();
  });

  test('insert/all round-trip preserves every field', () async {
    await repo.insert(
      const ImageStylePreset(
        name: '我的风格',
        artist: 'masterpiece, best quality',
        sampler: 'k_dpmpp_2m_sde',
        noiseSchedule: 'karras',
        scale: 6,
        cfg: 0.5,
        negative: 'lowres, bad hands',
      ),
    );
    final s = (await repo.all()).single;
    expect(s.id, isNotNull);
    expect(s.isCustom, isTrue);
    expect(s.name, '我的风格');
    expect(s.artist, 'masterpiece, best quality');
    expect(s.sampler, 'k_dpmpp_2m_sde');
    expect(s.noiseSchedule, 'karras');
    expect(s.scale, 6);
    expect(s.cfg, 0.5);
    expect(s.negative, 'lowres, bad hands');
  });

  test('nullable fields round-trip as null; all() orders by id', () async {
    await repo.insert(const ImageStylePreset(name: '空参数风格'));
    await repo.insert(const ImageStylePreset(name: '另一个风格', sampler: 'k_euler'));
    final all = await repo.all();
    expect(all.map((s) => s.name), ['空参数风格', '另一个风格']);
    expect(all.first.artist, isNull);
    expect(all.first.sampler, isNull);
    expect(all.first.noiseSchedule, isNull);
    expect(all.first.scale, isNull);
    expect(all.first.cfg, isNull);
    expect(all.first.negative, isNull);
  });

  test('update rewrites fields; delete removes the row', () async {
    await repo.insert(const ImageStylePreset(name: '旧名', scale: 5));
    final s = (await repo.all()).single;
    await repo.update(
      ImageStylePreset(id: s.id, name: '新名', scale: 7, cfg: 0.75),
    );
    final updated = (await repo.all()).single;
    expect(updated.id, s.id);
    expect(updated.name, '新名');
    expect(updated.scale, 7);
    expect(updated.cfg, 0.75);

    await repo.delete(s.id!);
    expect(await repo.all(), isEmpty);
  });

  test('duplicate name violates UNIQUE constraint', () async {
    await repo.insert(const ImageStylePreset(name: '重名风格'));
    expect(
      () => repo.insert(const ImageStylePreset(name: '重名风格')),
      throwsA(anything),
    );
  });
}
