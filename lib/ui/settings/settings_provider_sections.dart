/// 设置页的 LLM / 生图服务列表:移动页与桌面工作台共用。
///
/// 两个列表组件默认自带「添加」按钮与生图管理入口;桌面把动作收进工作区
/// 头部与入口卡时,用开关隐藏底部按钮,避免同一动作出现两次。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/image_config.dart';
import '../../models/image_style_preset.dart';
import '../../models/llm_provider.dart';
import '../../state/app_config_sync.dart';
import '../../state/providers.dart';
import '../common/async_section.dart';
import '../common/confirm_dialog.dart';
import '../common/empty_state.dart';
import '../common/section_header.dart';
import '../image_plugins_screen.dart';
import '../image_provider_edit_screen.dart';
import '../image_styles_screen.dart';
import '../provider_edit_screen.dart';

/// LLM 后端设置:按 provider 分组的配置列表。
///
/// 列表只显示名称;删除当前在用 provider 后重解析运行时配置并回写文本
/// 配置文件,避免运行链路继续指向已删除的 provider。
class LlmProviderSection extends ConsumerWidget {
  final bool showAddButton;

  const LlmProviderSection({super.key, this.showAddButton = true});

  Future<void> _deleteProvider(
    BuildContext context,
    WidgetRef ref,
    LlmProviderConfig p,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除 Provider?',
      message: '「${p.displayName}」及其全部模型都会被删除。',
    );
    if (!confirmed || !context.mounted) return;
    await markAppConfigDirty(ref);
    final wasActive = p.isActive;
    await ref.read(llmProviderRepositoryProvider).deleteProvider(p.id);
    if (wasActive) {
      // 删除当前在用 provider 后,重新解析可用的当前配置。
      final backend = await ref
          .read(llmProviderRepositoryProvider)
          .loadBackendConfig();
      ref.read(backendConfigProvider.notifier).state = backend;
    }
    ref.invalidate(llmProvidersProvider);
    await syncAppConfigFile(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(llmProvidersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AsyncSection<List<LlmProviderConfig>>(
          value: providersAsync,
          onRetry: () => ref.invalidate(llmProvidersProvider),
          builder: (context, providers) {
            if (providers.isEmpty) {
              return const SurfaceCard(
                child: EmptyState(
                  compact: true,
                  icon: Icons.dns_outlined,
                  title: '暂无 LLM Provider',
                  message: '还没有配置任何 LLM provider,点击"添加 Provider"开始。',
                ),
              );
            }
            return Column(
              children: [
                for (final (i, p) in providers.indexed) ...[
                  _ProviderTile(
                    provider: p,
                    onEdit: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProviderEditScreen(existing: p),
                      ),
                    ).then((_) => ref.invalidate(llmProvidersProvider)),
                    onDelete: () => _deleteProvider(context, ref, p),
                  ),
                  if (i != providers.length - 1) const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
        if (showAddButton) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProviderEditScreen()),
            ).then((_) => ref.invalidate(llmProvidersProvider)),
            icon: const Icon(Icons.add),
            label: const Text('添加 Provider'),
          ),
        ],
      ],
    );
  }
}

