/// 聊天消息气泡:正文、可折叠指令块与图片三态渲染。
///
/// 图片按 `messages.image_base64` → 按 id 惰性读库 → 远程 URL 的顺序择一,
/// 任何网络/解码失败都落静态失败占位,不留无限转圈;所有显示层改写(宏
/// 替换、显示层正则、折叠)都不回写落库正文。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../backend/disk_image_cache.dart';
import '../../backend/image_downloader.dart';
import '../../data/image_codec.dart';
import '../../models/message.dart';
import '../../engine/display_regex.dart';
import '../../engine/glossary.dart';
import '../../models/bubble_style.dart';
import '../common/image_header.dart';
import '../skill_highlight.dart';
import 'image_viewer.dart';
import 'rich_message_text.dart';

/// 助手气泡的最大宽度:桌面大幅加宽到 760;移动端占满整行(扣掉左右边距)。
/// 气泡本身按内容宽度自适应(短消息是小气泡),只是不会超过这个上限。
/// 用户气泡的对应上限见 [userBubbleMaxWidth]。
double assistantBubbleMaxWidth(BuildContext context) {
  final available = MediaQuery.sizeOf(context).width;
  final wanted = available >= 600 ? 760.0 : available - 24;
  return wanted.clamp(0.0, available - 24);
}

/// 用户气泡的最大宽度:桌面限到一个正常的聊天气泡宽度(不再被拉到 760),
/// 移动端最多占满整行(内容自适应,短消息是小气泡)。
double userBubbleMaxWidth(BuildContext context) {
  final available = MediaQuery.sizeOf(context).width;
  return available >= 600 ? 520.0 : available - 24;
}

/// 气泡内图片的解码尺寸上限(物理像素)。
typedef _DecodeSize = ({int width, int height});

/// 气泡内图片的解码尺寸上限:宽度按「显示宽度 × 屏幕像素比」封顶 1520;
/// 高度按图片框上限 [_maxImageHeight] × 像素比封顶。竖图/4K 源不再按宽度
/// 解出远超显示框的帧(9:16 图按 1520 宽会解到 1520×2702),解码内存与
/// ImageCache 占用显著下降。宽高同时交给 ResizeImage 的 fit 策略,比例不变。
/// 只影响气泡内的缩略解码,全屏查看有独立上限。
_DecodeSize _bubbleDecodeSize(BuildContext context, {required bool isUser}) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final logical = isUser
      ? userBubbleMaxWidth(context)
      : assistantBubbleMaxWidth(context);
  final width = (logical * dpr).clamp(320.0, 1520.0).round();
  final height = (_maxImageHeight * dpr).clamp(1.0, 4096.0).round();
  return (width: width, height: height);
}

/// 气泡的统一基调:iOS 语言 —— 用户 = 实心主色(白字),助手 = 表面白卡;
/// 都去掉浓重 container 色调,层级更干净。文字颜色各自随气泡底取高对比。
/// 圆角语言:顶角恒为 [kChatBubbleRadius] 大圆角;底部"尾巴"角仅组内末条
/// 出现(朝头像/同侧的小圆角),组内其余消息四角全圆 —— 连续同角色消息
/// 看起来像一个整体气泡串,不再每条都带小尾巴。
const double kChatBubbleRadius = 18;
const double kChatTailRadius = 6;

/// 消息气泡的共享外壳:统一的外边距 / 内容内边距 / 圆角 / 底纹 / 选中描边。
/// [MessageBubble] 与流式草稿气泡共用,保证两种气泡长相完全一致。
class ChatBubbleFrame extends StatelessWidget {
  /// 用户侧气泡(实心主色 + 白字);false = 助手侧(表面白卡)。
  final bool isUser;

  /// 是否组内首条:控制顶部间距(组间拉开、组内收紧)。
  final bool groupStart;

  /// 是否组内末条:控制底部"尾巴"圆角(末条才有尾巴)。
  final bool groupEnd;

  /// 选中态:气泡外圈描边高亮,提示"此消息已选中、下方有操作按钮"。
  final bool selected;

  /// 搜索定位态:目标气泡叠强调色描边与外发光(短暂,由聊天页计时收起)。
  final bool highlighted;

  /// 角色级气泡样式(仅定制助手气泡;null/默认 = 应用统一白卡)。
  /// 底色/透明度/圆角在此应用,文字颜色由 [MessageBubble] 解析后传入正文样式。
  final BubbleStyle? style;

  /// 最大宽度约束(作用域是可见气泡,边距之外);null 时不设上限。
  final BoxConstraints? constraints;

  final Widget child;

