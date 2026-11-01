/// 生图配置模型(跨层中立)。Data 持久化它、UI 构造它、`providers.dart` 按
/// [ImageBackendKind] 路由到具体后端、后端消费它。
///
/// 抽到 `lib/models/` 是为了守住分层不变量(「持久化层与 LLM/生图层不互相
/// import」):Data 层不 import 任何后端实现,只认识这份中立模型。
library;

/// 内置默认负面提示词(quality/anatomy 防护 tag 集,NovelAI 风格,花括号为
/// 强度权重,单行,本项目原创)。任何生图请求(后台自动生图)在
/// 用户未显式配置负面提示词时兜底注入,不依赖服务端默认负面词。用户显式
/// 填写时以用户值为准,绝不与默认词叠加。
const String kDefaultNegativePrompt =
    '{{{bad anatomy}}},{{bad hands}},{{bad proportions}},{blurry},{cloned face},{cropped},{{{deformed}}},{{{disfigured}}},error,{extra arms},{extra digit},{extra legs},{fewer digits},{{{fused fingers}}},{gross proportions},{{jpeg artifacts}},{{{long neck}}},{low quality},{malformed limbs},{{missing arms}},{{missing fingers}},{{missing legs}},mutated hands,{{{mutation}}},{{poorly drawn face}},{{poorly drawn hands}},signature,text,{{too many fingers}},{{{ugly}}},username,watermark,{{{worst quality}}}';

/// 生图后端类型。2.3 起两种内置协议(对话式网关 / Nai2API)已改写为仓库自带
/// 插件,统一走 `imageBackendProvider` 的单一插件路径,故此处仅保留 [plugin]。
enum ImageBackendKind {
  /// 由 `PluginImageBackend` 按 `pluginId` 加载的 JS 生图插件(内置协议亦是插件)。
  plugin;

  /// 从库内存储字符串解析。本值在 App 启动时即被水合(`main.dart` →
  /// `imageConfigProvider`),任何脏值/历史协议名都宽容回落到 [plugin],绝不抛错
  /// 炸掉启动(旧的 `chat_completions`/`nai2api` 行经 v64 归档重建后不再出现)。
  static ImageBackendKind fromWire(String? s) => ImageBackendKind.plugin;
}

extension ImageBackendKindX on ImageBackendKind {
  String get wire => 'plugin';

  String get label => '生图插件';
}

/// 各服务的默认端点。2.0 起不捆绑任何第三方端点 —— 由用户在设置页填写。
String defaultImageBaseUrl(ImageBackendKind kind) => '';

/// 默认模型:插件自行决定(核心字段留空,由 manifest / listModels 填充)。
String defaultImageModel(ImageBackendKind kind) => '';

/// 离线模型候选:统一为空,候选改由插件 `listModels` 操作提供。
List<String> imageModelCandidates(ImageBackendKind kind) => const [];

/// 生图服务配置(`image_providers` 一行的内存表示)。
///
/// 字段是两种协议的**并集**:同名参数(size/scale/cfg/sampler/negative/steps/…)
/// 两侧语义一致,协议差异集中在 [ImageBackendKind] 与各后端自己的请求组装
/// 上。两个内置协议共用同一套标准参数,`steps` 留空时沿用各自默认(均 28);
/// `token`/`nocache` 是对话式网关侧未持久化的遗留覆盖项(见仓库自带插件)。
class ImageConfig {
  final ImageBackendKind kind;
  final String baseUrl;

  /// 唯一的凭据字段。对话式网关走 `Authorization: Bearer sk-…`,Nai2API 把它
  /// 同时作为 POST body 的 `token` 与轮询的 `x-user-token` 头。两类凭据互不
  /// 通用,故同一行只承载当前服务的那一把。
  final String apiKey;
  final String model;
  final String? artist;
  final String? size; // 竖图 | 横图 | 方图
  final int? scale; // 提示词引导值
  final double? cfg; // 缩放引导值(可小数,如 0.5)
  final String? negative;
  final String? sampler;
  final int? steps; // 生图步数:1-50(>28 更高扣费档),NULL → 协议默认 28
  final int? nocache; // 0 命中缓存,1 强制重画
  final String? noiseSchedule; // 噪声调度,如 karras
  final String? token; // 对话式网关可选账号密钥覆盖(未持久化)

  /// 每次生图数量(1-6):多张 = 同场景的 N 个**不同画面描述**(由后台引擎
  /// 展开产出 N 个描述,再逐描述调用 `generateImage`)。
  /// 两个后端都是每次请求画一张。
  final int count;

  /// kind=plugin 时使用的插件身份与独立设置;内置协议始终为空。
  final String? pluginId;
  final Map<String, dynamic> pluginSettings;

  const ImageConfig({
    this.kind = ImageBackendKind.plugin,
    this.baseUrl = '',
    required this.apiKey,
    required this.model,
    this.artist,
    this.size,
    this.scale,
    this.cfg,
    this.negative,
    this.sampler,
    this.steps,
    this.nocache,
    this.noiseSchedule,
    this.token,
    this.count = 1,
    this.pluginId,
    this.pluginSettings = const {},
  });
}

/// 一条生图 provider 配置(多行表 `image_providers` 的内存表示)。
///
/// 与 [ImageConfig] 的分工:[ImageConfig] 是**参数载体** —— 两个生图后端、
/// `imageBackendProvider`、编排器只认它,不认识本类型。本类型在参数
/// 之上加身份(id / 显示名 / 是否当前使用 / 排序位),供设置页管理多套配置。
/// `ImageConfigRepository.loadActiveConfig()` 把活跃行剥回 [ImageConfig],因此
/// 运行链路零改动 —— 与 `LlmProviderRepository.loadBackendConfig()` 把
/// `LlmProviderConfig` 映射回 `BackendConfig` 是同一手法。
///
/// 存在的理由:两种协议的凭据互不通用,旧单行表只有一个 `api_key` 列,来回
/// 切服务必须重贴密钥。
class ImageProviderRecord {
  /// 库内自增 id;0 表示尚未落库(新建)。
  final int id;
  final String displayName;
  final bool isActive;
  final int position;
  final ImageConfig config;

  const ImageProviderRecord({
    required this.id,
    required this.displayName,
    required this.config,
    this.isActive = false,
    this.position = 0,
  });

  /// 新建配置时的默认显示名(用户可改;选择具体插件后 UI 会用插件名覆盖)。
  static String defaultNameFor(ImageBackendKind kind) => '生图插件';
}
