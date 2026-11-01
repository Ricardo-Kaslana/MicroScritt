import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/character_repository.dart';
import '../export/character_card_exporter.dart';
import '../export/character_card_png_exporter.dart';
import '../import/character_card_importer.dart';
import '../import/worldbook_importer.dart';
import '../models/character_card.dart';
import '../models/ui_prefs.dart';
import '../models/worldbook_entry.dart';
import '../state/providers.dart';
import 'character_edit_screen.dart';
import 'common/app_menu.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/export_helper.dart';
import 'common/pick_file_bytes.dart';
import 'common/progress_task.dart';
import 'common/searchable_list.dart';
import 'common/shrink_image.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';
import 'worldbook_screen.dart';

/// 角色卡管理:卡片式列表,每张卡片带角色预览图(头像大图/渐变占位)。
/// 点击进会话列表;右上角菜单提供编辑/世界书/导出/删除。
class CharacterScreen extends ConsumerWidget {
  const CharacterScreen({super.key});

  /// 原地切换列表/图片布局:先更新内存状态(立即生效),再回写偏好文件
  /// (`ui-prefs.json`,写失败只打日志,不影响本次切换)。
  Future<void> _toggleLayout(WidgetRef ref) async {
    final next = ref.read(characterLayoutProvider).toggled;
    ref.read(characterLayoutProvider.notifier).state = next;
    final file = ref.read(uiPrefsFileProvider);
    if (file == null) return;
    await file.write(UiPrefs(characterLayout: next));
  }

  void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static String _readLabel(int read, int total) {
    if (total <= 0) return '读取文件…';
    const mb = 1024 * 1024;
    final readMb = (read / mb).toStringAsFixed(1);
    final totalMb = (total / mb).toStringAsFixed(1);
    return '读取文件 $readMb / $totalMb MB';
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    // withData: false —— Android 端 file_picker 会把大文件整读进原生 ByteArray,
    // OOM 后静默丢掉字节(桌面不受影响,这就是"大卡只有移动端导入失败"的根因之一);
    // 这里一律从选择结果的 path 读,Dart 堆不占原生配额,大文件也稳。
    try {
      final result = await FilePicker.pickFiles(withData: false);
      final picked = result?.files.single;
      if (picked == null || !context.mounted) return;
      // 分阶段进度:20MB 卡光是读文件/解码缩图就要数秒,不能只丢一个会消失的
      // SnackBar 让界面看起来卡死。任务内每个阶段先让对话框完成一帧,再干重活。
      final card = await runWithProgress<CharacterCard?>(
        context,
        title: '正在导入角色卡',
        task: (controller) async {
          controller.report(message: '读取文件…');
          final bytes = await pickedFileBytes(
            picked,
            onProgress: (read, total) => controller.report(
              value: total <= 0 ? null : (read / total).clamp(0.0, 1.0),
              message: _readLabel(read, total),
            ),
          );
          if (bytes == null) {
            throw const FormatException('未读取到所选文件');
          }
          if (controller.cancelled) return null;

          final isPng = CharacterCardImporter.isPng(bytes);
          controller.report(message: '解析角色卡…');
          await WidgetsBinding.instance.endOfFrame;
          final card0 = CharacterCardImporter.fromBytes(
            bytes,
            includePngImageAsAvatar: false,
          );
          final entries = WorldbookImporter.extract(card0);
          if (controller.cancelled) return null;

          // 头像/背景缩到安全尺寸再落库:Android SQLite CursorWindow ~2MB,
          // 大卡头像(整张几 MB PNG 的 base64)不缩会造成列表/详情读取
          // "Row too big"。PNG 卡直接用原始字节缩放,不再走整图 base64 往返;
          // 卡 JSON 自带头像时仍以 JSON 为准(与 importer 的优先级一致)。
          controller.report(message: '处理头像与背景…');
          await WidgetsBinding.instance.endOfFrame;
          var card = card0;
          final inlineAvatar = card0.avatarBase64;
          if (inlineAvatar != null && inlineAvatar.isNotEmpty) {
            final shrunk = await shrinkBase64Image(inlineAvatar);
            if (shrunk != null) card = card.replacingAvatar(shrunk);
          } else if (isPng) {
            final shrunk = await shrinkImageBytes(bytes);
            if (shrunk != null) card = card.replacingAvatar(shrunk);
          }
          final shrunkBackground = await shrinkBase64Image(
            card0.backgroundBase64,
          );
          if (shrunkBackground != null) {
            card = card.replacingBackground(shrunkBackground);
          }
          if (controller.cancelled) return null;

          controller.report(message: '写入数据库…');
          await WidgetsBinding.instance.endOfFrame;
          // Character + worldbook insert in one transaction (rollback keeps the
          // card list consistent if the worldbook write fails).
          await ref
              .read(characterRepositoryProvider)
              .insertWithWorldbook(card, entries);
          return card;
        },
      );
      if (!context.mounted) return;
      if (card == null) {
        _toast(context, '已取消导入');
        return;
      }
      ref.invalidate(charactersProvider);
      _toast(context, '已导入:${card.name}');
    } on FormatException catch (e) {
      if (!context.mounted) return;
      _toast(context, '导入失败:${e.message}');
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导入失败:$e');
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    int id,
    String name,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除角色?',
      message: '「$name」的全部会话、消息、世界书与记忆都会被删除,不可恢复。',
    );
    if (!confirmed || !context.mounted) return;
    await ref.read(characterRepositoryProvider).deleteWithCascade(id);
    ref.invalidate(charactersProvider);
  }