  const ChatBubbleFrame({
    super.key,
    required this.isUser,
    required this.groupStart,
    required this.groupEnd,
    this.selected = false,
    this.highlighted = false,
    this.style,
    this.constraints,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 角色级样式只定制助手气泡;用户气泡恒为应用统一主色。
    final effStyle = isUser ? null : style;
    final bubbleColor = effStyle?.bubbleColor != null
        ? Color(effStyle!.bubbleColor!).withValues(alpha: effStyle.opacity ?? 1)
        : (isUser ? scheme.primary : scheme.surface);
    // 圆角:默认 [kChatBubbleRadius];角色定制半径只作用于"大角",
    // 尾巴小角恒为 [kChatTailRadius](分组语义不随样式变)。
    final radius = effStyle?.radius ?? kChatBubbleRadius;
    return Container(
      constraints: constraints,
      // 组内消息间距收紧(顶部 2),组间拉大(顶部 8);底部统一小间距。
      margin: EdgeInsets.fromLTRB(12, groupStart ? 8 : 2, 12, 2),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(radius),
          topRight: Radius.circular(radius),
          // 尾巴只在组内末条出现:用户尾巴在右下、助手尾巴在左下;
          // 组内中间消息四角全圆,视觉上合并成一个气泡串。
          bottomLeft: Radius.circular(
            isUser ? radius : (groupEnd ? kChatTailRadius : radius),
          ),
          bottomRight: Radius.circular(
            isUser ? (groupEnd ? kChatTailRadius : radius) : radius,
          ),
        ),
        // 选中描边:用户气泡上叠一圈更亮的同色系描边,助手气泡用主色描边;
        // 搜索定位高亮优先于选中态(强调色描边 + 外发光);都未命中时助手
        // 气泡加一条发丝细边,让白卡在白底背景上仍有分界。
        border: highlighted
            ? Border.all(color: scheme.tertiary, width: 2)
            : selected
            ? Border.all(
                color: isUser
                    ? Color.alphaBlend(
                        scheme.onPrimary.withValues(alpha: 0.65),
                        scheme.primary,
                      )
                    : scheme.primary,
                width: 1.6,
              )
            : (!isUser
                  ? Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.45),
                      width: 1,
                    )
                  : null),
        boxShadow: highlighted
            ? [
                BoxShadow(
                  color: scheme.tertiary.withValues(alpha: 0.35),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}

/// 气泡正文文字样式:15px + 1.4 行高,长对话更耐读;用户白字加一点字重提对比。
/// [fontFamily] 随角色级气泡样式传入(如 serif 衬线/宋体风)。
TextStyle chatBubbleTextStyle(
  Color color, {
  bool bold = false,
  String? fontFamily,
}) => TextStyle(
  color: color,
  fontSize: 15,
  height: 1.4,
  fontWeight: bold ? FontWeight.w500 : FontWeight.w400,
  fontFamily: fontFamily,
);

/// 助手气泡文字色解析:角色定制底色时 —— 显式文字色优先,否则按(叠透明度
/// 后的)底色亮度自动取深/浅;只定制文字色时直接用;未定制走主题 onSurface。
/// [MessageBubble] 与角色编辑页的样式预览共用。
Color resolveAssistantTextColor(ColorScheme scheme, BubbleStyle? style) {
  if (style?.bubbleColor != null) {
    final bg = Color(style!.bubbleColor!).withValues(alpha: style.opacity ?? 1);
    return style.textColor != null
        ? Color(style.textColor!)
        : (bg.computeLuminance() > 0.5
              ? const Color(0xFF1B1B1F)
              : Colors.white);
  }
  if (style?.textColor != null) return Color(style!.textColor!);
  return scheme.onSurface;
}

/// 单条消息气泡:正文、图片、分组外观与选中/搜索定位态。
///
/// 纯显示组件:正文经 [RichMessageText] 管线渲染,用户侧额外支持可折叠的
/// `<tag>` 指令块;不修改 [message],复制/编辑/删除/重生成等动作都由上层
/// 回调触发。图片在 base64、惰性读库与远程 URL 三种来源间择一,详见
/// [_CachedMemoryImage] / [_LazyMemoryImage] / [_CachedNetworkImage]。
class MessageBubble extends StatelessWidget {
  /// 要渲染的消息行(只读,渲染过程不改写)。
  final Message message;

  /// 长按回调(复制/编辑/删除/重新生成菜单);null 时不响应长按。
  final VoidCallback? onLongPress;

  /// 单击回调(选中消息以显示下方操作按钮);null 时不响应单击。
  final VoidCallback? onTap;

  /// 当前用户名,用于**显示时**把正文里的 `{{user}}` 替换为实际用户名
  /// (仅影响显示,不改写落库/上下文)。null 或空时不替换。
  final String? displayUserName;

  /// 角色名,用于**显示时**把正文里的 `{{char}}` 替换为角色名(仅影响显示)。
  final String? displayCharName;

  /// 已启用技能名集合:用户气泡内 `@技能名` 记号以记号色高亮(与输入框同构,
  /// 共用 skill_highlight 的正则与选色)。仅作用于**用户气泡**的普通正文段;
  /// null/空集合 = 不高亮。不影响助手气泡与存储/上下文。
  final Set<String>? skillNames;

  /// 预先编译好的技能记号正则(由聊天页按技能集合编译一次后下传)。
  /// 流式期间气泡会被高频重建,传这里可避免每个用户气泡每帧重新拼/编译
  /// RegExp;null 时退回按 [skillNames] 现场编译(测试/独立使用)。
  final RegExp? skillTokenPattern;

  /// 显示层正则脚本(气泡正文渲染管线用;null = 无脚本)。
  final List<CompiledRegexScript>? regexScripts;

  /// 名词词典(世界书词条高亮 + 点击;null = 不高亮)。
  final CompiledGlossary? glossary;

  /// 词条点击回调(弹释义卡);null = 仅高亮样式。
  final void Function(GlossaryTerm term)? onTermTap;

  /// 内置对话高亮(引号台词斜体+强调色)总开关;false = 引号内文字按普通正文渲染。
  final bool highlightDialogue;

  /// 角色级气泡样式(仅助手气泡生效;null = 应用默认)。
  final BubbleStyle? style;

  /// 按消息 id 惰性读取 image_base64(轻量查询后图片不随消息列表加载)。
  /// null 时 hasImage 消息无图可显(回退 URL)。
  final Future<String?> Function(int messageId)? imageLoader;

  /// 删除本条消息中的图片(全屏查看器"删除图片"按钮触发):有正文的清空
  /// 图片字段,纯图无正文的整条移除(由控制器决定);null 或消息尚无 id
  /// (草稿/导入前)时不提供删除入口。
  final Future<void> Function(int messageId)? onImageDelete;

  /// 本条图片正在重新生成:图片区叠半透明遮罩与转圈。
  final bool regenerating;

  /// 本条图片的本地修订号:原地替换后递增,本地图片缓存按它区分新旧字节。
  final int imageRevision;

  /// 是否组内首条(上方无同角色消息):控制顶部间距与分组感。
  final bool groupStart;

  /// 是否组内末条(下方无同角色消息):末条才显示底部小尾巴圆角。
  final bool groupEnd;

  /// 选中态:气泡外圈描边高亮。
  final bool selected;

  /// 搜索定位态:目标气泡强调描边 + 外发光。
  final bool highlighted;

  const MessageBubble({
    super.key,
    required this.message,
    this.onLongPress,
    this.onTap,
    this.displayUserName,
    this.displayCharName,
    this.skillNames,
    this.skillTokenPattern,
    this.regexScripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
    this.style,
    this.imageLoader,
    this.onImageDelete,
    this.regenerating = false,
    this.imageRevision = 0,
    this.groupStart = true,
    this.groupEnd = true,
    this.selected = false,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final imageUrl = message.imageUrl;
    final scheme = Theme.of(context).colorScheme;
    // 助手气泡文字色随角色样式解析(见 [resolveAssistantTextColor]);
    // 用户气泡恒为主题 onPrimary。
    final onBubble = isUser
        ? scheme.onPrimary
        : resolveAssistantTextColor(scheme, style);
    // 全屏查看器的删除入口:回调与消息 id 齐备才有(草稿/导入前的无 id 行不可删)。
    final messageId = message.id;
    final deleteImage = onImageDelete == null || messageId == null
        ? null
        : () => onImageDelete!(messageId);
    // 缩略解码尺寸上限(见 [_bubbleDecodeSize]);全屏查看器仍用原始字节。
    final decodeSize = _bubbleDecodeSize(context, isUser: isUser);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        // 桌面用鼠标时没有长按,右键(次键点击)同样打开消息菜单。
        onSecondaryTap: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: ChatBubbleFrame(
          isUser: isUser,
          groupStart: groupStart,
          groupEnd: groupEnd,
          selected: selected,
          highlighted: highlighted,
          style: style,
          // 用户与助手气泡都按内容宽度自适应(短消息是小气泡),各自有最大宽度
          // 上限:用户 520/移动满宽,助手 760/移动满宽。约束放在外壳上,
          // 作用域是**可见气泡**(边距之外),不把外边距算进上限。
          constraints: BoxConstraints(
            maxWidth: isUser
                ? userBubbleMaxWidth(context)
                : assistantBubbleMaxWidth(context),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // base64 优先:本地持久化的图(生成时已下载落库)绝不走网络,
              // 对话中/重启后都不会重新加载;URL 仅作为无本地字节时的回退。
              // 空串是历史导入/轻量查询的残留,不能当成"有本地图"。
              if (message.imageBase64?.isNotEmpty == true)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _withImageProgress(
                    _CachedMemoryImage(
                      base64: message.imageBase64!,
                      decodeSize: decodeSize,
                      onDelete: deleteImage,
                    ),
                  ),
                )
              else if (message.hasImage &&
                  message.id != null &&
                  imageLoader != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  // 轻量查询出的"库里有图":按 id 惰性读 base64(LRU 缓存)。
                  child: _withImageProgress(
                    _LazyMemoryImage(
                      messageId: message.id!,
                      loader: imageLoader!,
                      revision: imageRevision,
                      decodeSize: decodeSize,
                      onDelete: deleteImage,
                    ),
                  ),
                )
              else if (imageUrl != null && imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _withImageProgress(
                    _CachedNetworkImage(
                      imageUrl: imageUrl,
                      decodeSize: decodeSize,
                      onDelete: deleteImage,
                    ),
                  ),
                ),
              // 正文渲染走 RichMessageText 显示管线(宏替换 + 正则脚本 +
              // 富文本解析);仅显示层改写,存储/发给 LLM 的内容保持原样。
              // 可见文本为空时组件自身返回零尺寸占位。字体随角色级样式。
              // 用户气泡额外支持 <tag>…</tag> 折叠段(hook 输入改写的落库
              // 形态,见 [kUserFoldableTagPattern]):默认收起为一枚 chip,
              // 点击展开/收起,纯显示层。
              if (isUser)
                _UserMessageBody(
                  content: message.content,
                  baseStyle: chatBubbleTextStyle(onBubble, bold: true),
                  userName: displayUserName,
                  charName: displayCharName,
                  scripts: regexScripts,
                  glossary: glossary,
                  onTermTap: onTermTap,
                  highlightDialogue: highlightDialogue,
                  skillNames: skillNames,
                  skillTokenPattern: skillTokenPattern,
                )
              else
                RichMessageText(
                  text: message.content,
                  style: chatBubbleTextStyle(
                    onBubble,
                    fontFamily: style?.fontFamily,
                  ),
                  userName: displayUserName,
                  charName: displayCharName,
                  scripts: regexScripts,
                  glossary: glossary,
                  onTermTap: onTermTap,
                  highlightDialogue: highlightDialogue,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 重新生图期间在图片上叠半透明遮罩与转圈;其余时刻原样返回。
  Widget _withImageProgress(Widget child) {
    if (!regenerating) return child;
    return Stack(
      children: [
        child,
        const Positioned.fill(
          child: ColoredBox(
            color: Colors.black38,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 用户气泡正文的分段渲染:把 `<tag>说明行\n正文</tag>` 段(hook 改写指令
/// 的落库形态)切成可折叠 chip,其余文本照常走 RichMessageText 管线。
///
/// StatefulWidget + 记忆化:流式期间消息列表会以约 25FPS 重建可见气泡,
/// 历史用户消息的入参全部未变,直接复用上次构建的子树,避免每个流式块
/// 重扫 `<tag>` 标签、重建整段 Widget 树。技能正则由聊天页预编译下传,
/// 未提供时才按 [skillNames] 现场编译。
class _UserMessageBody extends StatefulWidget {
  final String content;
  final TextStyle baseStyle;
  final String? userName;
  final String? charName;
  final List<CompiledRegexScript>? scripts;
  final CompiledGlossary? glossary;
  final void Function(GlossaryTerm term)? onTermTap;
  final bool highlightDialogue;
  final Set<String>? skillNames;
  final RegExp? skillTokenPattern;

  const _UserMessageBody({
    required this.content,
    required this.baseStyle,
    this.userName,
    this.charName,
    this.scripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
    this.skillNames,
    this.skillTokenPattern,
  });

  @override
  State<_UserMessageBody> createState() => _UserMessageBodyState();
}

class _UserMessageBodyState extends State<_UserMessageBody> {
  Widget? _cachedBody;
  String? _cachedContent;
  TextStyle? _cachedStyle;
  String? _cachedUserName;
  String? _cachedCharName;
  List<CompiledRegexScript>? _cachedScripts;
  CompiledGlossary? _cachedGlossary;
  void Function(GlossaryTerm term)? _cachedOnTermTap;
  bool? _cachedHighlight;
  String? _cachedPatternSource;
  Color? _cachedTokenColor;
  ColorScheme? _cachedScheme;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pattern =
        widget.skillTokenPattern ??
        ((widget.skillNames == null || widget.skillNames!.isEmpty)
            ? null
            : skillTokenPattern(widget.skillNames!));
    final tokenColor = pattern == null
        ? null
        : skillTokenColor(scheme, onPrimaryBubble: true);

    final canReuse =
        _cachedBody != null &&
        _cachedContent == widget.content &&
        _cachedStyle == widget.baseStyle &&
        _cachedUserName == widget.userName &&
        _cachedCharName == widget.charName &&
        identical(_cachedScripts, widget.scripts) &&
        identical(_cachedGlossary, widget.glossary) &&
        _cachedOnTermTap == widget.onTermTap &&
        _cachedHighlight == widget.highlightDialogue &&
        _cachedPatternSource == pattern?.pattern &&
        _cachedTokenColor == tokenColor &&
        _cachedScheme == scheme;
    if (canReuse) return _cachedBody!;

    _cachedContent = widget.content;
    _cachedStyle = widget.baseStyle;
    _cachedUserName = widget.userName;
    _cachedCharName = widget.charName;
    _cachedScripts = widget.scripts;
    _cachedGlossary = widget.glossary;
    _cachedOnTermTap = widget.onTermTap;
    _cachedHighlight = widget.highlightDialogue;
    _cachedPatternSource = pattern?.pattern;
    _cachedTokenColor = tokenColor;
    _cachedScheme = scheme;

    final content = widget.content;
    final baseStyle = widget.baseStyle;
    final widgets = <Widget>[];
    var last = 0;
    void addPlain(int start, int end) {
      if (end <= start) return;
      widgets.add(
        RichMessageText(
          text: content.substring(start, end),
          style: baseStyle,
          userName: widget.userName,
          charName: widget.charName,
          scripts: widget.scripts,
          glossary: widget.glossary,
          onTermTap: widget.onTermTap,
          highlightDialogue: widget.highlightDialogue,
          skillTokenPattern: pattern,
          skillTokenColor: tokenColor,
        ),
      );
    }

    for (final m in kUserFoldableTagPattern.allMatches(content)) {
      // 附件包裹标签不是"改写指令",不折叠 —— 留在普通段里被管线剥离。
      if (m[1] == 'system-reminder') continue;
      addPlain(last, m.start);
      widgets.add(
        _FoldableNote(
          inner: m[2] ?? '',
          baseStyle: baseStyle,
          userName: widget.userName,
          charName: widget.charName,
          scripts: widget.scripts,
          glossary: widget.glossary,
          onTermTap: widget.onTermTap,
          highlightDialogue: widget.highlightDialogue,
        ),
      );
      last = m.end;
    }
    addPlain(last, content.length);
    _cachedBody = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
    return _cachedBody!;
  }
}

/// 用户气泡里可折叠的 `<tag>…</tag>` 段形态:标签名小写字母/下划线开头,
/// 内容跨行非贪婪匹配到同名闭标签。仅用于显示层切分。
final RegExp kUserFoldableTagPattern = RegExp(
  r'<([a-z_][a-z0-9_]*)>([\s\S]*?)</\1>',
);

/// 用户气泡内的折叠指令块:默认收起为一枚半透明 chip(说明行作标签),
/// 点击展开正文区(正文继续走 RichMessageText 显示管线)。纯显示层状态。
class _FoldableNote extends StatefulWidget {
  /// `<tag>` 内的完整内容(首行 = 说明行/chip 标签,余下为展开正文)。
  final String inner;
  final TextStyle baseStyle;
  final String? userName;
  final String? charName;
  final List<CompiledRegexScript>? scripts;
  final CompiledGlossary? glossary;
  final void Function(GlossaryTerm term)? onTermTap;
  final bool highlightDialogue;

  const _FoldableNote({
    required this.inner,
    required this.baseStyle,
    this.userName,
    this.charName,
    this.scripts,
    this.glossary,
    this.onTermTap,
    this.highlightDialogue = true,
  });

  @override
  State<_FoldableNote> createState() => _FoldableNoteState();
}

class _FoldableNoteState extends State<_FoldableNote> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final inner = widget.inner.trim();
    if (inner.isEmpty) return const SizedBox.shrink();
    final nl = inner.indexOf('\n');
    final label = (nl >= 0 ? inner.substring(0, nl) : inner).trim();
    final body = nl >= 0 ? inner.substring(nl + 1).trim() : '';
    final expandable = body.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: expandable ? () => setState(() => _expanded = !_expanded) : null,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    expandable ? Icons.auto_awesome : Icons.notes,
                    size: 13,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (expandable)
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more,
                        size: 15,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                ],
              ),
            ),
            if (_expanded && expandable)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: RichMessageText(
                  text: body,
                  style: widget.baseStyle.copyWith(fontSize: 13),
                  userName: widget.userName,
                  charName: widget.charName,
                  scripts: widget.scripts,
                  glossary: widget.glossary,
                  onTermTap: widget.onTermTap,
                  highlightDialogue: widget.highlightDialogue,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 图片框的尺寸上限:宽度受气泡最大宽限制,高度超过此值后不再撑高,
/// 而是按固有比例同步收窄宽度(见 [_AdaptiveImage]),避免超高竖图把聊天页
/// 撑爆,同时框比例始终等于图片比例(不裁切、不留边)。
const double _maxImageHeight = 520;

/// 按图片固有宽高比自适应形状的图片控件。
///
/// 不能把框固定成 `height: 200 + BoxFit.cover`:cover 会裁掉超出框的边,
/// 竖图截上下、横图截左右。这里从 ImageStream 取真实尺寸,按「满气泡宽 +
/// 固有比例」算高;仅当自然高度超过 [_maxImageHeight] 时**按比例收窄宽度**
/// 而不是压扁高度,框与图片始终同比例,不裁切也不留边。
///
/// 解码完成前用方形占位,拿到 [ImageInfo] 后一次到位;流报错落静态失败
/// 占位,不自动重试。
///
/// [onTap] 非空时点击图片打开全屏查看;气泡单击的"选中消息"手势只作用于
/// 图片之外的区域,两者不冲突。
class _AdaptiveImage extends StatefulWidget {
  final ImageProvider provider;
  final VoidCallback? onTap;

  /// 已知的宽高比(本地字节 LRU 命中时传入):首帧就按真实比例占位,
  /// 滚动回看不再先闪一帧方图。
  final double? initialAspect;

  /// 首次解析出真实宽高比时回调(调用方写入 LRU,供下次回看直接使用)。
  final ValueChanged<double>? onAspectResolved;

  /// 图片流加载失败时回调(URL 图用于清理失效的磁盘缓存并重试一次)。
  final VoidCallback? onLoadFailed;

  const _AdaptiveImage({
    required this.provider,
    this.onTap,
    this.initialAspect,
    this.onAspectResolved,
    this.onLoadFailed,
  });

  @override
  State<_AdaptiveImage> createState() => _AdaptiveImageState();
}

class _AdaptiveImageState extends State<_AdaptiveImage> {
  ImageInfo? _info;

  /// 图片流报错(网络拉取失败 / 解码异常):不再无限转圈,改显静态失败占位。
  /// 不自动重试(与 NetworkImage 一致的语义),但也不拦截后续重建的重试。
  bool _failed = false;

  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// 上次解析过的 provider:变化时(或首次)才重新 resolve。
  /// 解析必须在 didChangeDependencies 里做 —— createLocalImageConfiguration 依赖
  /// MediaQuery(inherited widget),不能在 initState 里调用。
  ImageProvider? _resolved;

  @override
  void initState() {
    super.initState();
    // 首次解析推迟到 didChangeDependencies(那里才能读 inherited)。
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!identical(_resolved, widget.provider)) {
      _detach();
      _resolved = widget.provider;
      _failed = false;
      _listen();
    }
  }

  @override
  void didUpdateWidget(covariant _AdaptiveImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.provider, widget.provider)) {
      _detach();
      _info = null;
      _failed = false;
      _resolved = null; // 下次 didChangeDependencies 用新 provider 重新解析。
    }
  }

  void _listen() {
    _stream = widget.provider.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        final firstFrame = _info == null;
        setState(() => _info = info);
        if (firstFrame) {
          final h = info.image.height;
          if (h > 0) widget.onAspectResolved?.call(info.image.width / h);
        }
      },
      onError: (_, __) {
        // 捕获流错误:网络拉取失败/本地解码异常都落到失败占位;若省略
        // onError,失败的网络图会一直转圈,用户永远等不到结果。
        if (mounted) setState(() => _failed = true);
        widget.onLoadFailed?.call();
      },
    );
    _stream!.addListener(_listener!);
  }

  /// 仅摘掉本控件自己的监听:渲染走 [RawImage](直接用已解码帧),没有第二个
  /// `Image` 再监听同一 completer,因此 dispose 时不会有"共享流已 dispose"的竞态。
  void _detach() {
    _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    // 已知比例(本次已解码 info,或 LRU 带回来的上次结果)优先;
    // 完全未知时才退回方形占位。
    final aspect = info != null
        ? info.image.width / info.image.height
        : (widget.initialAspect ?? 1.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 先按"满气泡宽 + 固有比例"算自然高;若超过 [_maxImageHeight],
        // 只压高度不压宽度会让框比例与图比例不一致,contain 只能左右留边,
        // 气泡变成"宽框 + 中间一小张图"。这里把宽度按同一比例同步收窄:
        // 宽 = 高上限 × 固有比例,框始终与图片同比例,且两维都在上限内。
        var width = constraints.maxWidth;
        var height = width / aspect;
        if (height > _maxImageHeight) {
          height = _maxImageHeight;
          width = height * aspect;
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox(
            width: width,
            height: height,
            child: info == null
                ? (_failed
                      ? const _BrokenImagePlaceholder()
                      : const _CachedImagePlaceholder())
                : RawImage(
                    image: info.image,
                    // 框比例 == 图比例 → 恰好铺满无裁切;contain 仅作异常比例
                    // 数据下的兜底,正常路径下不产生任何留边。
                    fit: BoxFit.contain,
                  ),
          ),
        );
      },
    );
  }
}

/// 气泡里的远程图片(消息只带 `image_url`、无本地字节时的回退)。
///
/// 必须是 StatefulWidget:流式期间气泡会被高频重建,若每次重建都新建
/// provider,同一 URL 会反复加载/解码并闪一次「占位 → 图片」。加载顺序:
/// 1. 磁盘缓存命中 → 以缓存文件建 [FileImage](路径为缓存键、不把字节读进
///    Dart 堆),只预读文件头取宽高比,让占位框一开始就是正确形状;
/// 2. 未命中 → 经 [downloadImageBytes] 下载(超时与连接停滞重试都有上限,
///    见该函数),**拿到字节立即渲染、后台写盘**,后续重建改走磁盘文件;
/// 3. 下载失败/空 body → 静态失败占位,不留无限转圈。
///
/// 下载完成即把 provider 换成本地图,与全屏查看器收敛到同一状态 —— 否则
/// 慢速或停滞的网络请求会一直占着气泡转圈,点开大图却是好的。缓存文件
/// 被清理/损坏时最多回退重载一次,避免网络持续失败时循环。
class _CachedNetworkImage extends StatefulWidget {
  final String imageUrl;

  /// 气泡内缩略解码尺寸上限(物理像素)。
  final _DecodeSize decodeSize;

  /// 全屏查看器的"删除图片"回调(null = 无删除入口),透传给查看器。
  final Future<void> Function()? onDelete;
  const _CachedNetworkImage({
    required this.imageUrl,
    required this.decodeSize,
    this.onDelete,
  });

  @override
  State<_CachedNetworkImage> createState() => _CachedNetworkImageState();
}

class _CachedNetworkImageState extends State<_CachedNetworkImage> {
  bool _failed = false;

  /// 当前展示用的 provider;null 表示仍在读盘/下载(显示占位框)。
  ImageProvider? _provider;

  /// 从文件头预读的宽高比(解码完成前也能按真实比例占位)。
  double? _aspect;

  /// 缓存文件失效(被 LRU 清理/损坏)时只回退重载一次,避免网络持续失败时循环。
  bool _retried = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 磁盘优先、网络兜底;每次 await 后都校验 mounted 与 URL 未变,
  /// 防止旧请求的回调覆盖新图片的状态。
  Future<void> _load() async {
    final url = widget.imageUrl;
    try {
      final cached = await DiskImageCache.existingFile(url);
      if (!mounted || widget.imageUrl != url) return;
      if (cached != null) {
        // 磁盘命中:文件直接解码,不联网、不占 Dart 堆;只预读 64KB 文件头
        // 拿宽高比,让解码期间的占位框就是正确形状。
        final aspect = await imageAspectFromFile(cached);
        if (!mounted || widget.imageUrl != url) return;
        setState(() {
          _aspect = aspect;
          _provider = _downsampledFile(cached, size: widget.decodeSize);
        });
        return;
      }
      // 磁盘未命中:经下载器取一次(超时 + 连接停滞重试都有上限)。
      final bytes = await downloadImageBytes(url);
      if (!mounted || widget.imageUrl != url) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      // 下载完成立即用内存字节渲染(不等写盘),写盘交给后台 —— 之后的重建/
      // 滚动回看会命中磁盘文件,以稳定的路径键复用 ImageCache。
      setState(() {
        _aspect = imageAspectFromBytes(bytes);
        _provider = _downsampled(bytes, size: widget.decodeSize);
      });
      unawaited(DiskImageCache.write(url, bytes));
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 磁盘文件可能在缓存淘汰/外部清理后消失:FileImage 报错后清空 provider,
  /// 重新走「磁盘 → 网络」一次(会重新下载并写盘)。仅重试一次。
  Future<void> _handleLoadFailed() async {
    if (_retried || !mounted) return;
    _retried = true;
    setState(() {
      _failed = false;
      _provider = null;
    });
    await _load();
  }

  @override
  void didUpdateWidget(covariant _CachedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.decodeSize != widget.decodeSize) {
      // URL 真的变了才重新加载;同 URL 复用缓存,避免滚动/重建时重复拉取。
      // 解码尺寸变化(如横竖屏切换)才需要按新尺寸重新解码。
      _failed = false;
      _retried = false;
      _provider = null;
      _aspect = null;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _provider;
    if (p != null) {
      // 点击全屏查看:全屏页自己按"磁盘缓存 → 网络"再取一次全尺寸字节。
      return _AdaptiveImage(
        provider: p,
        initialAspect: _aspect,
        onLoadFailed: _handleLoadFailed,
        onTap: () => showImageFullscreen(
          context,
          url: widget.imageUrl,
          onDelete: widget.onDelete,
        ),
      );
    }
    if (_failed) {
      return const SizedBox(
        width: double.infinity,
        height: 200,
        child: _BrokenImagePlaceholder(),
      );
    }
    // 磁盘读取/下载完成前先占位(下载有 30s 超时 + 停滞重试上限,不会无限悬挂)。
    return const SizedBox(
      width: double.infinity,
      height: 200,
      child: _CachedImagePlaceholder(),
    );
  }
}

/// 气泡里的本地图片(消息库的 image_base64;生成时已下载落库,不走网络)。
///
/// 每次重建若重新 safeBase64Decode + Image.memory,整幅图会被反复解码;
/// 这里把字节与 MemoryImage provider 缓存在 State,仅当 base64 或解码尺寸
/// 真正变化时才重算,再交给 [_AdaptiveImage] 按真实宽高比定高。
class _CachedMemoryImage extends StatefulWidget {
  final String base64;

  /// 气泡内缩略解码尺寸上限(物理像素)。
  final _DecodeSize decodeSize;

  /// 全屏查看器的"删除图片"回调(null = 无删除入口),透传给查看器。
  final Future<void> Function()? onDelete;
  const _CachedMemoryImage({
    required this.base64,
    required this.decodeSize,
    this.onDelete,
  });

  @override
  State<_CachedMemoryImage> createState() => _CachedMemoryImageState();
}

class _CachedMemoryImageState extends State<_CachedMemoryImage> {
  Uint8List? _bytes;
  ImageProvider? _provider;

  /// 从文件头预读的宽高比(解码完成前也能按真实比例占位)。
  double? _aspect;

  @override
  void didUpdateWidget(covariant _CachedMemoryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.base64 != widget.base64 ||
        oldWidget.decodeSize != widget.decodeSize) {
      _bytes = null;
      _provider = null;
      _aspect = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes ??= safeBase64Decode(widget.base64);
    if (bytes == null) return const SizedBox.shrink();
    // 点击全屏查看:气泡内为了省内存按「气泡框尺寸上限」解码,全屏页用
    // 原始字节按 2K 宽高上限重新解出,不经过本地缩略图。
    return _AdaptiveImage(
      provider: _provider ??= _downsampled(bytes, size: widget.decodeSize),
      initialAspect: _aspect ??= imageAspectFromBytes(bytes),
      onTap: () =>
          showImageFullscreen(context, bytes: bytes, onDelete: widget.onDelete),
    );
  }
}

/// 惰性加载的本地图片:轻量查询后消息只带 `has_image` 标志,这里按 id 向
/// 仓库单条读取 base64。解码结果进静态 LRU(滚动重建/State 销毁都不再回库),
/// base64 → 字节的重解码放在后台 isolate(3MB 级字符串主线程解码会掉帧)。
class _LazyMemoryImage extends StatefulWidget {
  final int messageId;
  final Future<String?> Function(int messageId) loader;

  /// 图片内容修订号:原地替换后递增,变化时绕过旧缓存重新读库。
  final int revision;

  /// 气泡内缩略解码尺寸上限(物理像素)。
  final _DecodeSize decodeSize;

  /// 全屏查看器的"删除图片"回调(null = 无删除入口),透传给查看器。
  final Future<void> Function()? onDelete;
  const _LazyMemoryImage({
    required this.messageId,
    required this.loader,
    this.revision = 0,
    required this.decodeSize,
    this.onDelete,
  });
  @override
  State<_LazyMemoryImage> createState() => _LazyMemoryImageState();
}

class _LazyMemoryImageState extends State<_LazyMemoryImage> {
  ImageProvider? _provider;
  bool _failed = false;

  /// 全尺寸字节(气泡内展示用降采样结果,这里保留原字节供全屏查看)。
  Uint8List? _bytes;

  /// LRU 里带回来的宽高比:回看同一张图时首帧就能按真实比例定高,
  /// 不再先闪一帧方形占位。
  double? _initialAspect;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LazyMemoryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId ||
        oldWidget.revision != widget.revision) {
      _provider = null;
      _bytes = null;
      _initialAspect = null;
      _failed = false;
      _load();
    } else if (oldWidget.decodeSize != widget.decodeSize) {
      // 屏幕像素比/尺寸变化:按新尺寸重新解码,字节仍从 LRU 复用。
      _provider = null;
      _load();
    }
  }

  /// LRU 优先,未命中回库;base64 解码放后台 isolate(3MB 级字符串在主线程
  /// 解码会掉帧)。任何异常都必须落到失败态,否则占位转圈永远不停。
  Future<void> _load() async {
    try {
      final cached = _LazyImageCache.get(widget.messageId, widget.revision);
      if (cached != null) {
        if (mounted) {
          _bytes = cached.bytes;
          _initialAspect = cached.aspect;
          setState(
            () => _provider = _downsampled(
              cached.bytes,
              size: widget.decodeSize,
            ),
          );
        }
        return;
      }
      final base64 = await widget.loader(widget.messageId);
      final bytes = base64 == null
          ? null
          : await compute(safeBase64Decode, base64);
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _failed = true);
        return;
      }
      _bytes = bytes;
      // 文件头就能给出真实比例:解码尚未完成时占位框已按正确形状布局,
      // 不再先闪一个方形再跳到真实高度(长会话滚动锚点也不再被二次扰动)。
      _initialAspect = imageAspectFromBytes(bytes);
      _LazyImageCache.put(
        widget.messageId,
        widget.revision,
        bytes,
        aspect: _initialAspect,
      );
      setState(
        () => _provider = _downsampled(bytes, size: widget.decodeSize),
      );
    } catch (_) {
      // 读库/解码抛异常也必须落到失败态,否则占位转圈永远不停。
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _provider;
    if (p != null) {
      final full = _bytes;
      return _AdaptiveImage(
        provider: p,
        initialAspect: _initialAspect,
        // 首次解码出的比例写回 LRU,下次滚动回看直接按真实比例布局。
        onAspectResolved: (aspect) => _LazyImageCache.putAspect(
          widget.messageId,
          widget.revision,
          aspect,
        ),
        // 惰性读取失败(无字节)时不接点击,避免打开一个空白全屏页。
        onTap: full == null
            ? null
            : () => showImageFullscreen(
                context,
                bytes: full,
                onDelete: widget.onDelete == null
                    ? null
                    : () async {
                        await widget.onDelete!();
                        // 删除落库后把本消息的惰性缓存字节一并清掉,防止
                        // 同 id 重建时 LRU 先命中、图"删了又回来"。
                        _LazyImageCache.remove(widget.messageId);
                      },
              ),
      );
    }
    if (_failed) return const SizedBox.shrink();
    return const SizedBox(
      width: double.infinity,
      height: 200,
      child: _CachedImagePlaceholder(),
    );
  }
}

/// LRU 中的一条图片记录:字节、修订号与已解码的宽高比。
class _LazyImageEntry {
  /// 写入时的消息图片修订号;与读取方不一致即视为失效。
  final int revision;
  final Uint8List bytes;

  /// 首次解码得到的宽高比;null = 还没解码过。
  double? aspect;

  _LazyImageEntry(this.revision, this.bytes, this.aspect);
}

/// 惰性图片字节的静态 LRU:气泡 State 在滚动中会被销毁重建,没有这层缓存
/// 每次重建都要回库重读 + 重解码。
///
/// 上限按**字节总量**而非张数 —— 生图单张 1.5~3MB,按张数计可轻易常驻
/// 数十 MB Dart 堆;32MB 封顶后长会话滚动回看也不会把字节推到失控,逐出
/// 仍是最旧优先。
class _LazyImageCache {
  static final LinkedHashMap<int, _LazyImageEntry> _map = LinkedHashMap();
  static const _maxBytes = 32 * 1024 * 1024;
  static int _bytes = 0;

  /// 命中要求修订号一致:原地替换后旧字节不再返回,由调用方回库重读。
  static _LazyImageEntry? get(int id, int revision) {
    final v = _map.remove(id);
    if (v == null) return null;
    if (v.revision != revision) return null;
    _map[id] = v;
    return v;
  }

  /// 解码出宽高比后写回并把条目置为最近使用;条目已被逐出或修订号不符
  /// 时忽略。
  static void putAspect(int id, int revision, double aspect) {
    final v = _map.remove(id);
    if (v == null) return;
    if (v.revision != revision) {
      _map[id] = v;
      return;
    }
    v.aspect = aspect;
    _map[id] = v;
  }

  /// 主动逐出某条消息的缓存字节(该消息的图片被删除时调用)。
  static void remove(int id) {
    final v = _map.remove(id);
    if (v != null) _bytes -= v.bytes.length;
  }

  /// 写入(同 id 旧条目先逐出),随后按字节总量裁到上限;单张超上限的
  /// 极端大图会被自身逐出,不做特判 —— 下次未命中再回库。
  static void put(
    int id,
    int revision,
    Uint8List bytes, {
    double? aspect,
  }) {
    remove(id);
    _map[id] = _LazyImageEntry(revision, bytes, aspect);
    _bytes += bytes.length;
    while (_bytes > _maxBytes && _map.isNotEmpty) {
      final oldest = _map.keys.first;
      _bytes -= _map[oldest]!.bytes.length;
      _map.remove(oldest);
    }
  }
}

/// 气泡内缩略解码:宽高上限由调用方按「显示宽 × DPR」与「图片框高 × DPR」
/// 给出(最宽 1520),policy=fit 保持比例且不放大小图。全屏查看器仍使用
/// 原始字节,不受这里的尺寸影响。
ImageProvider _downsampled(Uint8List bytes, {required _DecodeSize size}) =>
    ResizeImage(
      MemoryImage(bytes),
      width: size.width,
      height: size.height,
      policy: ResizeImagePolicy.fit,
    );

/// 磁盘缓存文件直接以 [FileImage] 解码:缓存键是稳定的文件路径(跨 State
/// 重建/重启都命中 ImageCache),且 `ImmutableBuffer.fromFilePath` 不会把
/// 图片字节复制进 Dart 堆。
ImageProvider _downsampledFile(File file, {required _DecodeSize size}) =>
    ResizeImage(
      FileImage(file),
      width: size.width,
      height: size.height,
      policy: ResizeImagePolicy.fit,
    );

/// 图片加载占位:灰色圆角块 + 转圈,填满当前图片框。
class _CachedImagePlaceholder extends StatelessWidget {
  const _CachedImagePlaceholder();
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    height: double.infinity,
    alignment: Alignment.center,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const SizedBox(
      width: 24,
      height: 24,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

/// 图片加载失败占位:同款灰底 + 破碎图图标(与全屏查看器的失败态同语言),
/// 替代"永远转圈" —— 网络图拉取失败/本地字节解码异常时静态展示,不阻塞其余气泡。
class _BrokenImagePlaceholder extends StatelessWidget {
  const _BrokenImagePlaceholder();
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    height: double.infinity,
    alignment: Alignment.center,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Icon(
      Icons.broken_image_outlined,
      size: 28,
      color: Theme.of(context).colorScheme.outline,
    ),
  );
}
