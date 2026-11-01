// 生图后端抽象测试:仅验证测试替身 FakeImageBackend 的回显。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/image_backend.dart';

void main() {
  test('FakeImageBackend returns the fixed base64', () async {
    final backend = FakeImageBackend('aGVsbG8=');
    final result = await backend.generateImage('a sword');
    expect(result.images.single.base64, 'aGVsbG8=');
  });
}
