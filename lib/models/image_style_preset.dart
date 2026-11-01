/// 生图的「画面风格」预设:一组可直接填进生图配置的参数字典,也是这些参数的
/// **唯一编辑入口** —— 设置页选择风格时回填 artist/sampler/噪声调度/scale/cfg/
/// negative 并随配置落库,不再单独展开这些输入框。
///
/// 采样器与噪声调度均为 NovelAI 有效取值:采样器 k_euler /
/// k_euler_ancestral / k_dpmpp_2m / k_dpmpp_2m_sde 等;噪声调度 native /
/// karras / exponential。scale 取 5–7,cfg 取 0–2(可带小数,如 0.5)。
///
/// 预设全部为本项目原创(通用质量 tag 组合,不含任何画师名串);用户可在
/// 「管理自定义风格」页把任意参数组合(含自己收集的画师串)保存为自定义
/// 风格,自定义行落 `image_styles` 表。
class ImageStylePreset {
  /// 自定义风格在 image_styles 表里的行 id;内置预设恒为 null。
  final int? id;
  final String name;
  final String? artist; // 风格前缀(质量/画师 tag,可空)
  final String? sampler;
  final String? noiseSchedule; // 噪声调度,如 karras
  final int? scale; // 提示词引导值
  final double? cfg; // 缩放引导值(可小数,如 0.5)
  final String? negative; // 负面提示词(null/空 = 用服务端内置默认)

  const ImageStylePreset({
    this.id,
    required this.name,
    this.artist,
    this.sampler,
    this.noiseSchedule,
    this.scale,
    this.cfg,
    this.negative,
  });

  bool get isCustom => id != null;

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'artist': artist,
    'sampler': sampler,
    'noise_schedule': noiseSchedule,
    'scale': scale,
    'cfg': cfg,
    'negative': negative,
  };

  static ImageStylePreset fromMap(Map<String, Object?> m) => ImageStylePreset(
    id: m['id'] as int?,
    name: m['name'] as String,
    artist: m['artist'] as String?,
    sampler: m['sampler'] as String?,
    noiseSchedule: m['noise_schedule'] as String?,
    scale: m['scale'] as int?,
    // cfg 列是 INTEGER 亲和性:SQLite 把非整数 REAL 原样存为 REAL,读回
    // 可能是 int(历史行/整数值)或 double(小数),统一收敛成 double。
    cfg: (m['cfg'] as num?)?.toDouble(),
    negative: m['negative'] as String?,
  );
}

/// cfg 的展示文本:整数值省略 `.0`,小数原样保留(0.5),供表单回填与摘要复用。
String formatCfg(double? value) {
  if (value == null) return '';
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

/// 内置画面风格(本项目原创)。第一个是「默认(服务端)」,其余为可选项。
const List<ImageStylePreset> kImageStylePresets = [
  ImageStylePreset(name: '默认(服务端)'),
  ImageStylePreset(
    name: '动漫插画',
    artist: 'masterpiece, best quality, very aesthetic, anime illustration, clean line art, vibrant colors',
    sampler: 'k_dpmpp_2m_sde',
    noiseSchedule: 'karras',
    scale: 6,
    cfg: 0,
  ),
  ImageStylePreset(
    name: '柔和淡彩',
    artist: 'best quality, pastel colors, soft lighting, gentle atmosphere',
    sampler: 'k_euler_ancestral',
    noiseSchedule: 'exponential',
    scale: 5,
    cfg: 1,
  ),
  ImageStylePreset(
    name: '电影质感',
    artist: 'best quality, cinematic lighting, dramatic composition, depth of field, detailed background',
    sampler: 'k_dpmpp_2m',
    noiseSchedule: 'karras',
    scale: 7,
    cfg: 1,
  ),
  ImageStylePreset(
    name: '厚涂水彩',
    artist: 'best quality, watercolor, painterly, soft brush strokes',
    sampler: 'k_euler_ancestral',
    noiseSchedule: 'karras',
    scale: 6,
    cfg: 2,
  ),
  ImageStylePreset(
    name: '暗调夜景',
    artist: 'best quality, night scene, dramatic lighting, high contrast, detailed shadows',
    sampler: 'k_dpmpp_2m_sde',
    noiseSchedule: 'native',
    scale: 7,
    cfg: 1,
  ),
  ImageStylePreset(
    name: '写实风格',
    artist: 'best quality, photorealistic, highly detailed, natural lighting, realistic skin texture',
    sampler: 'k_dpmpp_2m_sde',
    noiseSchedule: 'karras',
    scale: 6,
    cfg: 1,
  ),
  ImageStylePreset(
    name: '清晰锐利',
    sampler: 'k_dpmpp_2m',
    noiseSchedule: 'karras',
    scale: 7,
    cfg: 0,
  ),
];
