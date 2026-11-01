import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/bubble_style.dart';

void main() {
  test('default style reports isDefault', () {
    expect(const BubbleStyle().isDefault, isTrue);
    // 等同默认值的字段组合仍视为未定制。
    expect(const BubbleStyle(radius: 18, opacity: 1).isDefault, isTrue);
    expect(const BubbleStyle(radius: 12).isDefault, isFalse);
  });

  test('json roundtrip preserves all fields', () {
    const s = BubbleStyle(
      bubbleColor: 0xFF283593,
      textColor: 0xFFFFFFFF,
      radius: 22,
      opacity: 0.85,
    );
    final out = BubbleStyle.fromJson(s.toJson());
    expect(out.bubbleColor, 0xFF283593);
    expect(out.textColor, 0xFFFFFFFF);
    expect(out.radius, 22);
    expect(out.opacity, 0.85);
    expect(out.isDefault, isFalse);
  });

  test('null fields omitted from json; empty json parses to default', () {
    expect(const BubbleStyle(radius: 12).toJson(), {'radius': 12.0});
    final s = BubbleStyle.fromJson(const {});
    expect(s.isDefault, isTrue);
  });

  test('copyWith overrides selectively', () {
    const s = BubbleStyle(bubbleColor: 0xFF000000, radius: 10);
    final out = s.copyWith(radius: 20, opacity: 0.5);
    expect(out.bubbleColor, 0xFF000000);
    expect(out.radius, 20);
    expect(out.opacity, 0.5);
    expect(out.textColor, isNull);
  });

  test('fontFamily serializes and joins isDefault', () {
    const s = BubbleStyle(fontFamily: 'serif');
    expect(s.isDefault, isFalse);
    expect(s.toJson(), {'font_family': 'serif'});
    final out = BubbleStyle.fromJson({'font_family': 'serif'});
    expect(out.fontFamily, 'serif');
    // 空串视为未设置。
    expect(BubbleStyle.fromJson(const {}).fontFamily, isNull);
    expect(const BubbleStyle(fontFamily: '').isDefault, isTrue);
  });
}
