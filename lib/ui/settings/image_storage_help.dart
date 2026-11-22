/// 「图片与存储」的整理与压缩说明弹窗。
///
/// 设置区块只保留统计指标、开关和操作按钮;长文案集中到此处,避免窄屏
/// 设置页被大段说明占满。
library;

import 'package:flutter/material.dart';

/// 打开图片存储说明。
Future<void> showImageStorageHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const ImageStorageHelpDialog(),
  );
}

/// 整理与压缩的完整说明。
class ImageStorageHelpDialog extends StatelessWidget {
  const ImageStorageHelpDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('image_storage_help_dialog'),
      title: const Text('图片与存储说明'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '统计',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '数据库为本地 SQLite 文件大小；原图按内容寻址去重，同一张图只计'
                '一次；预览是可重建缓存，超过 256 MiB 会按最后使用时间自动淘汰'
                '最旧文件；待回收统计已过 24 小时宽限期、当前无人引用的原图。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '整理',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '回收到期零引用原图、清理临时文件与全部预览，并执行数据库 '
                'VACUUM。预览只作缓存，删除后按需重建；有引用的原图不会删除。'
                '远程图片首次显示时会并入资产库，之后不再依赖 URL。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '压缩',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '开启后，长边超过 2048px 的新图片在入库前压缩。GIF 保留动画，'
                '透明图保持 PNG；压缩后反而更大时保留原图。只影响之后入库的'
                '图片，已有原图不会回溯；归档导入与按哈希修复会绕过压缩，'
                '保证内容寻址一致。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}
