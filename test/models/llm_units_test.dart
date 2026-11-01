// token 简写解析、显示格式化与上下文用量估算测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/llm_units.dart';

void main() {
  group('parseTokenShorthand', () {
    test('plain numbers', () {
      expect(parseTokenShorthand('128000'), 128000);
      expect(parseTokenShorthand('4096'), 4096);
      expect(parseTokenShorthand('0'), 0);
    });

    test('k suffix', () {
      expect(parseTokenShorthand('128k'), 128000);
      expect(parseTokenShorthand('128K'), 128000);
      expect(parseTokenShorthand('256k'), 256000);
      expect(parseTokenShorthand('16k'), 16000);
    });

    test('m suffix', () {
      expect(parseTokenShorthand('1m'), 1000000);
      expect(parseTokenShorthand('1M'), 1000000);
      expect(parseTokenShorthand('2m'), 2000000);
    });

    test('invalid and empty return null', () {
      expect(parseTokenShorthand(''), isNull);
      expect(parseTokenShorthand('abc'), isNull);
      expect(parseTokenShorthand('12x'), isNull);
      expect(parseTokenShorthand('-5'), isNull);
      expect(parseTokenShorthand('1.5m'), 1500000);
    });
  });

  group('formatTokenCount', () {
    test('formats K and M', () {
      expect(formatTokenCount(999), '999');
      expect(formatTokenCount(1234), '1.2K');
      expect(formatTokenCount(128000), '128K');
      expect(formatTokenCount(1000000), '1M');
      expect(formatTokenCount(1234567), '1.2M');
    });
  });

  test('estimateTokensFromChars is a rough non-negative estimate', () {
    expect(estimateTokensFromChars(320), 100);
    expect(estimateTokensFromChars(0), 0);
  });
}
