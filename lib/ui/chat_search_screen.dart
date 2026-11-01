/// 会话内聊天记录搜索页:输入即查(防抖)的只读检索。
///
/// 点选命中只回传 messageId,窗口扩展与定位由聊天页完成;本页不写库。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/message_repository.dart';
import '../state/providers.dart';
import 'common/app_search_field.dart';
import 'common/empty_state.dart';
import 'widgets/rich_message_text.dart';

/// 会话内聊天记录搜索页:输入即查(220ms 防抖),命中按时间倒序展示。
///
/// 检索范围是当前会话的可见聊天行,最多取最新 200 条(取满即显示
/// 「仅显示最新 200 条」)。点选结果时把 messageId 回传给聊天页,由聊天页
/// 完成显示窗口扩展、定位与短暂高亮 —— 本页只读,不改动消息、上下文与
/// 显示窗口。
class ChatSearchScreen extends ConsumerStatefulWidget {
  /// 被检索的会话 id。
  final int sessionId;

  /// 助手消息一栏显示的角色名。
  final String characterName;
  const ChatSearchScreen({
    super.key,
    required this.sessionId,
    required this.characterName,
  });

  @override
  ConsumerState<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends ConsumerState<ChatSearchScreen> {
  static const int _limit = 200;
  static const Duration _debounce = Duration(milliseconds: 220);

  final _controller = TextEditingController();
  Timer? _debounceTimer;

  /// 请求代次:防抖窗口与在飞查询都靠它丢弃过期结果。
  int _request = 0;
  String _query = '';
  bool _loading = false;
  bool _searched = false;
  String? _error;
  List<_DisplayHit> _hits = const [];
  bool _truncated = false;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounceTimer?.cancel();
    final query = raw.trim();
    // 输入一变化就让在飞的旧查询作废,避免它赶在新一轮防抖之前把旧结果
    // 落进新关键词的列表里。
    if (query != _query) _request++;
    if (query.isEmpty) {
      _request++;
      setState(() {
        _query = '';
        _hits = const [];
        _truncated = false;
        _searched = false;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() => _query = query);
    _debounceTimer = Timer(_debounce, () => _search(query));
  }

  /// 执行一次检索:结果落进列表前用请求代次与 mounted 双重校验,丢弃过期
  /// 响应;SQL 在原始正文上匹配,展示口径剥离标记后仍须包含关键词才算命中
  /// (用户看不见的文本不作结果,也不做空高亮)。
  Future<void> _search(String query) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await ref
          .read(messageRepositoryProvider)
          .searchInSession(widget.sessionId, query, limit: _limit);
      if (!mounted || request != _request) return;
      final lower = query.toLowerCase();
      final hits = <_DisplayHit>[];
      for (final hit in raw) {
        // SQL 在原始正文上匹配;展示口径会剥掉内部注入/样式标记。命中若只落在
        // 被剥离的文本里(用户看不见),不作为结果返回。
        final display = _displayText(hit.content);
        final index = display.toLowerCase().indexOf(lower);
        if (index < 0) continue;
        hits.add(
          _DisplayHit(
            hit: hit,
            display: display,
            matchIndex: index,
            query: query,
          ),
        );
      }
      setState(() {
        _hits = hits;
        _truncated = raw.length >= _limit;
        _loading = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = '$e';
        _hits = const [];
        _loading = false;
        _searched = true;
      });
    }
  }

  /// 气泡样式标记与 `<chip>` 的剥离规则(与消息气泡的标记集一致)。
  static final _markupPattern = RegExp(
    r'</?(?:i|b|u|s|mark|c)(?:=#?[0-9a-fA-F]{6})?>|</?chip>',
  );
  static final _whitespace = RegExp(r'\s+');

