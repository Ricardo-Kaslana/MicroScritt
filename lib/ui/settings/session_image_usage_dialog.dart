/// 按会话查看消息图片构成:去重资产数、图片消息数与占用字节。
///
/// 统计只覆盖 `messages.image_hash`;同一图片在一个会话内只计一次,跨会话
/// 重复引用会分别计入,便于用户判断哪段对话最占空间。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/image_asset_store.dart';
import '../../state/providers.dart';
import '../common/byte_size.dart';
import '../common/empty_state.dart';
import '../common/inline_spinner.dart';

/// 打开「按会话查看图片」弹窗。
Future<void> showSessionImageUsageDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const SessionImageUsageDialog(),
  );
}

/// 会话图片构成弹窗;打开时查询一次,不做实时刷新。
class SessionImageUsageDialog extends ConsumerStatefulWidget {
  const SessionImageUsageDialog({super.key});

  @override
  ConsumerState<SessionImageUsageDialog> createState() =>
      _SessionImageUsageDialogState();
}

class _SessionImageUsageDialogState
    extends ConsumerState<SessionImageUsageDialog> {
  late final Future<List<SessionImageUsage>> _usage;

  @override
  void initState() {
    super.initState();
    _usage = ref.read(databaseProvider).images.sessionImageUsage(limit: 50);
  }

  @override
  Widget build(BuildContext context) {
    // 固定 360 高度在横屏/矮屏会顶出可视区;按屏高收缩,列表自身可滚动。
    final contentHeight = MediaQuery.sizeOf(context).height * 0.45;
    return AlertDialog(
      key: const ValueKey('session_image_usage_dialog'),
      title: const Text('按会话查看图片'),
      content: SizedBox(
        width: 520,
        height: contentHeight > 360 ? 360 : contentHeight,
        child: FutureBuilder<List<SessionImageUsage>>(
          future: _usage,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: InlineSpinner(size: 24));
            }
            if (snapshot.hasError) {
              return EmptyState(
                compact: true,
                icon: Icons.error_outline,
                title: '无法读取会话图片统计',
                message: '${snapshot.error}',
              );
            }
            final rows = snapshot.data ?? const <SessionImageUsage>[];
            if (rows.isEmpty) {
              return const EmptyState(
                compact: true,
                icon: Icons.image_not_supported_outlined,
                title: '暂无会话图片',
                message: '导入或收到图片后,这里会按会话汇总占用。',
              );
            }
            return ListView.separated(
              key: const ValueKey('session_image_usage_list'),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = rows[index];
                return ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  title: Text(
                    row.title.isEmpty ? '会话 #${row.sessionId}' : row.title,
                  ),
                  subtitle: Text(
                    '${row.assetCount} 个资产 · ${row.messageCount} 条图片消息',
                  ),
                  trailing: Text(
                    formatByteSize(row.bytes),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
