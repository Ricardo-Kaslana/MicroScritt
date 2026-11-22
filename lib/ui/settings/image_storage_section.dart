/// 图片文件资产与数据库的存储统计、手动整理、按会话构成。
///
/// 只治理内容寻址资产、预览与已并入资产库的远程图片;URL-only 图片尚未
/// 资产化时仍可能落在 `DiskImageCache`,其容量与 LRU 语义不在这里改变。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/image_asset_store.dart';
import '../../state/providers.dart';
import '../common/app_snack_bar.dart';
import '../common/byte_size.dart';
import '../common/form_row.dart';
import '../common/info_button.dart';
import '../common/inline_spinner.dart';
import '../common/section_header.dart';
import 'image_storage_help.dart';
import 'session_image_usage_dialog.dart';
import 'settings_workspace.dart';

/// 设置页共享存储区块;[wide] 时使用桌面 SurfaceCard 与响应式双列指标。
class ImageStorageSection extends ConsumerStatefulWidget {
  final bool wide;

  const ImageStorageSection({super.key, this.wide = false});

  @override
  ConsumerState<ImageStorageSection> createState() =>
      _ImageStorageSectionState();
}

class _ImageStorageSectionState extends ConsumerState<ImageStorageSection> {
  ImageAssetStorageStats? _stats;
  bool _loading = true;
  bool _organizing = false;
  bool _savingCompress = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStats());
  }

  Future<void> _loadStats() async {
    final db = ref.read(databaseProvider);
    try {
      final stats = await db.images.storageStats(databasePath: db.db.path);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  Future<void> _retryLoad() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    await _loadStats();
  }

  Future<void> _organize() async {
    if (_organizing) return;
    setState(() => _organizing = true);
    final db = ref.read(databaseProvider);
    try {
      final result = await db.images.organizeStorage();
      final stats = await db.images.storageStats(databasePath: db.db.path);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loadError = null;
        _organizing = false;
      });
      showAppSnack(
        context,
        '存储整理完成:回收 ${result.reclaimedAssets} 项资产,'
        '清理 ${result.removedTempFiles} 个临时文件与 '
        '${result.removedPreviews} 个预览',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _organizing = false);
      showAppSnack(context, '存储整理失败:$e');
    }
  }

  /// 保存“压缩新图片”开关;写库成功后才更新内存设置。
  Future<void> _setCompress(bool value) async {
    if (_savingCompress) return;
    setState(() => _savingCompress = true);
    final current = ref.read(appSettingsProvider);
    final updated = current.copyWith(compressImages: value);
    try {
      await ref.read(appSettingsRepositoryProvider).save(updated);
      ref.read(appSettingsProvider.notifier).state = updated;
      if (!mounted) return;
      setState(() => _savingCompress = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingCompress = false);
      showAppSnack(context, '保存图片压缩设置失败:$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.wide ? _buildWide(context) : _buildMobile(context);
  }

  /// 移动端:iOS 分组卡只承载统计与开关,四条指标各自成行以获得 hairline
  /// 分隔;说明入口并入开关标题,操作按钮按设置页其他区块的惯例整宽堆叠在
  /// 卡外 —— 避免右对齐换行与指标、开关、按钮三种右缘。
  Widget _buildMobile(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupCard(
          children: [
            ..._buildMobileStatusRows(context),
            _buildMobileCompressSwitch(context, horizontalPadding: 14),
          ],
        ),
        const SizedBox(height: 12),
        _buildSessionUsageButton(),
        const SizedBox(height: 8),
        _buildOrganizeButton(),
      ],
    );
  }

  /// 桌面端:拆成「存储构成」与「整理与压缩」两张卡,使用桌面工作区的
  /// SettingsCardTitle / SettingsFormRow 语言,而不是把移动端行式控件拉宽。
  Widget _buildWide(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SurfaceCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SettingsCardTitle(
                icon: Icons.storage_outlined,
                title: '存储构成',
              ),
              const SizedBox(height: 10),
              _buildWideStatus(context),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 2),
                child: SettingsCardTitle(
                  icon: Icons.cleaning_services_outlined,
                  title: '整理与压缩',
                ),
              ),
              SettingsSwitchRow(
                switchKey: const ValueKey('image_compress_switch'),
                icon: Icons.compress_outlined,
                title: '压缩新图片',
                description: '长边超过 2048px 的新图片入库前压缩',
                titleTrailing: InfoButton(
                  key: const ValueKey('image_storage_help'),
                  onTap: () => showImageStorageHelp(context),
                ),
                value: ref.watch(appSettingsProvider).compressImages,
                onChanged: _organizing || _savingCompress ? null : _setCompress,
              ),
              const SettingsFormDivider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildSessionUsageButton(),
                      _buildOrganizeButton(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildMobileStatusRows(BuildContext context) {
    final stats = _stats;
    if (stats != null) {
      return _buildMetricRows(stats, horizontalPadding: 14);
    }
    return [_buildStatusTile(context, horizontalPadding: 14)];
  }

  Widget _buildWideStatus(BuildContext context) {
    final stats = _stats;
    if (stats != null) {
      return SettingsResponsiveColumns(
        breakpoint: 700,
        gap: 12,
        children: [
          _WideStorageMetric(
            icon: Icons.storage_outlined,
            title: '数据库',
            value: formatByteSize(stats.databaseBytes),
          ),
          _WideStorageMetric(
            icon: Icons.image_outlined,
            title: '原图',
            subtitle: '${stats.assetCount} 项资产',
            value: formatByteSize(stats.originalBytes),
          ),
          _WideStorageMetric(
            icon: Icons.photo_size_select_large_outlined,
            title: '预览',
            subtitle: '可重建缓存',
            value: formatByteSize(stats.previewBytes),
          ),
          _WideStorageMetric(
            icon: Icons.delete_outline,
            title: '待回收',
            subtitle: '已过 24 小时宽限期',
            value: formatByteSize(stats.reclaimableBytes),
          ),
        ],
      );
    }
    return _buildStatusTile(context, horizontalPadding: 0);
  }

  /// 统计读取中的占位行或失败行;失败时保留重试入口并限制错误文案行数,
  /// 避免长异常串把卡片撑高。
  Widget _buildStatusTile(
    BuildContext context, {
    required double horizontalPadding,
  }) {
    final padding = EdgeInsets.symmetric(horizontal: horizontalPadding);
    if (_loading) {
      return ListTile(
        contentPadding: padding,
        leading: const InlineSpinner(size: 20),
        title: const Text('正在统计存储…'),
      );
    }
    return ListTile(
      contentPadding: padding,
      leading: Icon(
        Icons.error_outline,
        color: Theme.of(context).colorScheme.error,
      ),
      title: const Text('无法读取存储统计'),
      subtitle: _loadError == null
          ? null
          : Text(_loadError!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: TextButton(onPressed: _retryLoad, child: const Text('重试')),
    );
  }

  /// 移动端指标行直接铺进 GroupCard 以获得行间分隔线;副标题只保留一行
  /// 关键信息,256 MiB 淘汰与 24 小时宽限期的细节收进说明弹窗。
  List<Widget> _buildMetricRows(
    ImageAssetStorageStats stats, {
    required double horizontalPadding,
  }) {
    return [
      _StorageMetric(
        icon: Icons.storage_outlined,
        title: '数据库',
        value: formatByteSize(stats.databaseBytes),
        horizontalPadding: horizontalPadding,
      ),
      _StorageMetric(
        icon: Icons.image_outlined,
        title: '原图',
        subtitle: '${stats.assetCount} 项资产',
        value: formatByteSize(stats.originalBytes),
        horizontalPadding: horizontalPadding,
      ),
      _StorageMetric(
        icon: Icons.photo_size_select_large_outlined,
        title: '预览',
        subtitle: '可重建缓存',
        value: formatByteSize(stats.previewBytes),
        horizontalPadding: horizontalPadding,
      ),
      _StorageMetric(
        icon: Icons.delete_outline,
        title: '待回收',
        subtitle: '已过 24 小时宽限期',
        value: formatByteSize(stats.reclaimableBytes),
        horizontalPadding: horizontalPadding,
      ),
    ];
  }

  Widget _buildMobileCompressSwitch(
    BuildContext context, {
    required double horizontalPadding,
  }) {
    return SettingsSwitchTile(
      switchTileKey: const ValueKey('image_compress_switch'),
      contentPadding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      icon: Icons.compress_outlined,
      title: '压缩新图片',
      titleTrailing: InfoButton(
        key: const ValueKey('image_storage_help'),
        onTap: () => showImageStorageHelp(context),
      ),
      description: '长边超过 2048px 的新图片入库前压缩',
      value: ref.watch(appSettingsProvider).compressImages,
      onChanged: _organizing || _savingCompress ? null : _setCompress,
    );
  }

  Widget _buildSessionUsageButton() {
    return OutlinedButton.icon(
      key: const ValueKey('image_storage_session_usage'),
      onPressed: _organizing
          ? null
          : () => showSessionImageUsageDialog(context),
      icon: const Icon(Icons.forum_outlined),
      label: const Text('按会话查看'),
    );
  }

  Widget _buildOrganizeButton() {
    return FilledButton.icon(
      key: const ValueKey('image_storage_organize'),
      onPressed: _organizing || _loading ? null : _organize,
      icon: _organizing
          ? const InlineSpinner()
          : const Icon(Icons.cleaning_services_outlined),
      label: Text(_organizing ? '正在整理…' : '整理存储'),
    );
  }
}

class _StorageMetric extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String value;
  final double horizontalPadding;

  const _StorageMetric({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    this.horizontalPadding = 4,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 桌面统计磁贴:图标片 + 标题/说明 + 右缘字节数,与 SettingsLinkCard 的
/// 图标容器同调;两列排布交给 [SettingsResponsiveColumns]。
class _WideStorageMetric extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String value;

  const _WideStorageMetric({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
