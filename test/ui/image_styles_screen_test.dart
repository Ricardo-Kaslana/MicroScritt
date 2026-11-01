// 生图风格管理页:自定义风格列表与搜索、预填新建、小数 cfg 往返、
// 内置预设重名拒绝、编辑与删除。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/image_style_repository.dart';
import 'package:microscritt/models/image_style_preset.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/ui/image_styles_screen.dart';
import '../support/test_database.dart';

void main() {
  late AppDatabase db;
  late ImageStyleRepository repo;

  Widget harness({ImageStylePreset? prefill}) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp(
      home: ImageStylesScreen(prefill: prefill ?? const ImageStylePreset(name: '')),
    ),
  );

  /// 真实 DB IO 必须在 runAsync 窗口内完成(fake-async 区会永不完成)。
  /// 两轮:第一轮让写库+invalidate 完成,第二轮让 provider 的刷新查询落定。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
    }
  }

  Finder field(String label) => find.byKey(ValueKey('field_$label'));

  String fieldText(WidgetTester tester, String label) =>
      tester.widget<TextField>(field(label)).controller?.text ?? '';

  setUp(() async {
    db = await openTestDb();
    repo = ImageStyleRepository(db);
  });

  tearDown(() async {
    await db.db.close();
  });

  testWidgets('empty state when no custom styles', (tester) async {
    await tester.pumpWidget(harness());
    await settle(tester);

    expect(find.text('暂无自定义风格'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);
  });

  testWidgets('lists saved custom styles with param summary', (tester) async {
    await tester.runAsync(() => repo.insert(
      const ImageStylePreset(
        name: '我的画风',
        artist: 'masterpiece',
        sampler: 'k_dpmpp_2m_sde',
        noiseSchedule: 'karras',
        scale: 6,
        cfg: 0,
      ),
    ));
    await tester.pumpWidget(harness());
    await settle(tester);

    expect(find.text('我的画风'), findsOneWidget);
    expect(find.textContaining('k_dpmpp_2m_sde'), findsOneWidget);
    expect(find.textContaining('含画师串'), findsOneWidget);
  });

  testWidgets('new style form prefills from current advanced params and saves', (tester) async {
    await tester.pumpWidget(
      harness(
        prefill: const ImageStylePreset(
          name: '',
          artist: 'soft lighting',
          sampler: 'k_euler_ancestral',
          noiseSchedule: 'exponential',
          scale: 5,
          cfg: 1,
          negative: 'lowres, bad anatomy',
        ),
      ),
    );
    await settle(tester);

    await tester.tap(find.text('新建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 预填:生图配置当前生效的风格参数原样进表单(名称留空待用户起)。
    expect(fieldText(tester, '画师串 (artist)'), 'soft lighting');
    expect(fieldText(tester, '采样器 (sampler)'), 'k_euler_ancestral');
    expect(fieldText(tester, '噪声调度 (noise_schedule)'), 'exponential');
    expect(fieldText(tester, '提示词引导值 (scale)'), '5');
    expect(fieldText(tester, '缩放引导值 (cfg)'), '1');
    expect(fieldText(tester, '负面提示词 (negative)'), 'lowres, bad anatomy');

    await tester.enterText(field('名称 *'), '我的画风');
    await tester.pump();
    await tester.tap(find.text('保存').last);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 保存后回到列表页并出现新风格;库里有完整往返。
    expect(find.text('我的画风'), findsOneWidget);
    late List<ImageStylePreset> saved;
    await tester.runAsync(() async {
      saved = await repo.all();
    });
    expect(saved.single.name, '我的画风');
    expect(saved.single.artist, 'soft lighting');
    expect(saved.single.sampler, 'k_euler_ancestral');
    expect(saved.single.noiseSchedule, 'exponential');
    expect(saved.single.scale, 5);
    expect(saved.single.cfg, 1);
    expect(saved.single.negative, 'lowres, bad anatomy');
  });

  testWidgets('cfg accepts decimal input and round-trips', (tester) async {
    await tester.runAsync(
      () => repo.insert(const ImageStylePreset(name: '小数风格', cfg: 0.35)),
    );
    await tester.pumpWidget(harness());
    await settle(tester);

    // 摘要与表单回填保留小数,不给整数值补 `.0`。
    expect(find.textContaining('cfg 0.35'), findsOneWidget);

    await tester.tap(find.text('小数风格'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(fieldText(tester, '缩放引导值 (cfg)'), '0.35');

    await tester.enterText(field('缩放引导值 (cfg)'), '0.8');
    await tester.pump();
    await tester.tap(find.text('保存').last);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    late List<ImageStylePreset> saved;
    await tester.runAsync(() async {
      saved = await repo.all();
    });
    expect(saved.single.cfg, 0.8);
  });

  testWidgets('name clashing with a builtin preset is rejected', (tester) async {
    await tester.pumpWidget(harness());
    await settle(tester);

    await tester.tap(find.text('新建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(field('名称 *'), '清晰锐利');
    await tester.pump();
    await tester.tap(find.text('保存').last);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 内置预设是代码常量,撞名会让下拉里的套用语义分叉:拒绝且不落库。
    expect(find.text('名称与内置预设「清晰锐利」冲突'), findsOneWidget);
    expect(find.text('新建风格'), findsOneWidget);
    late int count;
    await tester.runAsync(() async {
      count = (await repo.all()).length;
    });
    expect(count, 0);
  });

  testWidgets('editing a style loads its params and renames it', (tester) async {
    await tester.runAsync(() => repo.insert(const ImageStylePreset(name: '旧名', sampler: 'k_dpmpp_2m', scale: 7)));
    await tester.pumpWidget(harness());
    await settle(tester);

    await tester.tap(find.text('旧名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('编辑风格'), findsOneWidget);
    expect(fieldText(tester, '名称 *'), '旧名');
    expect(fieldText(tester, '采样器 (sampler)'), 'k_dpmpp_2m');
    expect(fieldText(tester, '提示词引导值 (scale)'), '7');

    await tester.enterText(field('名称 *'), '新名');
    await tester.pump();
    await tester.tap(find.text('保存').last);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('新名'), findsOneWidget);
    late List<ImageStylePreset> saved;
    await tester.runAsync(() async {
      saved = await repo.all();
    });
    expect(saved.single.name, '新名');
    expect(saved.single.sampler, 'k_dpmpp_2m');
  });

  testWidgets('search filters the style list by name and artist', (tester) async {
    await tester.runAsync(() async {
      await repo.insert(
        const ImageStylePreset(name: '柔光人像', artist: 'soft lighting'),
      );
      await repo.insert(
        const ImageStylePreset(name: '硬朗赛博', artist: 'neon noir'),
      );
    });
    await tester.pumpWidget(harness());
    await settle(tester);

    expect(find.text('柔光人像'), findsOneWidget);
    expect(find.text('硬朗赛博'), findsOneWidget);

    // 按名称过滤。
    await tester.enterText(find.byType(TextField), '赛博');
    await tester.pump();
    expect(find.text('柔光人像'), findsNothing);
    expect(find.text('硬朗赛博'), findsOneWidget);

    // 按画师串过滤(大小写不敏感)。
    await tester.enterText(find.byType(TextField), 'SOFT');
    await tester.pump();
    expect(find.text('柔光人像'), findsOneWidget);
    expect(find.text('硬朗赛博'), findsNothing);

    // 无命中显示空态;清空恢复全量。
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump();
    expect(find.text('没有匹配项'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('柔光人像'), findsOneWidget);
    expect(find.text('硬朗赛博'), findsOneWidget);
  });

  testWidgets('delete asks for confirmation and removes the style', (tester) async {
    await tester.runAsync(() => repo.insert(const ImageStylePreset(name: '待删风格')));
    await tester.pumpWidget(harness());
    await settle(tester);

    await tester.tap(find.byTooltip('删除'));
    await tester.pump();
    expect(find.text('删除风格?'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('待删风格'), findsNothing);
    expect(find.text('暂无自定义风格'), findsOneWidget);
    late int count;
    await tester.runAsync(() async {
      count = (await repo.all()).length;
    });
    expect(count, 0);
  });
}
