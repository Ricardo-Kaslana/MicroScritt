/// 空会话引导:角色头像与名称、输入提示,以及可直接起笔的开场白。
///
/// 角色卡的开场白(`firstMessage`)与备用开场白此前只在导入/编辑里可见,
/// 空会话却只有一行灰字。这里把它们变成一次点击就能落库的起点,同时保留
/// 「发一条消息开始对话」的输入引导。
library;

import 'package:flutter/material.dart';

import '../../models/character_card.dart';

/// 单屏最多展示的开场白条数:再多会把输入区挤出屏幕。
const int kChatEmptySuggestionLimit = 3;

/// 空会话内容区(替代一行居中灰字)。
class ChatEmptyState extends StatelessWidget {
  /// 当前角色卡(名称与开场白来源)。
  final CharacterCard character;

  /// 角色头像 provider;null 时显示占位图标。
  final ImageProvider? avatar;

  /// 点击一条开场白:以其作为助手首条消息开始会话;null = 不展示开场白。
  final ValueChanged<String>? onGreeting;

  const ChatEmptyState({
    super.key,
    required this.character,
    this.avatar,
    this.onGreeting,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = character.name.trim();
    final suggestions = onGreeting == null
        ? const <String>[]
        : _suggestions(character);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: scheme.secondaryContainer,
                      foregroundImage: avatar,
                      onForegroundImageError: avatar == null
                          ? null
                          : (_, __) {},
                      child: Icon(
                        Icons.person_outline,
                        size: 32,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      name.isEmpty ? '开始对话' : '与 $name 开始对话',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      suggestions.isEmpty
                          ? '发一条消息开始对话'
                          : '发一条消息开始对话,或从下面的开场白起笔。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    if (suggestions.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      for (final text in suggestions) ...[
                        _GreetingTile(
                          text: text,
                          onTap: () => onGreeting!(text),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 开场白候选:角色主开场白在前,备用开场白按卡内顺序补齐,去重后
  /// 最多取 [kChatEmptySuggestionLimit] 条。
  static List<String> _suggestions(CharacterCard character) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in [
      character.firstMessage,
      ...character.alternateGreetings,
    ]) {
      final text = raw.trim();
      if (text.isEmpty || !seen.add(text)) continue;
      result.add(text);
      if (result.length >= kChatEmptySuggestionLimit) break;
    }
    return result;
  }
}

/// 一条可点击的开场白:最多两行,点击后作为助手首条消息落库。
class _GreetingTile extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _GreetingTile({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(14);
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
          child: Row(
            children: [
              Icon(Icons.format_quote_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
