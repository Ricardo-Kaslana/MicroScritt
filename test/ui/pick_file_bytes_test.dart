import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/common/pick_file_bytes.dart';
import 'package:path/path.dart' as p;

void main() {
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
  });
}
