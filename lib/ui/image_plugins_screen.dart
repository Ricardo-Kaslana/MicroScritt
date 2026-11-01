import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/image_plugin.dart';
import '../state/providers.dart';
import 'common/confirm_dialog.dart';
import 'common/empty_state.dart';
import 'common/pick_file_bytes.dart';
import 'common/section_header.dart';

class ImagePluginsScreen extends ConsumerStatefulWidget {
  const ImagePluginsScreen({super.key});

  @override
  ConsumerState<ImagePluginsScreen> createState() => _ImagePluginsScreenState();
}

class _ImagePluginsScreenState extends ConsumerState<ImagePluginsScreen> {
  bool _importing = false;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _refresh() async {
    final repository = ref.read(imagePluginRepositoryProvider);
    final catalog = ref.read(imagePluginsProvider.notifier);
    final plugins = await repository.all();
    catalog.state = plugins;
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null) return;
      final bytes = await pickedFileBytes(result.files.single);
      if (bytes == null) {
        _snack('导入失败：未读取到所选文件');
        return;
      }
      if (bytes.length > kMaxImagePluginPackageBytes) {
        throw const FormatException('插件文件过大(上限 1MB)');
      }
      var source = utf8.decode(bytes);
      if (source.startsWith('\ufeff')) source = source.substring(1);
      var plugin = ImagePlugin.fromPackageJson(source);
      final existing = ref
          .read(imagePluginsProvider)
          .where((item) => item.id == plugin.id)
          .firstOrNull;
      if (!mounted) return;
      if (!await _confirmImport(plugin, replacing: existing != null)) return;
      final runtime = ref.read(hookRuntimeProvider);
      if (runtime == null) throw const FormatException('当前平台无法运行 JS 生图插件');
      final valid = await runtime.evaluate('''
(function() {
${plugin.code}
  return typeof step === "function" ? "ok" : "missing";
})()
''');
      if (valid != 'ok') {
        throw const FormatException('插件 JS 无效，或未定义同步 step(ctx) 函数');
      }
      plugin = plugin.copyWith(enabled: existing?.enabled ?? true);
      await ref.read(imagePluginRepositoryProvider).save(plugin);
      await _refresh();
      _snack(
        existing == null ? '已导入插件「${plugin.name}」' : '已更新插件「${plugin.name}」',
      );
    } on FormatException catch (error) {
      _snack('导入失败：${error.message}');
    } catch (error) {
      _snack('导入失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<bool> _confirmImport(
    ImagePlugin plugin, {
    required bool replacing,
  }) async {
    final permissions = plugin.permissions;
    final endpoint = permissions.endpointSetting;
    final origins = <String>[
      ...permissions.allowedOrigins,
      if (endpoint != null) '用户在「$endpoint」中配置的服务 origin',
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(replacing ? '更新生图插件？' : '导入生图插件？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${plugin.name} · ${plugin.version}'),
            const SizedBox(height: 4),
            Text(plugin.id, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(
              origins.isEmpty ? '该插件未声明联网权限。' : '允许联网到：\n${origins.join('\n')}',
            ),
            const SizedBox(height: 8),
            const Text('仅导入你信任的插件；脚本可读取该插件配置中的密钥。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(replacing ? '更新' : '导入'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _toggle(ImagePlugin plugin) async {
    await ref
        .read(imagePluginRepositoryProvider)
        .setEnabled(plugin.id, !plugin.enabled);
    await _refresh();
  }

  Future<void> _delete(ImagePlugin plugin) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除生图插件？',
      message: '${plugin.name}\n${plugin.id}',
    );
    if (!confirmed) return;
    try {
      await ref.read(imagePluginRepositoryProvider).delete(plugin.id);
      await _refresh();
      _snack('已删除插件「${plugin.name}」');
    } on StateError catch (error) {
      _snack(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugins = ref.watch(imagePluginsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('生图插件')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _import,
        icon: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.file_open_outlined),
        label: Text(_importing ? '导入中' : '导入 JSON'),
      ),
      body: plugins.isEmpty
          ? const EmptyState(
              icon: Icons.extension_outlined,
              title: '暂无生图插件',
              message:
                  '导入 JSON 插件后，即可在生图配置中选择它。插件通过受限的 Dart 网络宿主接入 HTTP(S) 服务。',
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              itemCount: plugins.length,
              itemBuilder: (context, index) {
                final plugin = plugins[index];
                return GroupCard(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.extension_outlined),
                      title: Text(plugin.name),
                      subtitle: Text('${plugin.version} · ${plugin.id}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(plugin),
                          ),
                          Switch(
                            value: plugin.enabled,
                            onChanged: (_) => _toggle(plugin),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
