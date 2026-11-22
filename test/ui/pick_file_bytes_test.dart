// 文件选择字节读取:按路径分块读取并回报进度、内联 bytes 直接使用,
// 以及缺失路径/空选择返回 null;会话内联字节兜底写到受管理临时目录。
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/pick_file_bytes.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('reads from path in chunks and reports progress', () async {
    final dir = await Directory.systemTemp.createTemp('pick_bytes_');
    addTearDown(() => dir.delete(recursive: true));
    final data = Uint8List.fromList(List.generate(300000, (i) => i & 0xFF));
    final file = File(p.join(dir.path, 'card.png'));
    await file.writeAsBytes(data);

    final events = <(int, int)>[];
    final bytes = await pickedFileBytes(
      PlatformFile(name: 'card.png', size: data.length, path: file.path),
      onProgress: (read, total) => events.add((read, total)),
    );

    expect(bytes, data);
    expect(events, isNotEmpty);
    expect(events.last, (data.length, data.length));
    expect(events.every((e) => e.$2 == data.length), isTrue);
  });

  test('inline bytes also report one completed progress event', () async {
    final data = Uint8List.fromList([1, 2, 3, 4]);
    final events = <(int, int)>[];
    final bytes = await pickedFileBytes(
      PlatformFile(name: 'card.bin', size: data.length, bytes: data),
      onProgress: (read, total) => events.add((read, total)),
    );
    expect(bytes, data);
    expect(events, [(data.length, data.length)]);
  });

  test('missing path or file selection yields null', () async {
    expect(await pickedFileBytes(null), isNull);
    expect(
      await pickedFileBytes(
        PlatformFile(name: 'ghost.png', size: 1),
      ),
      isNull,
    );
    expect(await pickedFilePath(null), isNull);
  });

  test('inline archive bytes land in managed temp dir and can be cleaned', () async {
    final temp = await Directory.systemTemp.createTemp('pick_path_');
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathProviderChannel, null);
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    messenger.setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return temp.path;
      return null;
    });

    final bytes = Uint8List.fromList([0x50, 0x4b, 1, 2, 3]);
    final picked = await pickedFilePath(
      PlatformFile(name: 'inline.msarc', size: bytes.length, bytes: bytes),
    );
    expect(picked, isNotNull);
    expect(picked!.temporary, isTrue);
    expect(p.isWithin(p.join(temp.path, 'imports'), picked.path), isTrue);
    expect(picked.path, endsWith('.msarc'));
    expect(await File(picked.path).readAsBytes(), bytes);

    await picked.deleteIfTemporary();
    expect(File(picked.path).existsSync(), isFalse);

    // 用户自己的文件路径不是临时档,清理动作不得删除它。
    final userFile = File(p.join(temp.path, 'user.msarc'))
      ..writeAsBytesSync(bytes);
    final userPicked = await pickedFilePath(
      PlatformFile(name: 'user.msarc', size: bytes.length, path: userFile.path),
    );
    expect(userPicked!.temporary, isFalse);
    await userPicked.deleteIfTemporary();
    expect(userFile.existsSync(), isTrue);
  });
}
