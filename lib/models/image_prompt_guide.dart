/// 生图提示词生成规范(本项目原创)。
///
/// 生图后端期望 NovelAI 风格的英文 tag 串(与负面提示词 `kDefaultNegativePrompt`
/// 同一套 `{}`/`[]` 加权语法),而不是自由自然语言描述。本规范把「生成什么
/// 样的提示词」直接写进提示工程:
///
/// - **后台自动生图**(`BackgroundEngine`):`image` 指令后附
///   [kImageTagGuideEn],让 `imagePrompt`/`imagePrompts` 从「自然语言画面
///   描述」稳定输出为逗号分隔的英文 tag 串。
library;

/// 英文版 tag 规范:嵌入后台引擎(英文)指令。
const String kImageTagGuideEn = '''
Image descriptions are comma-separated English tags in NovelAI style, ordered by visual prominence:
1. character features: subject count (1girl/1boy), hair color, eye color, build, clothing;
2. pose and action: standing, sitting, running, reaching out, etc.;
3. environment interaction: how the character engages with props or other characters;
4. clothing details: outfit state and notable accessories;
5. camera and composition: shot size (full body/upper body), angle, gaze direction (looking at viewer);
6. location: bedroom, street, forest, indoors;
7. time and lighting: morning/night, warm or cold light, ambient mood.
Emphasize core features with {Tag} (each layer ≈1.1x, up to 6 layers); de-emphasize minor details with [Tag] (each layer ≈0.9x, up to 2 layers); always weight defining character features such as hair and eye color.
Describe only what is visible in the frame: people, objects, background, and physical actions in progress. Never include inner thoughts, memories, metaphors, dialogue, or abstract concepts; expressions must be visually concrete.
Keep characters consistent: restate each character's established appearance (hair color, eye color, build, clothing) in every tag string and never alter it between images.''';
