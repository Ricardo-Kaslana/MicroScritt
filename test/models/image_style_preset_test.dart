import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/image_style_preset.dart';

void main() {
  test('presets have unique names and start with the server default', () {
    final names = kImageStylePresets.map((p) => p.name).toList();
    expect(names.toSet().length, names.length, reason: '预设名必须唯一(下拉 value 冲突)');
    expect(kImageStylePresets.first.name, '默认(服务端)');
  });

  test('content presets are present with non-empty artist strings', () {
    final byName = {for (final p in kImageStylePresets) p.name: p};
    for (final name in ['动漫插画', '柔和淡彩', '电影质感', '厚涂水彩', '暗调夜景', '写实风格']) {
      final p = byName[name];
      expect(p, isNotNull, reason: '风格预设 $name 应存在');
      expect(p!.artist, isNotEmpty, reason: '风格预设 $name 必须带风格前缀,否则与默认无异');
    }
  });

  test('presets use valid NovelAI sampler / noise-schedule values', () {
    const samplers = {'k_euler', 'k_euler_ancestral', 'k_dpmpp_2m', 'k_dpmpp_2m_sde'};
    const schedules = {'native', 'karras', 'exponential'};
    for (final p in kImageStylePresets) {
      if (p.sampler != null) expect(samplers, contains(p.sampler), reason: '${p.name} 采样器非法');
      if (p.noiseSchedule != null) {
        expect(schedules, contains(p.noiseSchedule), reason: '${p.name} 噪声调度非法');
      }
      if (p.scale != null) {
        expect(p.scale! >= 5 && p.scale! <= 7, isTrue, reason: '${p.name} scale 越界');
      }
    }
  });

  test('preset artists stay single-line (7-field message integrity) and carry no restricted content', () {
    for (final p in kImageStylePresets) {
      final artist = p.artist;
      if (artist == null) continue;
      expect(artist.contains('\n'), isFalse, reason: '${p.name} 风格串不能含真实换行');
      expect(artist.contains('\r'), isFalse, reason: '${p.name} 风格串不能含回车');
      // 采样器/噪声调度同理不得带换行(同样落进 7 字段块)。
      expect(p.sampler?.contains('\n'), isFalse, reason: '${p.name} 采样器不能含换行');
      expect(p.noiseSchedule?.contains('\n'), isFalse, reason: '${p.name} 噪声调度不能含换行');
      // 开源化红线:内置预设为通用质量 tag,不含画师名串与成人向内容。
      final lowered = artist.toLowerCase();
      expect(lowered.contains('artist:'), isFalse, reason: '${p.name} 不应内置画师名串');
      expect(lowered.contains('nsfw'), isFalse, reason: '${p.name} 不应含成人向 tag');
      expect(artist.contains('RP-Hub'), isFalse);
    }
  });
}
