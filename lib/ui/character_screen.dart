/// 角色列表首屏:导入/新建入口、列表/图片/牌堆三种布局、角色操作菜单。
///
/// 头像经 `characterAvatarProvider` 按 id 惰性读取并降采样解码,大卡头像
/// 不随列表行加载(Android CursorWindow 上限);导入/导出都带阶段进度,
/// 取消即中止且不写库。
library;

import 'dart:async';
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
import '../state/card_studio_draft_assets.dart';
import '../state/providers.dart';
import '../state/ui_prefs_sync.dart';
import 'card_studio/card_studio_screen.dart';
import 'character_edit_screen.dart';
import 'common/app_menu.dart';
import 'common/app_snack_bar.dart';
import 'common/async_section.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/export_helper.dart';
import 'common/pick_file_bytes.dart';
import 'common/progress_task.dart';
import 'common/searchable_list.dart';
import 'common/section_header.dart';
import '../data/image_asset_input.dart';
import 'sessions_screen.dart';
import 'settings_screen.dart';
import 'widgets/character_avatar_preview.dart';
import 'widgets/character_deck.dart';
import 'worldbook_screen.dart';

/// 角色卡导出/分享的文件形态:纯 JSON,或内嵌卡数据的 PNG 图片。
enum _CardFileFormat { json, png }

/// 角色卡管理:首屏(`home`),列表/图片/牌堆三种布局,点击进入会话列表;
/// 右上角进入设置页,底部「添加」提供导入 PNG/JSON 与新建角色。
///
/// 布局偏好写入独立的 `ui-prefs.json`,写失败只打日志,不回滚本次切换。
class CharacterScreen extends ConsumerWidget {
  const CharacterScreen({super.key});

  /// 切换布局:先更新内存状态(立即生效),再整体回写偏好文件
  /// (`ui-prefs.json`,写失败只打日志,不影响本次切换)。布局从三态盲循环
  /// 改为菜单直选,当前项带勾选标记,不必连点猜下一个是什么。
  Future<void> _setLayout(WidgetRef ref, CharacterLayout next) async {
    if (ref.read(characterLayoutProvider) == next) return;
    ref.read(characterLayoutProvider.notifier).state = next;
    await syncUiPrefsFile(ref);
  }

  /// 牌堆翻到新正面卡:进度先在内存生效,再异步回写偏好文件。
  void _onDeckFrontChanged(WidgetRef ref, int id) {
    ref.read(deckFrontCharacterIdProvider.notifier).state = id;
    unawaited(syncUiPrefsFile(ref));
  }

  void _toast(BuildContext context, String message) =>
      showAppSnack(context, message);

  static String _readLabel(int read, int total) {
    if (total <= 0) return '读取文件…';
    const mb = 1024 * 1024;
    final readMb = (read / mb).toStringAsFixed(1);
    final totalMb = (total / mb).toStringAsFixed(1);
    return '读取文件 $readMb / $totalMb MB';
  }

