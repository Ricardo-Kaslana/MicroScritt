// 消息模型测试:snake_case map 往返、图片提示词往返与视觉图判定。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/message.dart';

void main() {
  test('Message roundtrips through map with snake_case keys', () {
    final m = const Message(sessionId: 1, role: 'user', content: 'hi', seq: 0);
    final back = Message.fromMap(m.toMap());
    expect(back.sessionId, 1);
    expect(back.role, 'user');
    expect(back.content, 'hi');
    expect(back.isCompacted, false);
  });

  test('image hash roundtrips and drives local/visual image flags', () {
    const hash =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const m = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash: hash,
    );
    final map = m.toMap();
    expect(map['image_hash'], hash);
    expect(map.containsKey('image_base64'), isFalse);
    final back = Message.fromMap(map);
    expect(back.imageHash, hash);
    expect(back.hasImage, isTrue);
    expect(back.hasVisualImage, isTrue);
    expect(back.copyWith(content: 'caption').imageHash, hash);
    expect(back.copyWith(content: 'caption').hasImage, isTrue);

    const emptyHash = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageHash: '',
    );
    expect(emptyHash.hasImage, isFalse);
    expect(emptyHash.hasVisualImage, isFalse);
  });

  test('image prompt roundtrips and counts as a visual image', () {
    const m = Message(
      sessionId: 1,
      role: 'assistant',
      content: '',
      seq: 0,
      imageUrl: 'https://img.example/x.png',
      imagePrompt: '1girl, silver hair',
    );
    final map = m.toMap();
    expect(map['image_prompt'], '1girl, silver hair');
    final back = Message.fromMap(map);
    expect(back.imagePrompt, '1girl, silver hair');
    expect(back.hasVisualImage, isTrue);

    const textOnly = Message(
      sessionId: 1,
      role: 'assistant',
      content: 'hi',
      seq: 0,
    );
    expect(textOnly.hasVisualImage, isFalse);
    expect(textOnly.imagePrompt, isNull);
  });
}
