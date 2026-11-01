// 生图 tag 规范文本测试:规格要点齐全且不含受限内容(开源红线)。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/image_prompt_guide.dart';

void main() {
  test('image tag guide carries the full spec (categories / weighting / framing / consistency)', () {
    const guide = kImageTagGuideEn;
    // 输出格式:英文逗号分隔的 NovelAI 风格 tag。
    expect(guide, contains('comma-separated English tags in NovelAI style'));
    // 七类组织:人物特征 / 姿势动作 / 环境交互 / 衣物 / 镜头构图 / 位置 / 时间光照。
    expect(guide, contains('1girl'));
    expect(guide, contains('looking at viewer'));
    expect(guide, contains('morning/night'));
    // 权重语法:{Tag} 增强 / [Tag] 减弱,人物标志特征必须加权。
    expect(guide, contains('{Tag}'));
    expect(guide, contains('[Tag]'));
    expect(guide, contains('hair color, eye color'));
    expect(guide, contains('≈1.1x'));
    expect(guide, contains('≈0.9x'));
    // 画面限制:只写客观可见画面,禁心理/对白/比喻。
    expect(guide, contains('visible in the frame'));
    expect(guide, contains('never alter it'));
  });

  test('guide carries no restricted content markers', () {
    // 开源化红线:规范里不得出现成人向 tag 指引或第三方项目标记。
    expect(kImageTagGuideEn.contains('RP-Hub'), isFalse);
    expect(kImageTagGuideEn.toLowerCase().contains('nsfw'), isFalse);
    expect(kImageTagGuideEn.contains('grinding'), isFalse);
    expect(kImageTagGuideEn.contains('fingering'), isFalse);
  });
}
