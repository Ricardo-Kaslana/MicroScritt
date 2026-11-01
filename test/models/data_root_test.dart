import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/data_root.dart';

void main() {
  tearDown(() => DataRoot.overrideDir = null);

  test('overrideDir wins over platform detection', () {
    DataRoot.overrideDir = r'D:\Custom\Spot';
    expect(DataRoot.desktopDir(), r'D:\Custom\Spot');
  });

  test('desktop resolves to <home>/.microscritt', () {
    // 测试宿主是桌面环境(Windows CI/本机):主目录必然可解析。
    final dir = DataRoot.desktopDir();
    expect(dir, isNotNull);
    expect(dir!.endsWith('/.microscritt') || dir.endsWith(r'\.microscritt'), isTrue,
        reason: '固定目录名必须是 .microscritt');
  });
}