  /// 导出前的公共读取:分块读取让 20MB 级卡(单行超 CursorWindow)也能导出。
  /// 返回 null 表示角色卡已不存在/数据损坏,调用方给出明确提示而不是静默退出。
  Future<(CharacterCard, List<WorldbookEntry>)?> _loadForExport(
    WidgetRef ref,
    int id,
  ) async {
    final card = await ref.read(characterRepositoryProvider).get(id);
    if (card == null) return null;
    final worldbook = await ref
        .read(worldbookRepositoryProvider)
        .byCharacter(id);
    return (card, worldbook);
  }

  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    int id,
    String name,
  ) async {
    var cancelled = false;
    try {
      final bytes = await runWithProgress<Uint8List?>(
        context,
        title: '正在导出角色卡',
        task: (controller) async {
          controller.report(message: '读取角色卡…');
          await WidgetsBinding.instance.endOfFrame;
          final loaded = await _loadForExport(ref, id);
          if (loaded == null) return null;
          if (controller.cancelled) {
            cancelled = true;
            return null;
          }
          final (card, worldbook) = loaded;
          controller.report(message: '生成导出文件…');
          await WidgetsBinding.instance.endOfFrame;
          // 世界书随卡导出:以本端当前条目为准覆盖 character_book(见 exporter 注释)。
          final content = CharacterCardExporter.export(
            card,
            worldbook: worldbook,
          );
          return utf8.encoder.convert(content);
        },
      );
      if (!context.mounted) return;
      if (bytes == null) {
        _toast(
          context,
          cancelled ? '已取消导出' : '无法导出:角色卡数据读取失败',
        );
        return;
      }
      await saveBytesFile(
        context,
        fileName: '$name.json',
        bytes: bytes,
        allowedExtensions: const ['json'],
      );
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导出失败:$e');
    }
  }

  /// PNG 卡导出:头像作图片本体、卡数据嵌入文本块;无头像时导出器生成占位图。
  Future<void> _exportPng(
    BuildContext context,
    WidgetRef ref,
    int id,
    String name,
  ) async {
    var cancelled = false;
    try {
      final bytes = await runWithProgress<Uint8List?>(
        context,
        title: '正在导出 PNG',
        task: (controller) async {
          controller.report(message: '读取角色卡…');
          await WidgetsBinding.instance.endOfFrame;
          final loaded = await _loadForExport(ref, id);
          if (loaded == null) return null;
          if (controller.cancelled) {
            cancelled = true;
            return null;
          }
          final (card, worldbook) = loaded;
          controller.report(message: '生成 PNG…');
          await WidgetsBinding.instance.endOfFrame;
          return CharacterCardPngExporter.export(
            card,
            worldbook: worldbook,
          );
        },
      );
      if (!context.mounted) return;
      if (bytes == null) {
        _toast(
          context,
          cancelled ? '已取消导出' : '无法导出:角色卡数据读取失败',
        );
        return;
      }
      await saveBytesFile(
        context,
        fileName: '$name.png',
        bytes: bytes,
        allowedExtensions: const ['png'],
      );
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '导出 PNG 失败:$e');
    }
  }

  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    CharacterRecord c,
  ) async {
    final picked = await showAppActionSheet<String>(
      context,
      actions: const [
        MenuAction(value: 'edit', label: '编辑角色卡', icon: Icons.edit_outlined),
        MenuAction(value: 'worldbook', label: '世界书', icon: Icons.book_outlined),
        MenuAction(
          value: 'export',
          label: '导出角色卡(JSON)',
          icon: Icons.file_download_outlined,
        ),
        MenuAction(
          value: 'exportPng',
          label: '导出角色卡(PNG)',
          icon: Icons.image_outlined,
        ),
        MenuAction(
          value: 'delete',
          label: '删除角色',
          icon: Icons.delete_outline,
          destructive: true,
        ),
      ],
    );
    if (picked == null || !context.mounted) return;
    switch (picked) {
      case 'edit':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CharacterEditScreen(characterId: c.id),
          ),
        );
      case 'worldbook':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                WorldbookScreen(characterId: c.id, characterName: c.card.name),
          ),
        );
      case 'export':
        _export(context, ref, c.id, c.card.name);
      case 'exportPng':
        _exportPng(context, ref, c.id, c.card.name);
      case 'delete':
        _delete(context, ref, c.id, c.card.name);
    }
  }

  void _openSessions(BuildContext context, CharacterRecord c) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionsScreen(characterId: c.id, character: c.card),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final characters = ref.watch(charactersProvider);
    final grid = ref.watch(characterLayoutProvider) == CharacterLayout.grid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('角色'),
        actions: [
          IconButton(
            tooltip: grid ? '列表布局' : '图片布局',
            icon: Icon(
              grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
            ),
            onPressed: () => _toggleLayout(ref),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddMenu(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加'),
      ),
      body: characters.when(
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.person_add_alt_1_outlined,
                title: '暂无角色',
                message: '导入一张角色卡(PNG/JSON),或从零新建一个角色。',
                action: FilledButton.tonalIcon(
                  onPressed: () => _import(context, ref),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: const Text('导入角色卡'),
                ),
              )
            : Center(
                // 桌面/平板上限宽,避免卡片拉得过长。
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: SearchableList<CharacterRecord>(
                    items: list,
                    grid: grid,
                    searchHint: '搜索角色名称/描述',
                    searchText: (c) => '${c.card.name} ${c.card.description}',
                    itemBuilder: (context, c) => grid
                        ? _CharacterGridTile(
                            record: c,
                            onOpen: () => _openSessions(context, c),
                            onActions: () => _openActions(context, ref, c),
                          )
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _CharacterCardView(
                              record: c,
                              onOpen: () => _openSessions(context, c),
                              onActions: () => _openActions(context, ref, c),
                            ),
                          ),
                  ),
                ),
              ),
        error: (e, _) =>
            EmptyState(icon: Icons.error_outline, title: '加载失败', message: '$e'),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Future<void> _showAddMenu(BuildContext context, WidgetRef ref) async {
    final picked = await showAppActionSheet<String>(
      context,
      actions: const [
        MenuAction(
          value: 'import',
          label: '导入角色卡',
          icon: Icons.file_upload_outlined,
          subtitle: 'PNG(内嵌 JSON)或纯 JSON',
        ),
        MenuAction(
          value: 'create',
          label: '新建角色',
          icon: Icons.person_add_alt_1_outlined,
          subtitle: '从零填写角色设定',
        ),
      ],
    );
    if (picked == null || !context.mounted) return;
    if (picked == 'import') {
      _import(context, ref);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CharacterEditScreen()),
      );
    }
  }
}

