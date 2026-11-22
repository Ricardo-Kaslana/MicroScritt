/// 角色会话列表:搜索、新建、重命名、删除与会话归档导入导出。
///
/// 导出经系统保存/分享(移动端)或另存为(桌面),归档流式写盘;导入是
/// 两遍扫描的流式读取,截断/坏档在写库前报错,取消不留下数据。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/session_repository.dart';
import '../export/session_exporter.dart';
import '../import/json_stream_reader.dart';
import '../import/session_importer.dart';
import '../models/character_card.dart';
import '../state/providers.dart';
import 'chat_screen.dart';
import 'common/app_menu.dart';
import 'common/app_snack_bar.dart';
import 'common/async_section.dart';
import 'common/confirm_dialog.dart';
import 'common/section_header.dart';
import 'common/empty_state.dart';
import 'common/pick_file_bytes.dart';
import 'common/progress_task.dart';
import 'common/searchable_list.dart';
import 'common/session_file_helper.dart';
import '../data/shrink_image.dart';

/// 角色的会话列表,从角色卡点击进入:点击会话进聊天页,搜索匹配标题与
/// 最近消息。
///
/// 新建会话时,只有单条开场白的角色会自动把 `firstMessage` 落为助手首条
/// 消息;有多条开场白时留空会话,让用户在聊天页空态自行选择(选择只写入
/// 该会话,不跨会话记忆)。删除会话级联删除消息。导入归档可能落到其它
/// (或新建)角色名下,完成后整族会话 provider 一起失效。
class SessionsScreen extends ConsumerStatefulWidget {
  final int characterId;
  final CharacterCard character;
  const SessionsScreen({
    super.key,
    required this.characterId,
    required this.character,
  });

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  /// 会话增删改后失效列表数据:按角色的聚合供本页展示,跨角色的
  /// [sessionGroupsProvider] 供桌面聊天页侧栏 —— 后者已缓存时若不失
  /// 效,新建会话进入聊天页会在侧栏里「缺失」刚建的那条。
  void _invalidateSessionLists(WidgetRef ref) {
    ref.invalidate(sessionInfosProvider(widget.characterId));
    ref.invalidate(sessionGroupsProvider);
  }

