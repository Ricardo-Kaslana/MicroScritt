// 会话记忆模型的 map 往返测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/memory.dart';

void main() {
  test('toMap/fromMap round-trips', () {
    const m = Memory(id: 2, sessionId: 5, content: 'Met a dragon', updatedAt: 12345);
    final r = Memory.fromMap(m.toMap());
    expect(r.id, 2);
    expect(r.sessionId, 5);
    expect(r.content, 'Met a dragon');
    expect(r.updatedAt, 12345);
  });
}