  /// 显示层纯文本:剥内部注入与样式标记、折叠空白 —— 搜索结果片段不应露出
  /// `<system-reminder>` 或 `<i>` 之类的标记。
  static String _displayText(String content) => stripSystemReminders(
    content,
  ).replaceAll(_markupPattern, '').replaceAll(_whitespace, ' ').trim();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = ref.watch(userProfileProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('搜索聊天记录')),
      body: Column(
        children: [
          AppSearchField(
            controller: _controller,
            hint: '输入关键词搜索聊天记录',
            autofocus: true,
            onChanged: _onChanged,
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(context, scheme, user.name)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, ColorScheme scheme, String userName) {
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: '搜索失败',
        message: _error,
      );
    }
    if (_query.isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        title: '搜索聊天记录',
        message: '输入关键词,检索这段会话的全部历史消息。',
      );
    }
    if (_loading && _hits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searched && _hits.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off,
        title: '没有匹配的消息',
        message: '换一个关键词试试。',
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
          child: Row(
            children: [
              Text(
                '${_hits.length} 条结果',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (_truncated) ...[
                const SizedBox(width: 8),
                Text(
                  '仅显示最新 $_limit 条',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: _hits.length,
            itemBuilder: (context, index) {
              final hit = _hits[index];
              final isUser = hit.hit.role == 'user';
              final roleName = isUser
                  ? (userName.isEmpty ? '你' : userName)
                  : widget.characterName;
              return ListTile(
                key: ValueKey('chat-search-hit-${hit.hit.messageId}'),
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: isUser
                      ? scheme.primaryContainer
                      : scheme.secondaryContainer,
                  child: Icon(
                    isUser ? Icons.person_outline : Icons.auto_awesome_outlined,
                    size: 18,
                    color: isUser
                        ? scheme.onPrimaryContainer
                        : scheme.onSecondaryContainer,
                  ),
                ),
                title: Text.rich(
                  _snippetSpan(hit, scheme),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    roleName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                trailing: Icon(
                  Icons.north_east,
                  size: 16,
                  color: scheme.outline,
                ),
                onTap: () => Navigator.pop(context, hit.hit.messageId),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 命中片段(命中点前后各 36 字符,越界补省略号)与关键词高亮。
  ///
  /// 高亮下标按展示文本计算,关键词长度在小写折叠后可能变化,末尾再按
  /// 片段长度夹一次,避免 substring 越界。
  TextSpan _snippetSpan(_DisplayHit hit, ColorScheme scheme) {
    const radius = 36;
    final display = hit.display;
    final start = math.max(0, hit.matchIndex - radius);
    final end = math.min(
      display.length,
      hit.matchIndex + hit.query.length + radius,
    );
    // 用命中关键词长度截取高亮段;大小写折叠后长度可能变化,末尾再夹一次。
    final prefix = start > 0 ? '…' : '';
    final suffix = end < display.length ? '…' : '';
    final text = '$prefix${display.substring(start, end)}$suffix';
    final highlightStart = prefix.length + (hit.matchIndex - start);
    final highlightEnd = math.min(
      text.length,
      highlightStart + hit.query.length,
    );
    return TextSpan(
      children: [
        if (highlightStart > 0)
          TextSpan(text: text.substring(0, highlightStart)),
        TextSpan(
          text: text.substring(highlightStart, highlightEnd),
          style: TextStyle(
            backgroundColor: scheme.tertiaryContainer,
            color: scheme.onTertiaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (highlightEnd < text.length)
          TextSpan(text: text.substring(highlightEnd)),
      ],
    );
  }
}

/// 展示用命中:原始命中、剥离标记后的片段与本次关键词快照。
class _DisplayHit {
  final MessageSearchHit hit;
  final String display;
  final int matchIndex;

  /// 本次命中所用的关键词。存一份结果快照,避免使用页面最新输入(旧结果在
  /// 防抖窗口里仍会短暂显示)导致高亮段错位。
  final String query;

  const _DisplayHit({
    required this.hit,
    required this.display,
    required this.matchIndex,
    required this.query,
  });
}