  Future<void> _createSession(BuildContext context, WidgetRef ref) async {
    final id = await ref
        .read(sessionRepositoryProvider)
        .createWithDefaultTitle(widget.characterId);
    if (!widget.character.hasMultipleGreetings &&
        widget.character.firstMessage.isNotEmpty) {
      await ref
          .read(messageRepositoryProvider)
          .append(
            sessionId: id,
            role: 'assistant',
            content: widget.character.firstMessage,
          );
    }
    _invalidateSessionLists(ref);
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          sessionId: id,
          characterId: widget.characterId,
          character: widget.character,
        ),
      ),
    );
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    int sessionId,
    String current,
  ) async {
    final newTitle = await showDialog<String>(
      context: context,
      builder: (_) => _SessionRenameDialog(initial: current),
    );
    if (newTitle == null) return;
    final title = newTitle.trim();
    if (title.isEmpty) {
      // 空标题不落库,但也不能静默关闭 —— 用户会以为改名成功了。
      if (context.mounted) {
        showAppSnack(context, '会话标题不能为空');
      }
      return;
    }
    await ref.read(sessionRepositoryProvider).rename(sessionId, title);
    _invalidateSessionLists(ref);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    int sessionId,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除会话?',
      message: '会话内的全部消息都会被删除,不可恢复。',
    );
    if (!confirmed) return;
    await ref.read(sessionRepositoryProvider).deleteWithCascade(sessionId);
    _invalidateSessionLists(ref);
  }

  /// 导出/分享会话归档:交付通道交给 `saveSessionArchive`,取消与失败
  /// 由其统一提示;归档内容由 `SessionExporter` 流式写出。
  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    int sessionId,
    String title, {
    bool share = false,
  }) async {
    await saveSessionArchive(
      context,
      fileName: '$title.msarc',
      delivery: share
          ? SessionArchiveDelivery.share
          : SessionArchiveDelivery.save,
      build: (staging, {onProgress, isCancelled}) =>
          SessionExporter(ref.read(databaseProvider)).exportToFile(
            sessionId: sessionId,
            file: staging,
            onProgress: onProgress,
            isCancelled: isCancelled,
          ),
    );
  }

  /// 询问是否解包归档图片;null 表示用户取消导入。
  Future<bool?> _askIncludeImages(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入选项'),
        content: const Text(
          '仅文本只导入对话文字与变量等状态，'
          '消息中的图片（含远程链接）与角色头像、背景都不导入，'
          '只有图片的消息会被整条略过；导入更快、占用更小。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('仅文本'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('包含图片'),
          ),
        ],
      ),
    );
  }

  /// 导入会话归档:同名角色复用既有(不动本地卡与世界书),否则随卡新建。
  /// 走流式读取:几百 MB 的图片消息也能导入,不再受 50MB 上限限制。
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'msarc'],
      withData: false,
    );
    // 系统文件选择器的返回键是标准取消路径,取消不是失败。
    if (picked == null) {
      if (context.mounted) {
        showAppSnack(context, '已取消导入');
      }
      return;
    }
    final pickedFile = await pickedFilePath(picked.files.single);
    if (pickedFile == null) {
      if (context.mounted) {
        showAppSnack(context, '导入失败:未读取到所选文件');
      }
      return;
    }
    // 内联 bytes 兜底写出的临时归档必须在所有出口清理(含取消/异常)。
    try {
      if (!context.mounted) return;
      final includeImages = await _askIncludeImages(context);
      if (!context.mounted) return;
      if (includeImages == null) {
        showAppSnack(context, '已取消导入');
        return;
      }
      try {
        final imported = await runWithProgress<SessionImportResult>(
          context,
          title: '正在导入会话',
          task: (controller) async {
            controller.report(message: '正在扫描归档…');
            return SessionImporter.importFile(
              ref.read(databaseProvider),
              File(pickedFile.path),
              avatarShrinker: shrinkBase64Image,
              includeImages: includeImages,
              onProgress: (done, total) => controller.report(
                value: total == 0 ? null : done / total,
                message: '已导入 $done / $total 条消息',
              ),
              isCancelled: () => controller.cancelled,
            );
          },
        );
        // 会话可能落到其它(新建)角色名下,家族 provider 整体失效以覆盖所有角色。
        ref.invalidate(sessionInfosProvider);
        ref.invalidate(charactersProvider);
        ref.invalidate(sessionGroupsProvider);
        if (!context.mounted) return;
        showAppSnack(
          context,
          imported.reusedCharacter
              ? '已导入会话(复用角色「${widget.character.name}」)'
              : '已导入会话,并新建了同名未匹配的角色',
        );
      } on ArchiveScanCancelled {
        if (!context.mounted) return;
        showAppSnack(context, '已取消导入');
      } on FormatException catch (e) {
        if (!context.mounted) return;
        showAppSnack(context, '导入失败:${e.message}');
      } catch (e) {
        if (!context.mounted) return;
        showAppSnack(context, '导入失败:$e');
      }
    } finally {
      await pickedFile.deleteIfTemporary();
    }
  }

  @override
  Widget build(BuildContext context) {
    final infos = ref.watch(sessionInfosProvider(widget.characterId));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.character.name),
        actions: [
          AppPopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (_) => _import(context, ref),
            actions: const [
              MenuAction(
                value: 'import',
                label: '导入会话',
                icon: Icons.file_upload_outlined,
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createSession(context, ref),
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('新建会话'),
      ),
      body: AsyncSection<List<SessionInfo>>(
        value: infos,
        compact: false,
        onRetry: () => ref.invalidate(sessionInfosProvider(widget.characterId)),
        builder: (context, list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.chat_bubble_outline,
              title: '还没有会话',
              message: '点击下方按钮,和「${widget.character.name}」开始第一段对话。',
              action: FilledButton.tonal(
                onPressed: () => _createSession(context, ref),
                child: const Text('新建会话'),
              ),
            );
          }
          // 与其它管理页共用同一个检索外壳:无结果空态带「清除搜索」,
          // 搜索时有命中计数,回顶钮由外壳统一提供。
          return SearchableList<SessionInfo>(
            items: list,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            searchHint: '搜索会话标题或消息内容',
            noMatchTitle: '没有匹配的会话',
            searchText: (s) =>
                '${s.title.isEmpty ? '会话 #${s.id}' : s.title} ${s.lastMessage ?? ''}',
            itemBuilder: (context, s) {
              final title = s.title.isEmpty ? '会话 #${s.id}' : s.title;
              return GroupCard(
                key: ValueKey('session-card-${s.id}'),
                children: [
                  ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(title),
                    subtitle: Text(
                      s.messageCount == 0
                          ? '暂无消息'
                          : '${s.messageCount} 条消息'
                                '${s.imageCount == 0 ? '' : ':${s.messageCount - s.imageCount} 条文本 + ${s.imageCount} 条图片'}'
                                '${s.lastMessage == null ? '' : ' · ${_clip(s.lastMessage!)}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: AppPopupMenuButton<String>(
                      tooltip: '更多操作',
                      onSelected: (action) {
                        switch (action) {
                          case 'rename':
                            _rename(context, ref, s.id, s.title);
                          case 'export':
                            _export(context, ref, s.id, title);
                          case 'share':
                            _export(context, ref, s.id, title, share: true);
                          case 'delete':
                            _delete(context, ref, s.id);
                        }
                      },
                      actions: [
                        const MenuAction(
                          value: 'rename',
                          label: '重命名',
                          icon: Icons.edit_outlined,
                        ),
                        const MenuAction(
                          value: 'export',
                          label: '导出',
                          icon: Icons.file_download_outlined,
                        ),
                        if (isMobileSessionExport)
                          const MenuAction(
                            value: 'share',
                            label: '分享',
                            icon: Icons.share_outlined,
                          ),
                        const MenuAction(
                          value: 'delete',
                          label: '删除',
                          icon: Icons.delete_outline,
                          destructive: true,
                        ),
                      ],
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(
                          sessionId: s.id,
                          characterId: widget.characterId,
                          character: widget.character,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  static final _whitespace = RegExp(r'\s+');

  static String _clip(String s) {
    final oneLine = s.replaceAll(_whitespace, ' ').trim();
    return oneLine.length <= 40 ? oneLine : '${oneLine.substring(0, 40)}…';
  }
}

/// 会话重命名对话框:controller 归 Dialog 的 State 所有,随路由退场动画
/// 一并销毁,避免调用方在退场期间提前 dispose 引发 TextField 重建断言。
class _SessionRenameDialog extends StatefulWidget {
  final String initial;
  const _SessionRenameDialog({required this.initial});

  @override
  State<_SessionRenameDialog> createState() => _SessionRenameDialogState();
}

class _SessionRenameDialogState extends State<_SessionRenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名会话'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: '会话标题'),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('确定'),
      ),
    ],
  );
}