  /// 导入角色卡(带内嵌 JSON 的 PNG 或纯 JSON),分阶段进度覆盖读取、解析与
  /// 缩图;头像/背景缩到安全尺寸后与世界书在同一事务写入。失败或取消都不
  /// 留下半截角色/世界书。
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    // withData: false —— Android 端 file_picker 会把大文件整读进原生 ByteArray,
    // OOM 后静默丢掉字节(桌面不受影响,这就是"大卡只有移动端导入失败"的根因之一);
    // 这里一律从选择结果的 path 读,Dart 堆不占原生配额,大文件也稳。
    try {
      final result = await FilePicker.pickFiles(withData: false);
      // 系统文件选择器的返回键是标准取消路径,取消不是失败。
      if (result == null) {
        if (context.mounted) _toast(context, '已取消导入');
        return;
      }
      final picked = result.files.single;
      if (!context.mounted) return;
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

          // base64 只在外部卡协议边界出现;PNG 原字节与内嵌头像都先缩图,
          // 再写入内容寻址资产库。卡 JSON 自带头像时优先于 PNG 图片本体。
          controller.report(message: '处理头像与背景…');
          await WidgetsBinding.instance.endOfFrame;
          final db = ref.read(databaseProvider);
          final inlineAvatar = card0.importedAvatarBase64;
          final avatarHash = inlineAvatar != null && inlineAvatar.isNotEmpty
              ? await assetizeBase64Image(db, inlineAvatar)
              : isPng
              ? await assetizeImageBytes(db, bytes)
              : null;
          final card = card0.replacingAvatar(avatarHash);
          if (controller.cancelled) return null;

          controller.report(message: '写入数据库…');
          await WidgetsBinding.instance.endOfFrame;
          // 角色与世界书在同一事务内写入:世界书写失败时整体回滚,列表不会
          // 出现「有卡没书」的半截状态。
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
      // 侧栏分组直接读角色仓库,不随 charactersProvider 联动,需显式失效。
      ref.invalidate(sessionGroupsProvider);
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
    // 角色已删,孤立提案不再保留;只有文件清理成功后才释放草稿图片引用。
    final draftFile = ref.read(cardStudioDraftFileProvider);
    if (draftFile != null) {
      await clearCardStudioDraftAndRelease(
        ref.read(databaseProvider),
        draftFile,
        id,
      );
    }
    ref.invalidate(charactersProvider);
    ref.invalidate(sessionGroupsProvider);
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

  /// 选择导出/分享的文件形态:纯 JSON 或内嵌卡数据的 PNG。
  Future<_CardFileFormat?> _chooseCardFormat(BuildContext context) {
    return showAppActionSheet<_CardFileFormat>(
      context,
      actions: const [
        MenuAction(
          value: _CardFileFormat.json,
          label: 'JSON',
          subtitle: '纯文本角色卡,世界书随卡导出',
          icon: Icons.code_outlined,
        ),
        MenuAction(
          value: _CardFileFormat.png,
          label: 'PNG',
          subtitle: '头像作图片本体,卡数据嵌入图片',
          icon: Icons.image_outlined,
        ),
      ],
    );
  }

  /// 导出/分享角色卡:JSON 为纯文本卡,PNG 以头像为图片本体并内嵌卡数据;
  /// 世界书都以本端当前条目为准覆盖 `character_book`。读取失败给出明确提示,
  /// 不生成空文件。
  Future<void> _exportCard(
    BuildContext context,
    WidgetRef ref,
    int id,
    String name,
    _CardFileFormat format, {
    bool share = false,
  }) async {
    final isPng = format == _CardFileFormat.png;
    var cancelled = false;
    try {
      final bytes = await runWithProgress<Uint8List?>(
        context,
        title: isPng ? '正在生成 PNG 角色卡' : '正在导出角色卡',
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
          String? avatarBase64;
          final avatarHash = card.avatarHash;
          if (avatarHash != null) {
            try {
              final avatarBytes = await ref
                  .read(databaseProvider)
                  .images
                  .fileFor(avatarHash)
                  .readAsBytes();
              avatarBase64 = base64Encode(avatarBytes);
            } catch (_) {
              // 原图缺失时 JSON 仍导出卡面;PNG 导出使用名字占位图。
            }
          }
          controller.report(message: isPng ? '生成 PNG…' : '生成导出文件…');
          await WidgetsBinding.instance.endOfFrame;
          // 只有文件导出边界把资产字节还原为外部协议 base64。
          return isPng
              ? CharacterCardPngExporter.export(
                  card,
                  worldbook: worldbook,
                  avatarBase64: avatarBase64,
                )
              : utf8.encoder.convert(
                  CharacterCardExporter.export(
                    card,
                    worldbook: worldbook,
                    avatarBase64: avatarBase64,
                  ),
                );
        },
      );
      if (!context.mounted) return;
      if (bytes == null) {
        _toast(context, cancelled ? '已取消导出' : '无法导出:角色卡数据读取失败');
        return;
      }
      final fileName = isPng ? '$name.png' : '$name.json';
      if (share) {
        await shareBytesFile(
          context,
          fileName: fileName,
          bytes: bytes,
          mimeType: isPng ? 'image/png' : 'application/json',
        );
      } else {
        await saveBytesFile(
          context,
          fileName: fileName,
          bytes: bytes,
          allowedExtensions: [isPng ? 'png' : 'json'],
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, share ? '分享失败:$e' : '导出失败:$e');
    }
  }

  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    CharacterRecord c,
  ) async {
    final picked = await showAppActionSheet<String>(
      context,
      actions: [
        const MenuAction(
          value: 'edit',
          label: '编辑角色卡',
          icon: Icons.edit_outlined,
        ),
        const MenuAction(
          value: 'ai',
          label: 'AI 优化角色卡',
          icon: Icons.auto_awesome_outlined,
        ),
        const MenuAction(
          value: 'worldbook',
          label: '世界书管理',
          icon: Icons.book_outlined,
        ),
        const MenuAction(
          value: 'export',
          label: '导出角色卡',
          icon: Icons.file_download_outlined,
        ),
        if (isMobileShareAvailable)
          const MenuAction(
            value: 'share',
            label: '分享角色卡',
            icon: Icons.share_outlined,
          ),
        const MenuAction(
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
      case 'ai':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CardStudioScreen(characterId: c.id),
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
        {
          final format = await _chooseCardFormat(context);
          if (format != null && context.mounted) {
            await _exportCard(context, ref, c.id, c.card.name, format);
          }
        }
      case 'share':
        {
          final format = await _chooseCardFormat(context);
          if (format != null && context.mounted) {
            await _exportCard(
              context,
              ref,
              c.id,
              c.card.name,
              format,
              share: true,
            );
          }
        }
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
    final layout = ref.watch(characterLayoutProvider);
    final grid = layout == CharacterLayout.grid;
    return Scaffold(
      // 牌堆的卡面尺寸由可用高度推导,键盘弹起时若 body 随之收缩,弹起
      // 动画的每一帧都会重算卡宽,整副牌被持续缩放挤压。牌堆没有滚动
      // 视图、检索框又固定在页面顶部,让键盘直接覆盖底部即可(点空白处
      // 或按搜索键收起键盘);列表/网格仍保留默认的让位行为。
      resizeToAvoidBottomInset: layout != CharacterLayout.deck,
      appBar: AppBar(
        title: const Text('角色'),
        actions: [
          PopupMenuButton<CharacterLayout>(
            tooltip: '切换布局',
            icon: Icon(switch (layout) {
              CharacterLayout.list => Icons.view_list_rounded,
              CharacterLayout.grid => Icons.grid_view_rounded,
              CharacterLayout.deck => Icons.style_rounded,
            }),
            onSelected: (next) => _setLayout(ref, next),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: CharacterLayout.list,
                checked: layout == CharacterLayout.list,
                child: const Text('列表布局'),
              ),
              CheckedPopupMenuItem(
                value: CharacterLayout.grid,
                checked: layout == CharacterLayout.grid,
                child: const Text('图片布局'),
              ),
              CheckedPopupMenuItem(
                value: CharacterLayout.deck,
                checked: layout == CharacterLayout.deck,
                child: const Text('牌堆布局'),
              ),
            ],
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
      body: AsyncSection<List<CharacterRecord>>(
        value: characters,
        compact: false,
        onRetry: () {
          ref.invalidate(charactersProvider);
          ref.invalidate(sessionGroupsProvider);
        },
        builder: (context, list) => list.isEmpty
            ? EmptyState(
                icon: Icons.person_add_alt_1_outlined,
                title: '暂无角色',
                message: '导入一张角色卡(PNG/JSON),或从零新建一个角色。',
                // 空态与右下角「添加」菜单给同一组入口:导入与新建都是
                // 首次使用的正常路径,不让用户只能先猜 FAB。
                action: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => _import(context, ref),
                      child: const Text('导入'),
                    ),
                    FilledButton.tonal(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const CharacterEditScreen(),
                        ),
                      ),
                      child: const Text('新建'),
                    ),
                  ],
                ),
              )
            : Center(
                // 桌面/平板上限宽,避免卡片拉得过长。
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: SearchableList<CharacterRecord>(
                    items: list,
                    grid: grid,
                    deckBuilder: layout == CharacterLayout.deck
                        ? (context, items) => CharacterDeckView(
                            records: items,
                            initialFrontId: ref.read(
                              deckFrontCharacterIdProvider,
                            ),
                            onFrontChanged: (id) =>
                                _onDeckFrontChanged(ref, id),
                            onOpen: (c) => _openSessions(context, c),
                            onActions: (c) => _openActions(context, ref, c),
                          )
                        : null,
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
      ),
    );
  }

  Future<void> _showAddMenu(BuildContext context, WidgetRef ref) async {
    final picked = await showAppActionSheet<String>(
      context,
      actions: const [
        MenuAction(
          value: 'ai',
          label: 'AI 制卡',
          icon: Icons.auto_awesome,
          subtitle: '描述想法，自动生成角色卡、世界书与头像',
        ),
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
    switch (picked) {
      case 'ai':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CardStudioScreen()),
        );
      case 'import':
        _import(context, ref);
      case 'create':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CharacterEditScreen()),
        );
    }
  }
}

/// 一张角色卡:左侧竖版头像(惰性加载/渐变占位)+ 名字/描述 + 操作菜单。
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
    return SurfaceCard(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: EdgeInsets.zero,
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
                    child: CharacterAvatarPreview(
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
            CharacterAvatarPreview(
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
                icon: const Icon(Icons.more_vert, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
