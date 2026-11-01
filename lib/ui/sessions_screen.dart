/// 角色会话列表:搜索、新建、重命名、删除与会话归档导入导出。
///
/// 导出经系统保存/分享(移动端)或另存为(桌面),归档流式写盘;导入是
/// 两遍扫描的流式读取,截断/坏档在写库前报错,取消不留下数据。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../export/session_exporter.dart';
import '../import/json_stream_reader.dart';
import '../import/session_importer.dart';
import '../models/character_card.dart';
import '../state/providers.dart';
import 'chat_screen.dart';
import 'common/app_menu.dart';
import 'common/app_search_field.dart';
import 'common/confirm_dialog.dart';
import 'common/section_header.dart';
import 'common/empty_state.dart';
import 'common/pick_file_bytes.dart';
import 'common/progress_task.dart';
import 'common/scroll_to_top_fab.dart';
import 'common/session_file_helper.dart';
import 'common/shrink_image.dart';

/// 角色的会话列表,从角色卡点击进入:点击会话进聊天页,搜索匹配标题与
/// 最近消息。
///
/// 新建会话时若角色有开场白,会作为助手首条消息落库;删除会话级联删除
/// 消息。导入归档可能落到其它(或新建)角色名下,完成后整族会话 provider
/// 一起失效。
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
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _createSession(BuildContext context, WidgetRef ref) async {
    final id = await ref
        .read(sessionRepositoryProvider)
        .create(widget.characterId, '新会话');
    if (widget.character.firstMessage.isNotEmpty) {
      await ref
          .read(messageRepositoryProvider)
          .append(
            sessionId: id,
            role: 'assistant',
            content: widget.character.firstMessage,
          );
    }
    ref.invalidate(sessionInfosProvider(widget.characterId));
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
    final controller = TextEditingController(text: current);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '会话标题'),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // ChangeNotifier 用完即弃:对话框关闭(确认/取消/点外部)后必释放,
    // 此前每次重命名泄漏一个 controller。
    controller.dispose();
    if (newTitle == null || newTitle.trim().isEmpty) return;
    await ref
        .read(sessionRepositoryProvider)
        .rename(sessionId, newTitle.trim());
    ref.invalidate(sessionInfosProvider(widget.characterId));
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
    ref.invalidate(sessionInfosProvider(widget.characterId));
  }

  /// 导出会话归档:保存/分享通道交给 `saveSessionArchive`,取消与失败
  /// 由其统一提示;归档内容由 `SessionExporter` 流式写出。
  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    int sessionId,
    String title,
  ) async {
    await saveSessionArchive(
      context,
      fileName: '$title.json',
      build: (staging, {onProgress, isCancelled}) =>
          SessionExporter(ref.read(databaseProvider)).exportToFile(
            sessionId: sessionId,
            file: staging,
            onProgress: onProgress,
            isCancelled: isCancelled,
          ),
    );
  }

  /// 导入会话归档:同名角色复用既有(不动本地卡与世界书),否则随卡新建。
  /// 走流式读取:几百 MB 的图片消息也能导入,不再受 50MB 上限限制。
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: false,
    );
    final path = await pickedFilePath(picked?.files.single);
    if (path == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('导入失败:未读取到所选文件')));
      }
      return;
    }
    if (!context.mounted) return;
    try {
      final imported = await runWithProgress<SessionImportResult>(
        context,
        title: '正在导入会话',
        task: (controller) async {
          controller.report(message: '正在扫描归档…');
          return SessionImporter.importFile(
            ref.read(databaseProvider),
            File(path),
            avatarShrinker: shrinkBase64Image,
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
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            imported.reusedCharacter
                ? '已导入会话(复用角色「${widget.character.name}」)'
                : '已导入会话,并新建了同名未匹配的角色',
          ),
        ),
      );
    } on ArchiveScanCancelled {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已取消导入')));
    } on FormatException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败:${e.message}')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final infos = ref.watch(sessionInfosProvider(widget.characterId));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.character.name),
        actions: [
          IconButton(
            tooltip: '导入会话',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: () => _import(context, ref),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ScrollToTopFab(controller: _scroll),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            onPressed: () => _createSession(context, ref),
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('新建会话'),
          ),
        ],
      ),
      body: infos.when(
        data: (list) {
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
          final query = _query.trim().toLowerCase();
          final filtered = query.isEmpty
              ? list
              : list
                    .where((s) {
                      final title = s.title.isEmpty ? '会话 #${s.id}' : s.title;
                      return title.toLowerCase().contains(query) ||
                          (s.lastMessage?.toLowerCase().contains(query) ??
                              false);
                    })
                    .toList(growable: false);
          return Column(
            children: [
              AppSearchField(
                controller: _search,
                hint: '搜索会话标题或消息内容',
                onChanged: (v) {
                  if (_query != v) setState(() => _query = v);
                },
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.search_off,
                        title: '没有匹配的会话',
                        message: '换一个关键词试试。',
                      )
                    // 按会话虚拟化:每个条目是独立卡片。旧实现把所有会话塞进
                    // 单个 GroupCard(内部 Column)作为列表唯一 item,再长的
                    // 会话列表也会一次性构建/布局,且列表刷新时全部重建。
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.only(top: 4, bottom: 96),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final s = filtered[index];
                          final title = s.title.isEmpty
                              ? '会话 #${s.id}'
                              : s.title;
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
                                            '${s.imageCount == 0 ? '' : '：${s.messageCount - s.imageCount} 条文本 + ${s.imageCount} 条图片'}'
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
                                      case 'delete':
                                        _delete(context, ref, s.id);
                                    }
                                  },
                                  actions: const [
                                    MenuAction(
                                      value: 'rename',
                                      label: '重命名',
                                      icon: Icons.edit_outlined,
                                    ),
                                    MenuAction(
                                      value: 'export',
                                      label: '导出',
                                      icon: Icons.file_download_outlined,
                                    ),
                                    MenuAction(
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
                      ),
              ),
            ],
          );
        },
        error: (e, _) =>
            EmptyState(icon: Icons.error_outline, title: '加载失败', message: '$e'),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  static final _whitespace = RegExp(r'\s+');

  static String _clip(String s) {
    final oneLine = s.replaceAll(_whitespace, ' ').trim();
    return oneLine.length <= 40 ? oneLine : '${oneLine.substring(0, 40)}…';
  }
}
