// 用户档案模型与 {{user}} 显示层占位符替换测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/user.dart';

void main() {
  test('default user profile is empty', () {
    const user = UserProfile();
    expect(user.name, '');
    expect(user.avatarBase64, isNull);
  });

  test('copyWith updates fields while keeping others', () {
    const user = UserProfile(id: 1, name: 'a', avatarBase64: 'x');
    final next = user.copyWith(name: 'b');
    expect(next.id, 1);
    expect(next.name, 'b');
    expect(next.avatarBase64, 'x');
  });

  test('replaceUserPlaceholder only replaces when a username is set', () {
    // 未设置用户名 → 原样保留占位符。
    expect(replaceUserPlaceholder('你好 {{user}}', null), '你好 {{user}}');
    expect(replaceUserPlaceholder('你好 {{user}}', ''), '你好 {{user}}');
    // 设置用户名 → 全部替换(多处)。
    expect(replaceUserPlaceholder('你好 {{user}},再见 {{user}}', '小明'), '你好 小明,再见 小明');
    // 无占位符 → 原样返回。
    expect(replaceUserPlaceholder('你好 小明', '小明'), '你好 小明');
  });
}