/// 一张角色卡:顶部大预览图(头像/渐变占位)+ 名字/描述 + 操作。
class _CharacterCardView extends StatelessWidget {
  final CharacterRecord record;
  final VoidCallback onOpen;
  final VoidCallback onActions;
  const _CharacterCardView({
    required this.record,
    required this.onOpen,
    required this.onActions,
  });

  @override
  Widget build(BuildContext context) {
    final card = record.card;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 左侧竖图头像:角色立绘多为竖图,用固定 3:4 竖版裁切,不再被 16:7 宽横幅
                  // 压扁/裁掉头部。无头像时用渐变底 + 姓名首字占位。
                  SizedBox(
                    width: 96,
                    // 头像在 data_json/列里不一定带(列表投影已把大 BLOB 排除),
                    // 一律走惰性加载:有则显示,读取失败/为空回退占位。
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: _LazyAvatarPreview(
                        recordId: record.id,
                        card: card,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          card.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (card.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              card.description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '更多操作',
                    icon: const Icon(Icons.more_vert),
                    onPressed: onActions,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 图片卡面网格条目:整块立绘 + 底部渐变叠名字/描述,右上角保留操作菜单。
/// 与列表卡共用同一份记录与头像 provider,只是排版不同。
class _CharacterGridTile extends StatelessWidget {
  final CharacterRecord record;
  final VoidCallback onOpen;
  final VoidCallback onActions;
  const _CharacterGridTile({
    required this.record,
    required this.onOpen,
    required this.onActions,
  });

  @override
  Widget build(BuildContext context) {
    final card = record.card;
    final text = Theme.of(context).textTheme;
    final description = card.description.trim();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _LazyAvatarPreview(
              recordId: record.id,
              card: card,
              borderRadius: 0,
              cacheWidth: 768,
            ),
            // 底部压暗保证白字可读,上半部保持立绘原样。
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.5, 1],
                  colors: [Colors.transparent, Color(0xB3000000)],
                ),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (description.isNotEmpty)
                    Text(
                      description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: const Color(0xCCFFFFFF),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              top: 2,
              right: 2,
              child: IconButton(
                tooltip: '更多操作',
                onPressed: onActions,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0x4D000000),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.more_vert, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 角色卡列表头像预览:按 id 惰性读 base64(移动端 CursorWindow 排除了大 BLOB),
/// 拿到后按 96 逻辑宽 × ~4x 密度降采样解码(cacheWidth: 384),大图不再全分辨率
/// 解码占内存;读取失败/为空(超大历史行)回退名字首字占位,绝不再转圈。
///
/// 数据走 [characterAvatarProvider]:编辑保存后 invalidate 该 provider,
/// 复用中的列表项也会拿到新头像(此前只按 id 重载,换头像要重导入才生效)。
class _LazyAvatarPreview extends ConsumerWidget {
  final int recordId;
  final CharacterCard card;

  /// 圆角/解码宽度按用途可调:列表缩略图 96 宽(384 解码即 ~4x 密度),
  /// 网格卡面更大,交给调用方放大解码宽度。
  final double borderRadius;
  final int cacheWidth;
  const _LazyAvatarPreview({
    required this.recordId,
    required this.card,
    this.borderRadius = 8,
    this.cacheWidth = 384,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = ref.watch(characterAvatarProvider(recordId));
    final bytes = avatar.value;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.memory(
          bytes,
          cacheWidth: cacheWidth,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorBuilder: (_, __, ___) => _placeholder(context, scheme, card),
        ),
      );
    }
    if (avatar.isLoading) {
      // 加载中:灰底占位,避免还没读到就闪字。
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(color: scheme.surfaceContainerHighest),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: _placeholder(context, scheme, card),
    );
  }

  Widget _placeholder(
    BuildContext context,
    ColorScheme scheme,
    CharacterCard card,
  ) {
    final initial = card.name.isEmpty ? '?' : card.name.characters.first;
    return Container(
      color: scheme.secondaryContainer.withValues(alpha: 0.55),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: Theme.of(context).textTheme.displayLarge?.copyWith(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
