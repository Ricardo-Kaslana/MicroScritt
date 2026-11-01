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

    const textOnly = Message(sessionId: 1, role: 'assistant', content: 'hi', seq: 0);
    expect(textOnly.hasVisualImage, isFalse);
    expect(textOnly.imagePrompt, isNull);
  });
}