class _ProviderTile extends ConsumerWidget {
  final LlmProviderConfig provider;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _ProviderTile({
    required this.provider,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: onEdit,
        leading: Icon(Icons.dns_outlined, color: scheme.onSurfaceVariant),
        title: Text(provider.displayName),
        // 只显示 provider 名称;详情(协议/地址/模型个数)进了编辑页。
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 生图配置列表(多行 `image_providers`):每行一套完整配置,**各自带 api_key**。
///
/// 与上方 [LlmProviderSection] 同一套交互 —— 列表只显示名称与服务/在用状态,参数
/// 细节进编辑页。「设为当前使用」决定 `imageConfigProvider` 水合哪一套,而运行
/// 链路(编排器 / 后台引擎)只读它。
class ImageProviderSection extends ConsumerWidget {
  final bool showAddButton;
  final bool showManageButtons;

  const ImageProviderSection({
    super.key,
    this.showAddButton = true,
    this.showManageButtons = true,
  });

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    ImageProviderRecord p,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除生图配置?',
      message: '「${p.displayName}」及其连接参数都会被删除。',
    );
    if (!confirmed || !context.mounted) return;
    await markAppConfigDirty(ref);
    final repo = ref.read(imageConfigRepositoryProvider);
    await repo.deleteProvider(p.id);
    // 删掉的若是当前在用那套,repository 会顺位补一条为活跃 —— 重解析让运行
    // 链路立刻跟上,否则 `imageConfigProvider` 还指向已删除的配置。
    ref.read(imageConfigProvider.notifier).state = await repo
        .loadActiveConfig();
    ref.invalidate(imageProvidersProvider);
    await syncAppConfigFile(ref);
  }

  Future<void> _setActive(WidgetRef ref, ImageProviderRecord p) async {
    await markAppConfigDirty(ref);
    final repo = ref.read(imageConfigRepositoryProvider);
    await repo.setActive(p.id);
    ref.read(imageConfigProvider.notifier).state = await repo
        .loadActiveConfig();
    ref.invalidate(imageProvidersProvider);
    await syncAppConfigFile(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providersAsync = ref.watch(imageProvidersProvider);
    final activeConfig = ref.watch(imageConfigProvider);
    // 新建自定义风格时用当前生效参数预填;未配置生图时给空初值。
    final stylePrefill = stylePrefillFromConfig(activeConfig);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AsyncSection<List<ImageProviderRecord>>(
          value: providersAsync,
          onRetry: () => ref.invalidate(imageProvidersProvider),
          builder: (context, providers) {
            if (providers.isEmpty) {
              return const SurfaceCard(
                child: EmptyState(
                  compact: true,
                  icon: Icons.image_outlined,
                  title: '暂无生图服务',
                  message: '还没有配置生图服务,点击"添加生图配置"开始。',
                ),
              );
            }
            return Column(
              children: [
                for (final (i, p) in providers.indexed) ...[
                  _ImageProviderTile(
                    record: p,
                    onEdit: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ImageProviderEditScreen(existing: p),
                      ),
                    ).then((_) => ref.invalidate(imageProvidersProvider)),
                    onDelete: () => _delete(context, ref, p),
                    onSetActive: () => _setActive(ref, p),
                  ),
                  if (i != providers.length - 1) const SizedBox(height: 8),
                ],
              ],
            );
          },
        ),
        if (showAddButton) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const ImageProviderEditScreen(),
              ),
            ).then((_) => ref.invalidate(imageProvidersProvider)),
            icon: const Icon(Icons.add),
            label: const Text('添加生图配置'),
          ),
        ],
        if (showManageButtons) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ImagePluginsScreen()),
            ),
            icon: const Icon(Icons.extension_outlined),
            label: const Text('管理生图插件'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            // 风格此前只能从生图配置编辑页底部进入;设置页给出直达入口。
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ImageStylesScreen(prefill: stylePrefill),
              ),
            ),
            icon: const Icon(Icons.palette_outlined),
            label: const Text('管理自定义风格'),
          ),
        ],
      ],
    );
  }
}

/// 用当前生效的生图参数预填自定义风格;未配置生图时给空初值。
ImageStylePreset stylePrefillFromConfig(ImageConfig? config) =>
    ImageStylePreset(
      name: '',
      artist: config?.artist,
      sampler: config?.sampler,
      noiseSchedule: config?.noiseSchedule,
      scale: config?.scale,
      cfg: config?.cfg,
      negative: config?.negative,
    );

class _ImageProviderTile extends ConsumerWidget {
  final ImageProviderRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSetActive;
  const _ImageProviderTile({
    required this.record,
    required this.onEdit,
    required this.onDelete,
    required this.onSetActive,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final plugins = ref.watch(imagePluginsProvider);
    final service =
        plugins
            .where((plugin) => plugin.id == record.config.pluginId)
            .firstOrNull
            ?.name ??
        '生图插件';
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        onTap: onEdit,
        leading: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
        title: Text(record.displayName),
        // 副标题只报插件与"是否在用";密钥/地址/模型等细节进编辑页。
        subtitle: Text(
          record.isActive ? '$service · 当前使用' : service,
          style: TextStyle(
            color: record.isActive ? scheme.primary : scheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!record.isActive)
              IconButton(
                icon: const Icon(Icons.radio_button_unchecked),
                tooltip: '设为当前使用',
                onPressed: onSetActive,
              ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
