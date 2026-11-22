// 图片与存储设置组件:真实统计、整理进度/完成反馈、按会话构成与原图回收。
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
import 'package:microscritt/ui/settings/image_storage_section.dart';
import 'package:path/path.dart' as p;
import '../support/image_fixtures.dart';
import '../support/test_database.dart';
import '../support/wait_until.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('显示四项统计并完成存储整理', (tester) async {
    late AppDatabase db;
    late String hash;
    await tester.runAsync(() async {
      db = await openTestDb();
      hash = await putTestImageHash(db);
      final preview = File(
        p.join(
          db.imageRootPath,
          'preview',
          hash.substring(0, 2),
          '$hash-v1-1600.jpg',
        ),
      );
      await preview.parent.create(recursive: true);
      await preview.writeAsBytes([1, 2, 3]);
      await db.db.update(
        'image_assets',
        {
          'created_at': DateTime.now()
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
        },
        where: 'hash = ?',
        whereArgs: [hash],
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: ImageStorageSection())),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('数据库').evaluate().isNotEmpty,
      reason: '图片存储统计未完成加载',
    );

    for (final label in ['数据库', '原图', '预览', '待回收']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('1 项资产'), findsOneWidget);
    final organize = find.byKey(const ValueKey('image_storage_organize'));
    expect(tester.widget<FilledButton>(organize).onPressed, isNotNull);

    await tester.tap(organize);
    await tester.pump();
    expect(find.text('正在整理…'), findsOneWidget);
    await waitUntilOrFail(
      tester,
      () => find.textContaining('存储整理完成').evaluate().isNotEmpty,
      reason: '存储整理未完成',
    );

    expect(find.textContaining('回收 1 项资产'), findsOneWidget);
    await tester.runAsync(() async {
      expect(await db.images.exists(hash), isFalse);
      expect(await db.db.query('image_assets'), isEmpty);
    });

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await db.db.close();
      final images = Directory(db.imageRootPath);
      if (await images.exists()) await images.delete(recursive: true);
    });
  });

  testWidgets('按会话查看图片构成', (tester) async {
    late AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
      final charId = await CharacterRepository(
        db,
      ).insert(const CharacterCard(name: 'A'));
      final sessionId = await SessionRepository(db).create(charId, '会话甲');
      final hash = await putTestImageHash(db);
      await MessageRepository(db).append(
        sessionId: sessionId,
        role: 'user',
        content: '',
        imageHash: hash,
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: ImageStorageSection())),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('数据库').evaluate().isNotEmpty,
      reason: '图片存储统计未完成加载',
    );

    await tester.tap(find.byKey(const ValueKey('image_storage_session_usage')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('session_image_usage_dialog')),
      findsOneWidget,
    );
    await waitUntilOrFail(
      tester,
      () => find.text('会话甲').evaluate().isNotEmpty,
      reason: '会话图片统计未完成加载',
    );
    expect(find.text('1 个资产 · 1 条图片消息'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('session_image_usage_dialog')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await db.db.close();
      final images = Directory(db.imageRootPath);
      if (await images.exists()) await images.delete(recursive: true);
    });
  });

  testWidgets('压缩新图片开关保存到设置', (tester) async {
    late AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: ImageStorageSection())),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('数据库').evaluate().isNotEmpty,
      reason: '图片存储统计未完成加载',
    );

    final toggle = find.byKey(const ValueKey('image_compress_switch'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    await waitUntilOrFail(
      tester,
      () => tester.widget<SwitchListTile>(toggle).value,
      reason: '压缩开关未切换',
    );
    await tester.runAsync(() async {
      final rows = await db.db.query('app_settings', where: 'id = 1');
      expect(rows.single['compress_images'], 1);
      expect(db.images.compressMaxEdge, 2048);
    });

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await db.db.close();
      final images = Directory(db.imageRootPath);
      if (await images.exists()) await images.delete(recursive: true);
    });
  });

  testWidgets('查看说明收纳整理与压缩细节', (tester) async {
    late AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: ImageStorageSection())),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('数据库').evaluate().isNotEmpty,
      reason: '图片存储统计未完成加载',
    );

    // 长文案默认不占列表;点「查看说明」后集中展示。
    expect(find.textContaining('整理会回收'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('image_storage_help')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final dialog = find.byKey(const ValueKey('image_storage_help_dialog'));
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.textContaining('回收到期零引用原图')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('长边超过 2048px')),
      findsOneWidget,
    );
    // 指标副标题收短后,淘汰与宽限期细节在弹窗内保持可查。
    expect(
      find.descendant(of: dialog, matching: find.textContaining('超过 256 MiB')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('24 小时宽限期')),
      findsOneWidget,
    );

    await tester.tap(find.text('知道了'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(dialog, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await db.db.close();
      final images = Directory(db.imageRootPath);
      if (await images.exists()) await images.delete(recursive: true);
    });
  });

  testWidgets('窄屏下指标分行展示,操作按钮整宽纵向堆叠', (tester) async {
    late AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: ImageStorageSection())),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('数据库').evaluate().isNotEmpty,
      reason: '图片存储统计未完成加载',
    );

    expect(tester.takeException(), isNull, reason: '窄屏不应出现布局溢出');
    final usage = tester.getRect(
      find.byKey(const ValueKey('image_storage_session_usage')),
    );
    final organize = tester.getRect(
      find.byKey(const ValueKey('image_storage_organize')),
    );
    expect(usage.width, greaterThan(300), reason: '移动端操作按钮应整宽');
    expect(organize.top, greaterThan(usage.bottom), reason: '操作按钮纵向堆叠');
    expect(find.byKey(const ValueKey('image_storage_help')), findsOneWidget);
    expect(find.byKey(const ValueKey('image_compress_switch')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await db.db.close();
      final images = Directory(db.imageRootPath);
      if (await images.exists()) await images.delete(recursive: true);
    });
  });

  testWidgets('桌面端统计与整理拆成两张卡,操作按钮同排右对齐', (tester) async {
    late AppDatabase db;
    await tester.runAsync(() async {
      db = await openTestDb();
    });
    tester.view.physicalSize = const Size(1120, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(body: ImageStorageSection(wide: true)),
        ),
      ),
    );
    await waitUntilOrFail(
      tester,
      () => find.text('数据库').evaluate().isNotEmpty,
      reason: '图片存储统计未完成加载',
    );

    expect(tester.takeException(), isNull, reason: '桌面布局不应溢出');
    expect(find.text('存储构成'), findsOneWidget);
    expect(find.text('整理与压缩'), findsOneWidget);
    expect(find.byKey(const ValueKey('image_compress_switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('image_storage_help')), findsOneWidget);
    final usage = tester.getRect(
      find.byKey(const ValueKey('image_storage_session_usage')),
    );
    final organize = tester.getRect(
      find.byKey(const ValueKey('image_storage_organize')),
    );
    expect(
      (usage.center.dy - organize.center.dy).abs(),
      lessThan(1),
      reason: '桌面端两个操作按钮应同排',
    );
    expect(organize.right, closeTo(1100, 1), reason: '操作按钮收在卡片右侧');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await db.db.close();
      final images = Directory(db.imageRootPath);
      if (await images.exists()) await images.delete(recursive: true);
    });
  });
}
