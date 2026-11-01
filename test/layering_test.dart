// 分层约束:data 与 backend 不互相 import,二者只通过 models 的中立类型对接。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('data/backend/models only meet through the models layer', () {
    _expectNoImports('lib/data', [
      '../backend/',
      'package:microscritt/backend/',
    ]);
    _expectNoImports('lib/backend', [
      '../data/',
      'package:microscritt/data/',
    ]);
    _expectNoImports('lib/models', [
      '../data/',
      '../backend/',
      'package:microscritt/data/',
      'package:microscritt/backend/',
    ]);
  });
}

void _expectNoImports(String dir, List<String> forbidden) {
  final files = Directory(
    dir,
  ).listSync(recursive: true).whereType<File>().where(
    (file) => file.path.endsWith('.dart'),
  );
  for (final file in files) {
    final source = file.readAsStringSync();
    for (final fragment in forbidden) {
      expect(
        source.contains(fragment),
        isFalse,
        reason: '${file.path} 不应 import $fragment',
      );
    }
  }
}
