import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/image_codec.dart';
import '../engine/display_regex.dart';
import '../models/bubble_style.dart';
import '../models/character_card.dart';
import '../models/regex_script_seeds.dart';
import '../state/providers.dart';
import 'common/form_field.dart';
import 'common/pick_file_bytes.dart';
import 'common/section_header.dart';
import 'common/shrink_image.dart';
import 'widgets/message_bubble.dart';
import 'widgets/rich_message_text.dart';

/// 角色编辑/新建屏。characterId 为 null 时是新建模式。
class CharacterEditScreen extends ConsumerStatefulWidget {
  final int? characterId;
  const CharacterEditScreen({super.key, this.characterId});

  @override
  ConsumerState<CharacterEditScreen> createState() =>
      _CharacterEditScreenState();
}

class _CharacterEditScreenState extends ConsumerState<CharacterEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _personality;
  late final TextEditingController _scenario;
  late final TextEditingController _firstMessage;
  late final TextEditingController _alternateGreetings;
  late final TextEditingController _mesExample;
  late final TextEditingController _systemPrompt;
  late final TextEditingController _postHistory;
  late final TextEditingController _creatorNotes;
  late final TextEditingController _tags;
  String? _avatarBase64;
  String? _backgroundBase64;

  /// 角色级气泡样式(仅助手气泡;null = 应用默认)。
  BubbleStyle? _bubbleStyle;
  bool _loading = true;
  bool _saving = false;

  /// 编辑模式下加载的原始卡片:保存时把界面上没有编辑入口的元数据字段
  /// (creator/character_version/talkativeness/fav/depth_prompt)原样带过,
  /// 避免编辑一次就丢字段(导入的卡这些值只在 raw 里)。
  CharacterCard? _existing;

  bool get _isNew => widget.characterId == null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _description = TextEditingController();
    _personality = TextEditingController();
    _scenario = TextEditingController();
    _firstMessage = TextEditingController();
    _alternateGreetings = TextEditingController();
    _mesExample = TextEditingController();
    _systemPrompt = TextEditingController();
    _postHistory = TextEditingController();
    _creatorNotes = TextEditingController();
    _tags = TextEditingController();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final id = widget.characterId;
    if (id == null) {
      setState(() => _loading = false);
      return;
    }
    final card = await ref.read(characterRepositoryProvider).get(id);
    if (!mounted || card == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _existing = card;
    _name.text = card.name;
    _description.text = card.description;
    _personality.text = card.personality;
    _scenario.text = card.scenario;
    _firstMessage.text = card.firstMessage;
    _alternateGreetings.text = card.alternateGreetings.join('\n');
    _mesExample.text = card.mesExample;
    _systemPrompt.text = card.systemPrompt;
    _postHistory.text = card.postHistoryInstructions;
    _creatorNotes.text = card.creatorNotes;
    _tags.text = card.tags.join(', ');
    _avatarBase64 = card.avatarBase64;
    _backgroundBase64 = card.backgroundBase64;
    _bubbleStyle = card.bubbleStyle;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _personality.dispose();
    _scenario.dispose();
    _firstMessage.dispose();
    _alternateGreetings.dispose();
    _mesExample.dispose();
    _systemPrompt.dispose();
    _postHistory.dispose();
    _creatorNotes.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    // withData: false —— Android 大图会整读进原生 ByteArray 并可能 OOM 静默丢
    // 字节;改从选择结果 path 读(见 pickedFileBytes)。
    final result = await FilePicker.pickFiles(type: FileType.image);
    final bytes = await pickedFileBytes(result?.files.single);
    if (bytes == null) return;
    // 缩到安全尺寸再落库:用户可能选整张几 MB 的照片作头像,不缩会撑爆
    // Android CursorWindow(与导入同款防护,见 shrink_image.dart)。
    final shrunk = await shrinkImageBytes(bytes);
    if (shrunk != null) setState(() => _avatarBase64 = shrunk);
  }

  /// 选择/清除角色卡专属聊天背景图(独立于头像;未设置时开启背景回退头像)。
  Future<void> _pickBackground() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    final bytes = await pickedFileBytes(result?.files.single);
    if (bytes == null) return;
    final shrunk = await shrinkImageBytes(bytes);
    if (shrunk != null) setState(() => _backgroundBase64 = shrunk);
  }

  void _clearBackground() => setState(() => _backgroundBase64 = null);

  CharacterCard _buildCard() {
    // 编辑模式保留界面上没有编辑入口的元数据字段(导入的卡它们只存在于 raw);
    // 新建模式取默认值。
    final preserved = _existing;
    return CharacterCard(
      name: _name.text.trim(),
      description: _description.text,
      personality: _personality.text,
      scenario: _scenario.text,
      firstMessage: _firstMessage.text,
      mesExample: _mesExample.text,
      systemPrompt: _systemPrompt.text,
      postHistoryInstructions: _postHistory.text,
      creatorNotes: _creatorNotes.text,
      avatarBase64: _avatarBase64,
      backgroundBase64: _backgroundBase64,
      alternateGreetings: _alternateGreetings.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      tags: _tags.text
          .split(RegExp(r'[，,]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      creator: preserved?.creator ?? '',
      characterVersion: preserved?.characterVersion ?? '',
      talkativeness: preserved?.talkativeness ?? '',
      fav: preserved?.fav ?? false,
      depthPrompt: preserved?.depthPrompt ?? '',
      bubbleStyle: _bubbleStyle,
      // 保留原 raw:序列化时编辑过的字段会合并进 raw(见 _mergedRaw),
      // 信封结构/character_book/未知 extensions 不再因编辑而降级丢失。
      raw: preserved?.raw ?? const {},
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('名字不能为空')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(characterRepositoryProvider);
      final id = widget.characterId;
      if (id == null) {
        await repo.insert(_buildCard());
      } else {
        await repo.update(id, _buildCard());
        // 列表预览图按 id 缓存,换头像后必须失效 —— 仅刷新 charactersProvider
        // 时复用中的列表项不会重读头像,旧图会一直留到重启/重导入。
        ref.invalidate(characterAvatarProvider(id));
      }
      ref.invalidate(charactersProvider);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    const fallback = CircleAvatar(
      radius: 36,
      child: Icon(Icons.person, size: 36),
    );
    Widget avatar = fallback;
    final avatarBytes = safeBase64Decode(_avatarBase64);
    if (avatarBytes != null) {
      avatar = CircleAvatar(
        radius: 36,
        // 72 逻辑半径的头像按 384px 降采样解码,导入的大卡头像(可能整张
        // 几 MB 的 PNG)不再全分辨率解码占内存。
        backgroundImage: ResizeImage(
          MemoryImage(avatarBytes),
          width: 384,
          policy: ResizeImagePolicy.fit,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建角色' : '编辑角色'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Center(
            child: Column(
              children: [
                avatar,
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _pickAvatar,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('选择头像'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 聊天背景:独立于头像的横图,开启"聊天背景"后铺在聊天页;未设置时回退头像。
          _BackgroundField(
            backgroundBase64: _backgroundBase64,
            onPick: _pickBackground,
            onClear: _clearBackground,
          ),
          const SizedBox(height: 20),
          // ── 角色名片 ──────────────────────────────────────────
          const SectionHeader('名片', icon: Icons.badge_outlined),
          GroupCard(
            children: [
              FormTextField(controller: _name, label: '名字 *', hint: '角色的名字'),
              FormTextField(
                controller: _description,
                label: '描述',
                hint: '角色的外貌、背景、身份等基础设定',
                lines: 4,
              ),
            ],
          ),
          const SizedBox(height: 20),
          // ── 性格与场景 ────────────────────────────────────────
          const SectionHeader('性格与场景', icon: Icons.psychology_outlined),
          GroupCard(
            children: [
              FormTextField(
                controller: _personality,
                label: '性格',
                hint: '性格特征与说话方式',
                lines: 3,
              ),
              FormTextField(
                controller: _scenario,
                label: '场景',
                hint: '故事发生的背景与当前情境',
                lines: 3,
              ),
            ],
          ),
          const SizedBox(height: 20),
          // ── 对话 ──────────────────────────────────────────────
          const SectionHeader('对话', icon: Icons.forum_outlined),
          GroupCard(
            children: [
              FormTextField(
                controller: _firstMessage,
                label: '开场白',
                hint: '角色第一条消息(新建会话时自动写入)',
                lines: 5,
              ),
              FormTextField(
                controller: _alternateGreetings,
                label: '备用开场白',
                hint: '每行一条;点击左侧按钮切换',
                lines: 2,
              ),
              FormTextField(
                controller: _mesExample,
                label: '对话示例',
                hint: '示范角色语气的对话样例',
                lines: 5,
              ),
            ],
          ),
          const SizedBox(height: 20),
          // ── 高级 ──────────────────────────────────────────────
          const SectionHeader('高级', icon: Icons.tune_outlined),
          GroupCard(
            children: [
              FormTextField(
                controller: _systemPrompt,
                label: '系统提示词',
                hint: '追加到系统提示词的专属指令',
                lines: 4,
              ),
              FormTextField(
                controller: _postHistory,
                label: '历史后指令',
                hint: '追加在历史之后的指令',
                lines: 3,
              ),
              FormTextField(
                controller: _creatorNotes,
                label: '作者备注',
                hint: '仅展示,不进上下文',
                lines: 2,
              ),
              FormTextField(
                controller: _tags,
                label: '标签',
                hint: '逗号分隔,如 奇幻, 图书馆',
                lines: 1,
              ),
            ],
          ),
          const SizedBox(height: 20),
          // ── 气泡样式 ──────────────────────────────────────────
          const SectionHeader('气泡样式', icon: Icons.chat_bubble_outline),
          _BubbleStyleSection(
            style: _bubbleStyle,
            previewName: _name.text.trim().isEmpty ? '角色' : _name.text.trim(),
            onChanged: (s) => setState(() => _bubbleStyle = s),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// 聊天背景选择:横图预览 + 选择/清除按钮。未设置时显示说明,提示开启背景后回退头像。
class _BackgroundField extends StatelessWidget {
  final String? backgroundBase64;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _BackgroundField({
    required this.backgroundBase64,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = safeBase64Decode(backgroundBase64);
    final Widget preview;
    if (bytes != null) {
      preview = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          bytes,
          height: 90,
          width: double.infinity,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorBuilder: (_, __, ___) => _placeholder(context, scheme),
        ),
      );
    } else {
      preview = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _placeholder(context, scheme),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '聊天背景(可选)',
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        preview,
        const SizedBox(height: 4),
        Row(
          children: [
            TextButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.wallpaper_outlined),
              label: Text(bytes == null ? '选择背景图' : '更换背景图'),
            ),
            if (bytes != null)
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.close),
                label: const Text('清除'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '开启"聊天背景"后铺在聊天页;未设置时自动使用角色头像。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.outline),
        ),
      ],
    );
  }

  Widget _placeholder(BuildContext context, ColorScheme scheme) => Container(
    height: 90,
    width: double.infinity,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(Icons.wallpaper_outlined, color: scheme.outline),
  );
}

/// 预设气泡底色色板(含纸感浅色款,文字色自动取深)。
const List<({String label, int color})> _kBubblePalette = [
  (label: '墨黑', color: 0xFF23262B),
  (label: '暖棕', color: 0xFF4E342E),
  (label: '酒红', color: 0xFF7B1F2B),
  (label: '靛蓝', color: 0xFF283593),
  (label: '青碧', color: 0xFF00695C),
  (label: '森绿', color: 0xFF2E5D34),
  (label: '藕紫', color: 0xFF6A4C93),
  (label: '琥珀', color: 0xFFFFB300),
  (label: '蔷薇', color: 0xFFF48FB1),
  (label: '米白', color: 0xFFF8F5F0),
  (label: '浅棕', color: 0xFFEFE6DA),
];

/// 气泡样式定制节:预设色板 + 文字色三选(自动/深/浅)+ 圆角/透明度滑杆 +
/// 实时预览(与聊天页同款 [ChatBubbleFrame] + [RichMessageText] 管线)。
/// 全部字段回到默认值时上报 null(走应用统一样式)。
class _BubbleStyleSection extends StatelessWidget {
  final BubbleStyle? style;
  final ValueChanged<BubbleStyle?> onChanged;

  /// 预览正文里的角色名({{char}} 替换用)。
  final String previewName;

  /// 预览与聊天页同款显示层正则脚本:用默认种子编译,让预览里的
  /// `*动作*`/`**加粗**`/【…】按聊天同款规则渲染(星号被吃掉、胶囊生效),
  /// 而不是裸星号原样显示。compileDisplayScripts 按列表实例记忆化,
  /// const 种子列表只编译一次。
  static final List<CompiledRegexScript> _previewScripts =
      compileDisplayScripts(kDefaultRegexScriptSeeds);

  const _BubbleStyleSection({
    required this.style,
    required this.onChanged,
    required this.previewName,
  });

  void _update(BubbleStyle s) => onChanged(s.isDefault ? null : s);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = style ?? const BubbleStyle();
    return GroupCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('气泡底色', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _swatch(context, null, '默认', Icons.format_color_reset_outlined),
                  for (final e in _kBubblePalette) _swatch(context, e.color, e.label, null),
                ],
              ),
              const SizedBox(height: 12),
              Text('文字颜色', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('自动')),
                  ButtonSegment(value: 0xFF1B1B1F, label: Text('深色')),
                  ButtonSegment(value: 0xFFFFFFFF, label: Text('浅色')),
                ],
                selected: {
                  s.textColor ?? 0,
                },
                // copyWith 传 null 不清除旧值,这里整对象重建以支持"回到自动"。
                onSelectionChanged: (set) => _update(BubbleStyle(
                  bubbleColor: s.bubbleColor,
                  textColor: set.first == 0 ? null : set.first,
                  radius: s.radius,
                  opacity: s.opacity,
                  fontFamily: s.fontFamily,
                )),
              ),
              const SizedBox(height: 12),
              Text('正文字体', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: '', label: Text('默认')),
                  ButtonSegment(value: 'serif', label: Text('衬线')),
                ],
                selected: {
                  s.fontFamily ?? '',
                },
                onSelectionChanged: (set) => _update(BubbleStyle(
                  bubbleColor: s.bubbleColor,
                  textColor: s.textColor,
                  radius: s.radius,
                  opacity: s.opacity,
                  fontFamily: set.first.isEmpty ? null : set.first,
                )),
              ),
              const SizedBox(height: 4),
              _slider(
                context,
                label: '圆角',
                value: s.radius ?? 18,
                min: 4,
                max: 28,
                divisions: 24,
                display: '${(s.radius ?? 18).round()}',
                onChanged: (v) => _update(s.copyWith(radius: v)),
              ),
              _slider(
                context,
                label: '不透明度',
                value: s.opacity ?? 1.0,
                min: 0.3,
                max: 1.0,
                divisions: 14,
                display: (((s.opacity ?? 1.0) * 100).round()).toString(),
                onChanged: (v) => _update(s.copyWith(opacity: v)),
              ),
              const SizedBox(height: 8),
              Text('预览', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Center(
                child: ChatBubbleFrame(
                  isUser: false,
                  groupStart: true,
                  groupEnd: true,
                  style: style,
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: RichMessageText(
                    text: '【2024年·秋·晴 17:42】$previewName *微微一笑*,**压低声音**:“你来了。”',
                    style: chatBubbleTextStyle(
                      resolveAssistantTextColor(scheme, style),
                      fontFamily: s.fontFamily,
                    ),
                    charName: previewName,
                    scripts: _previewScripts,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '仅定制该角色(助手)的气泡外观,不进对话上下文;用户气泡保持应用统一样式。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
              if (style != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => onChanged(null),
                    icon: const Icon(Icons.restart_alt_outlined, size: 18),
                    label: const Text('恢复默认'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 单个色块;[color] 为 null 表示"默认"(清除定制底色)。
  Widget _swatch(BuildContext context, int? color, String tooltip, IconData? icon) {
    final selected = style?.bubbleColor == color;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => _update((style ?? const BubbleStyle()).copyWith(bubbleColor: color)),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color == null ? Theme.of(context).colorScheme.surfaceContainerHighest : Color(color),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: icon == null
              ? null
              : Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
        ),
      ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(width: 64, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
        Expanded(
          child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, label: display, onChanged: onChanged),
        ),
        SizedBox(width: 34, child: Text(display, textAlign: TextAlign.end, style: Theme.of(context).textTheme.bodySmall)),
      ],
    );
  }
}
