// 会话归档保存/分享通道:移动端保存与分享分支、临时暂存文件的清理与
// 取消语义(平台通道打桩,不弹真实系统对话框)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/session_file_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const fileDialogChannel = MethodChannel('flutter_file_dialog');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('session_file_helper');
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return temp.path;
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(fileDialogChannel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 桌面测试宿主没有移动端平台,用调试开关覆盖分支;
  /// 在测试体内恢复,避免影响同进程的其它用例。
  Future<void> runAsMobile(Future<void> Function() body) async {
    debugMobileSessionExportOverride = true;
    try {
      await body();
    } finally {
      debugMobileSessionExportOverride = null;
    }
  }

  /// 导出涉及真实文件 IO,testWidgets 的假时钟不会推进它;
  /// 用 runAsync 轮询直到条件满足(与 sessions_import_export_test 一致)。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    int polls = 200,
  }) async {
    await tester.runAsync(() async {
      for (var i = 0; i < polls; i++) {
        if (condition()) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  Future<void> pumpExportButton(
    WidgetTester tester, {
    required Future<void> Function(BuildContext context) export,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => export(context),
                child: const Text('导出'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'mobile save writes a streamed staging file and removes it afterwards',
    (tester) async {
      await runAsMobile(() async {
        String? stagedPath;
        String? stagedContent;
        messenger.setMockMethodCallHandler(fileDialogChannel, (call) async {
          if (call.method != 'saveFile') return null;
          final args = call.arguments as Map;
          stagedPath = args['sourceFilePath'] as String;
          stagedContent = File(stagedPath!).readAsStringSync();
          return '/storage/emulated/0/Download/王都之旅.json';
        });

        bool? result;
        await pumpExportButton(
          tester,
          export: (context) async {
            result = await saveSessionArchive(
              context,
              fileName: '王都之旅.json',
              build: (staging, {onProgress, isCancelled}) async {
                onProgress?.call(1, 2);
                staging.writeAsStringSync('{"version":4}');
                onProgress?.call(2, 2);
                return staging;
              },
            );
          },
        );

        await tester.tap(find.text('导出'));
        await pumpUntil(tester, () => result != null);
        await tester.pumpAndSettle();

        expect(result, isTrue);
        expect(stagedPath, endsWith('王都之旅.json'));
        expect(stagedContent, '{"version":4}');
        expect(File(stagedPath!).existsSync(), isFalse);
        expect(find.text('已保存到本地'), findsOneWidget);
      });
    },
  );

  testWidgets('cancelling the system save removes the staging file', (
    tester,
  ) async {
    await runAsMobile(() async {
      String? stagedPath;
      messenger.setMockMethodCallHandler(fileDialogChannel, (call) async {
        if (call.method != 'saveFile') return null;
        stagedPath = (call.arguments as Map)['sourceFilePath'] as String;
        return null;
      });

      bool? result;
      await pumpExportButton(
        tester,
        export: (context) async {
          result = await saveSessionArchive(
            context,
            fileName: 'session.json',
            build: (staging, {onProgress, isCancelled}) async {
              staging.writeAsStringSync('{}');
              return staging;
            },
          );
        },
      );

      await tester.tap(find.text('导出'));
      await pumpUntil(tester, () => result != null);
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(stagedPath, isNotNull);
      expect(File(stagedPath!).existsSync(), isFalse);
      expect(find.text('已取消保存'), findsOneWidget);
    });
  });

  testWidgets(
    'mobile share hands the staging file to the share channel and keeps it',
    (tester) async {
      await runAsMobile(() async {
        Map<Object?, Object?>? shareArgs;
        messenger.setMockMethodCallHandler(shareChannel, (call) async {
          if (call.method != 'share') return null;
          shareArgs = call.arguments as Map<Object?, Object?>;
          return 'ok';
        });

        bool? result;
        await pumpExportButton(
          tester,
          export: (context) async {
            result = await saveSessionArchive(
              context,
              fileName: '王都之旅.json',
              delivery: SessionArchiveDelivery.share,
              build: (staging, {onProgress, isCancelled}) async {
                staging.writeAsStringSync('{"version":4}');
                return staging;
              },
            );
          },
        );

        await tester.tap(find.text('导出'));
        await pumpUntil(tester, () => result != null);
        await tester.pumpAndSettle();

        expect(result, isTrue);
        final paths = shareArgs?['paths'] as List?;
        expect(paths, isNotNull);
        final sharedPath = paths!.single as String;
        expect(sharedPath, endsWith('王都之旅.json'));
        expect(File(sharedPath).readAsStringSync(), '{"version":4}');
        // 分享分支的暂存文件要留到接收方读完,不随返回删除。
        expect(File(sharedPath).existsSync(), isTrue);
        expect(find.text('已打开分享面板'), findsOneWidget);
      });
    },
  );
}
